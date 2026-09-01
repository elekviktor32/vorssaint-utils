// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Network

/// SSH port forwards, one process per profile.
///
/// Nothing runs until `syncWithPreferences()` says the feature is installed:
/// no ssh, no observers, no probing. Uninstalling in the hub tears every
/// tunnel down on the spot rather than leaving orphaned processes behind.
@MainActor
final class TunnelService: ObservableObject {
    static let shared = TunnelService()

    @Published private(set) var profiles: [TunnelProfile] = []
    @Published private(set) var states: [String: TunnelState] = [:]
    @Published private(set) var portOpen: [Int: Bool] = [:]
    @Published var autoReconnect: Bool = false {
        didSet {
            guard autoReconnect != oldValue else { return }
            UserDefaults.standard.set(autoReconnect, forKey: DefaultsKey.tunnelAutoReconnect)
        }
    }

    /// A live tunnel is worth watching closely; an idle feature is not. The
    /// slow cadence exists only to notice ports someone else opened.
    private static let activeProbeInterval: UInt64 = 5_000_000_000
    private static let idleProbeInterval: UInt64 = 60_000_000_000

    private var processes: [String: Process] = [:]
    /// Held only so the stderr handler stays reachable from every teardown
    /// path. The closure keeps the read source alive, not the process.
    private var stderrPipes: [String: Pipe] = [:]
    private var lastStderrLine: [String: String] = [:]
    private var manualDisconnects: Set<String> = []
    private var backoffs: [String: TunnelBackoff] = [:]
    private var connectTasks: [String: Task<Void, Never>] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var healthTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var networkSatisfied = true
    private var isSleeping = false
    private var suspendedForSleep: Set<String> = []
    /// Connected and not disconnected since: what a returning network restores.
    private var desiredActive: Set<String> = []
    /// Dropped without being asked to; the reconnect notice is owed to these.
    private var droppedUnexpectedly: Set<String> = []
    /// Drops a notice actually went out for. Notifications can be turned on
    /// mid-outage, and "it is back" without a preceding drop notice is noise.
    private var dropNoticePosted: Set<String> = []
    /// Panel appearances outstanding. A count, not a flag, so two visible
    /// copies cannot cancel each other out.
    private var panelViewers = 0

    private var isInstalled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.featureAvailable("tunnels"))
    }

    private var notifies: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.tunnelNotify)
    }

    private init() {}

    var aggregate: TunnelAggregateStatus {
        tunnelAggregate(profiles.compactMap { states[$0.id] })
    }

    func state(of profileID: String) -> TunnelState {
        states[profileID] ?? .disconnected
    }

    // MARK: Lifecycle

    func syncWithPreferences() {
        guard isInstalled else {
            stop()
            return
        }
        TunnelProfileStore.migrateIfNeeded()
        autoReconnect = UserDefaults.standard.bool(forKey: DefaultsKey.tunnelAutoReconnect)
        reloadProfiles()
        startObservers()
        startHealthLoop()
    }

    /// Full teardown: every tunnel closed, every task cancelled, every
    /// watcher and read source released, and every field that governs running
    /// state cleared. `profiles` and `autoReconnect` stay as they are —
    /// they mirror preferences and `syncWithPreferences()` reloads them on the
    /// way back in. What the user connected is forgotten too, so a reinstall
    /// does not silently reopen connections they last saw closed. Leaving any
    /// of the rest behind survives the uninstall: a stale `isSleeping` alone
    /// poisons every termination decision after a reinstall.
    private func stop() {
        disconnectAll()
        for task in connectTasks.values { task.cancel() }
        connectTasks = [:]
        for task in reconnectTasks.values { task.cancel() }
        reconnectTasks = [:]
        healthTask?.cancel()
        healthTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        // Teardown can precede EOF, and the handler outlives both the child
        // and this dictionary unless it is cleared here.
        for profileID in Array(stderrPipes.keys) { releaseStderr(profileID) }
        processes = [:]
        manualDisconnects = []
        lastStderrLine = [:]
        backoffs = [:]
        desiredActive = []
        droppedUnexpectedly = []
        dropNoticePosted = []
        suspendedForSleep = []
        isSleeping = false
        networkSatisfied = true
        portOpen = [:]
        states = [:]
        panelViewers = 0
    }

    func reloadProfiles() {
        profiles = TunnelProfileStore.load()
        let known = Set(profiles.map(\.id))
        for id in states.keys where !known.contains(id) {
            disconnect(id)
            states[id] = nil
            // The set only had to hold deleted ids while it was the sole thing
            // keeping a respawn away from them; respawnIfNeeded checks the
            // profile itself now, so it no longer has to grow forever.
            manualDisconnects.remove(id)
            // Otherwise a create/delete cycle leaks one entry per profile for
            // the life of the process.
            lastStderrLine[id] = nil
        }
        for profile in profiles where states[profile.id] == nil {
            states[profile.id] = .disconnected
        }
        // disconnect() above reprices too, but while states[id] still reads
        // .connected, so a deletion of the last active profile leaves the
        // loop pinned to the fast cadence. Repricing again here, after the
        // deletions have actually cleared states, is what settles it — do
        // not read this as a duplicate of disconnect()'s call and drop it.
        restartHealthLoop()
    }

    func panelDidAppear() {
        panelViewers += 1
        restartHealthLoop()
    }

    func panelDidDisappear() {
        panelViewers = max(0, panelViewers - 1)
        restartHealthLoop()
    }

    // MARK: Connect and disconnect

    func toggle(_ profileID: String) {
        switch state(of: profileID) {
        case .connected, .connecting: disconnect(profileID)
        default: connect(profileID)
        }
    }

    func connect(_ profileID: String) {
        guard isInstalled,
              let profile = profiles.first(where: { $0.id == profileID }),
              processes[profileID] == nil else { return }
        manualDisconnects.remove(profileID)
        desiredActive.insert(profileID)
        states[profileID] = .connecting
        restartHealthLoop()
        connectTasks[profileID]?.cancel()
        connectTasks[profileID] = Task { [weak self] in
            guard let self else { return }
            // A port someone else already holds makes ssh exit immediately,
            // with a message that reads like our failure. Say what it is
            // instead of spawning into it.
            for forward in profile.forwards {
                // A second per forward is long enough for an uninstall to land
                // mid-probe; without these checks the task spawns ssh into
                // state that stop() has already torn down.
                guard !Task.isCancelled else { return }
                let portInUse = await TunnelPortProbe.isOpen(port: forward.localPort, timeout: 1)
                // Symmetric with the health sweep: sleep or stop() can cancel
                // while the await above is suspended, and a write after that
                // would resurrect state that teardown already cleared.
                guard !Task.isCancelled else { return }
                guard portInUse else { continue }
                self.states[profileID] = .error("Port \(forward.localPort) is already in use")
                // Still wanting it would let a regained network respawn into
                // the very port this refused to spawn into.
                self.desiredActive.remove(profileID)
                self.restartHealthLoop()
                return
            }
            guard !Task.isCancelled else { return }
            self.spawn(profile)
        }
    }

    func disconnect(_ profileID: String) {
        manualDisconnects.insert(profileID)
        desiredActive.remove(profileID)
        droppedUnexpectedly.remove(profileID)
        dropNoticePosted.remove(profileID)
        connectTasks[profileID]?.cancel()
        connectTasks[profileID] = nil
        reconnectTasks[profileID]?.cancel()
        reconnectTasks[profileID] = nil
        backoffs[profileID] = nil
        if let process = processes[profileID] {
            process.terminate()
        } else {
            states[profileID] = .disconnected
        }
        restartHealthLoop()
    }

    func disconnectAll() {
        for profileID in states.keys { disconnect(profileID) }
    }

    // MARK: Process

    private func spawn(_ profile: TunnelProfile) {
        // The last gate before a child process exists: a probe or a reconnect
        // that was in flight during an uninstall must not leave one behind.
        guard isInstalled else { return }
        // Not a duplicate of respawnIfNeeded's check: the callers test this
        // before awaiting the port probe, and a network regain can spawn while
        // that await is suspended. Both registries are keyed by profile id, so
        // a second spawn would overwrite them, orphaning the first child and
        // leaving its stderr handler unreachable from every release path.
        guard processes[profile.id] == nil else { return }
        // A tunnel that dies without saying anything must not be reported with
        // the previous failure's message.
        lastStderrLine[profile.id] = nil
        states[profile.id] = .connecting
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TunnelSSHCommand.executablePath)
        process.arguments = TunnelSSHCommand.arguments(for: profile)

        let stderr = Pipe()
        process.standardError = stderr
        stderrPipes[profile.id] = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty is EOF, and the read end stays readable at EOF forever:
            // left installed, the handler respins on empty reads for the life
            // of the app.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            // ssh prefixes its post-quantum advisory with "**"; it is noise,
            // and it would otherwise become the reported failure reason.
            let lines = text.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("**") }
            guard let last = lines.last else { return }
            Task { @MainActor in self?.lastStderrLine[profile.id] = last }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.handleTermination(profile, exitStatus: status) }
        }
        do {
            try process.run()
            processes[profile.id] = process
        } catch {
            releaseStderr(profile.id)
            states[profile.id] = .error("ssh failed to start: \(error.localizedDescription)")
            // Nothing is connecting any more; without this the five-second
            // cadence keeps probing with no tunnel to watch.
            restartHealthLoop()
        }
    }

    /// Clearing the handler is what releases the dispatch read source and the
    /// descriptor with it. Dropping the process is not enough: the source
    /// holds the read end open and keeps firing after the child is gone.
    private func releaseStderr(_ profileID: String) {
        guard let pipe = stderrPipes.removeValue(forKey: profileID) else { return }
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    private func handleTermination(_ profile: TunnelProfile, exitStatus: Int32) {
        processes[profile.id] = nil
        releaseStderr(profile.id)
        // A child outlives the teardown that killed it, and a deleted
        // profile's child outlives its profile. Nothing either reports may
        // rebuild state that stop() or reloadProfiles has just cleared, least
        // of all a reconnect.
        guard isInstalled, profiles.contains(where: { $0.id == profile.id }) else { return }
        var backoff = backoffs[profile.id] ?? TunnelBackoff()
        let decision = TunnelTerminationDecision.decide(
            manual: manualDisconnects.contains(profile.id),
            autoReconnect: autoReconnect,
            sleeping: isSleeping,
            backoff: &backoff,
            stderrLine: lastStderrLine[profile.id],
            exitStatus: exitStatus)
        backoffs[profile.id] = backoff

        switch decision {
        case .staysDisconnected:
            states[profile.id] = .disconnected
        case .suspendForSleep:
            states[profile.id] = .connecting
        case .error(let message):
            states[profile.id] = .error(message)
            notifyDropOnce(profile, reason: message)
        case .reconnect(let delay):
            states[profile.id] = .connecting
            notifyDropOnce(profile, reason: lastStderrLine[profile.id] ?? "reconnecting")
            reconnectTasks[profile.id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.respawnIfNeeded(profile)
            }
        }
        restartHealthLoop()
    }

    /// One notice per outage, not one per backoff attempt. The outage is
    /// recorded either way; only the notice depends on the setting, so a drop
    /// that went unannounced cannot produce a lone recovery notice later.
    private func notifyDropOnce(_ profile: TunnelProfile, reason: String) {
        let isNewOutage = droppedUnexpectedly.insert(profile.id).inserted
        guard isNewOutage, notifies else { return }
        dropNoticePosted.insert(profile.id)
        Notifier.post(title: "\(profile.name) tunnel dropped", body: reason)
    }

    private func respawnIfNeeded(_ profile: TunnelProfile) {
        // The captured profile outlives the store it came from: a delete in
        // Settings can land while a reconnect or a wake is still pending.
        guard isInstalled, profiles.contains(where: { $0.id == profile.id }),
              processes[profile.id] == nil,
              !manualDisconnects.contains(profile.id) else { return }
        spawn(profile)
    }

    // MARK: Sleep, wake and network

    private func startObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.macWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.macDidWake() }
            },
        ]
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handlePathUpdate(satisfied: satisfied) }
        }
        monitor.start(queue: .global())
        pathMonitor = monitor
    }

    private func macWillSleep() {
        isSleeping = true
        suspendedForSleep = Set(states.filter { $0.value == .connected || $0.value == .connecting }.keys)
        for task in reconnectTasks.values { task.cancel() }
        reconnectTasks.removeAll()
        // A probe still in flight would resume mid-sleep and spawn ssh instead
        // of being restored with everything else on wake.
        for task in connectTasks.values { task.cancel() }
        connectTasks.removeAll()
        // Close cleanly rather than letting sleep freeze a half-dead socket
        // that the far end still believes in.
        for profileID in suspendedForSleep { processes[profileID]?.terminate() }
    }

    private func macDidWake() {
        isSleeping = false
        let restoring = suspendedForSleep
        suspendedForSleep = []
        guard !restoring.isEmpty else { return }
        for profileID in restoring {
            backoffs[profileID] = nil
            states[profileID] = .connecting
        }
        Task { [weak self] in
            // The Wi-Fi comes back a beat after the display does.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            for profileID in restoring {
                guard let profile = self.profiles.first(where: { $0.id == profileID }) else { continue }
                self.respawnIfNeeded(profile)
            }
        }
    }

    private func handlePathUpdate(satisfied: Bool) {
        let regained = satisfied && !networkSatisfied
        networkSatisfied = satisfied
        guard regained, !isSleeping else { return }
        // The network is back now, so waiting out a backoff that was measured
        // against a dead link only adds delay.
        for profileID in desiredActive where processes[profileID] == nil
            && !manualDisconnects.contains(profileID) {
            guard autoReconnect || states[profileID] == .connecting else { continue }
            reconnectTasks[profileID]?.cancel()
            reconnectTasks[profileID] = nil
            backoffs[profileID] = nil
            states[profileID] = .connecting
            guard let profile = profiles.first(where: { $0.id == profileID }) else { continue }
            respawnIfNeeded(profile)
        }
    }

    // MARK: Health loop

    private var wantsFastProbe: Bool {
        panelViewers > 0 || states.values.contains { $0 == .connected || $0 == .connecting }
    }

    private func startHealthLoop() {
        guard healthTask == nil else { return }
        let interval = wantsFastProbe ? Self.activeProbeInterval : Self.idleProbeInterval
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.healthCheck()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// The cadence is chosen when the loop starts, so a change of pace means
    /// restarting it. Cheap, and it keeps the idle case genuinely idle.
    private func restartHealthLoop() {
        guard isInstalled else { return }
        healthTask?.cancel()
        healthTask = nil
        startHealthLoop()
    }

    private func healthCheck() async {
        for profile in profiles {
            var allOpen = !profile.forwards.isEmpty
            var anyOpen = false
            for forward in profile.forwards {
                // A superseded pass has to stop here: restartHealthLoop only
                // cancels the task, and a traversal suspended in the probe
                // would otherwise keep opening sockets for the whole sweep.
                guard !Task.isCancelled else { return }
                let open = await TunnelPortProbe.isOpen(port: forward.localPort, timeout: 1.5)
                // The reading is up to a second and a half old by now: a
                // superseded sweep landing it would overwrite the value the
                // fresh sweep has already published for this port.
                guard !Task.isCancelled else { return }
                portOpen[forward.localPort] = open
                if open { anyOpen = true } else { allOpen = false }
            }
            // These probes were taken before the cancellation; acting on them
            // now would flip a profile that has since been disconnected.
            guard !Task.isCancelled else { return }
            switch states[profile.id] {
            case .connecting where processes[profile.id] != nil && allOpen:
                states[profile.id] = .connected
                backoffs[profile.id] = nil
                droppedUnexpectedly.remove(profile.id)
                if dropNoticePosted.remove(profile.id) != nil, notifies {
                    Notifier.post(title: "\(profile.name) tunnel is back",
                                  body: "Every port is reachable again.")
                }
            case .disconnected where anyOpen:
                states[profile.id] = .external
            case .external where !anyOpen:
                states[profile.id] = .disconnected
            default:
                break
            }
        }
    }
}
