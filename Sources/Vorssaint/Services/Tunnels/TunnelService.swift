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
    private var lastStderrLine: [String: String] = [:]
    private var manualDisconnects: Set<String> = []
    private var backoffs: [String: TunnelBackoff] = [:]
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

    /// Full teardown: every tunnel closed, every watcher released. What the
    /// user connected is forgotten too, so a reinstall does not silently
    /// reopen connections they last saw closed.
    private func stop() {
        disconnectAll()
        healthTask?.cancel()
        healthTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        desiredActive = []
        droppedUnexpectedly = []
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
        }
        for profile in profiles where states[profile.id] == nil {
            states[profile.id] = .disconnected
        }
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
        Task { [weak self] in
            // A port someone else already holds makes ssh exit immediately,
            // with a message that reads like our failure. Say what it is
            // instead of spawning into it.
            for forward in profile.forwards
            where await TunnelPortProbe.isOpen(port: forward.localPort, timeout: 1) {
                self?.states[profileID] = .error("Port \(forward.localPort) is already in use")
                return
            }
            self?.spawn(profile)
        }
    }

    func disconnect(_ profileID: String) {
        manualDisconnects.insert(profileID)
        desiredActive.remove(profileID)
        droppedUnexpectedly.remove(profileID)
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
        states[profile.id] = .connecting
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TunnelSSHCommand.executablePath)
        process.arguments = TunnelSSHCommand.arguments(for: profile)

        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
            states[profile.id] = .error("ssh failed to start: \(error.localizedDescription)")
        }
    }

    private func handleTermination(_ profile: TunnelProfile, exitStatus: Int32) {
        processes[profile.id] = nil
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

    /// One notice per outage, not one per backoff attempt.
    private func notifyDropOnce(_ profile: TunnelProfile, reason: String) {
        guard droppedUnexpectedly.insert(profile.id).inserted, notifies else { return }
        Notifier.post(title: "\(profile.name) tunnel dropped", body: reason)
    }

    private func respawnIfNeeded(_ profile: TunnelProfile) {
        guard isInstalled, processes[profile.id] == nil,
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
                let open = await TunnelPortProbe.isOpen(port: forward.localPort, timeout: 1.5)
                portOpen[forward.localPort] = open
                if open { anyOpen = true } else { allOpen = false }
            }
            switch states[profile.id] {
            case .connecting where processes[profile.id] != nil && allOpen:
                states[profile.id] = .connected
                backoffs[profile.id] = nil
                if droppedUnexpectedly.remove(profile.id) != nil, notifies {
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
