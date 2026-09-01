// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Tunnel profile editor. Edits are written to disk on every change — cheap,
/// synchronous, so nothing typed is lost if Settings closes or the app quits
/// mid-edit — but handing the change to the service is debounced, since each
/// handoff restarts the health loop and reprobes every port. A profile
/// renamed mid-connection does not drop the tunnel either way: running state
/// is keyed by the profile's stable id, not its name.
struct TunnelSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = TunnelService.shared
    @AppStorage(DefaultsKey.tunnelNotify) private var notify = true
    @State private var profiles: [TunnelProfile] = []
    @State private var reloadTask: Task<Void, Never>?

    /// Long enough to collapse a whole burst of keystrokes into one service
    /// reload, short enough that an add or delete still reaches the panel
    /// without the user noticing a delay.
    private static let reloadDebounceNanoseconds: UInt64 = 400_000_000

    private var strings: TunnelFeatureStrings { FeatureStrings.tunnels(l10n.language) }

    var body: some View {
        Form {
            Section {
                Toggle(strings.autoReconnect, isOn: $service.autoReconnect)
                Text(strings.autoReconnectCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(strings.notify, isOn: $notify)
                Text(strings.notifyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning {
                Section {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            ForEach($profiles) { $profile in
                Section(profile.name.isEmpty ? strings.untitledProfile : profile.name) {
                    TextField(strings.profileName, text: $profile.name)
                    TextField(strings.sshUser, text: $profile.sshUser)
                    TextField(strings.sshHost, text: $profile.sshHost)
                    forwardRows($profile)
                    HStack {
                        Button(strings.addForward) { addForward(to: $profile) }
                        Spacer()
                        Button(strings.removeProfile, role: .destructive) {
                            remove(profile)
                        }
                    }
                }
            }
            Section {
                if profiles.isEmpty {
                    Text(strings.noProfiles)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(strings.addProfile) { addProfile() }
            }
        }
        .formStyle(.grouped)
        .onAppear { profiles = TunnelProfileStore.load() }
        .onChange(of: profiles) { _, updated in persist(updated) }
        .onDisappear { flushReload() }
    }

    @ViewBuilder
    private func forwardRows(_ profile: Binding<TunnelProfile>) -> some View {
        ForEach(profile.forwards) { $forward in
            VStack(alignment: .leading, spacing: 4) {
                TextField(strings.forwardLabel, text: $forward.label)
                HStack {
                    TextField(strings.localPort, value: $forward.localPort, format: .number)
                        .frame(width: 90)
                    TextField(strings.remoteHost, text: $forward.remoteHost)
                    TextField(strings.remotePort, value: $forward.remotePort, format: .number)
                        .frame(width: 90)
                }
                Button(strings.removeForward, role: .destructive) {
                    profile.wrappedValue.forwards.removeAll { $0.id == forward.id }
                }
                .font(.caption)
            }
        }
    }

    /// Exactly what `addForward` seeds and nothing more — the state of a
    /// forward the user has not touched yet. Its 0 ports are not really an
    /// error, so it is excluded from `warning` below rather than tripping
    /// the invalid-port check and masking a genuine duplicate-port warning
    /// elsewhere in the list. A forward the user has started filling in
    /// (even just the label) no longer matches this and is held to the
    /// normal rules.
    private static let blankForward = TunnelPortForward(label: "", localPort: 0,
                                                         remoteHost: "", remotePort: 0)

    /// Advisory only — neither the service nor the ssh command builder
    /// consults this. A profile half typed is a normal state, and refusing
    /// to store it would lose the work; an invalid or duplicated port just
    /// makes ssh fail, or fail to bind, when the tunnel actually connects.
    private var warning: String? {
        let touched = profiles.map { profile -> TunnelProfile in
            var profile = profile
            profile.forwards = profile.forwards.filter { $0 != Self.blankForward }
            return profile
        }
        let ports = touched.flatMap(\.forwards).flatMap { [$0.localPort, $0.remotePort] }
        if ports.contains(where: { !TunnelProfileStore.isValidPort($0) }) {
            return strings.invalidPort
        }
        if !TunnelProfileStore.duplicateLocalPorts(in: touched).isEmpty {
            return strings.duplicatePort
        }
        return nil
    }

    private func persist(_ updated: [TunnelProfile]) {
        // The write is cheap and synchronous — it must never wait, or a user
        // who types and immediately closes Settings or quits would lose the
        // edit. Only the service handoff is worth delaying: it restarts the
        // health loop, which cancels the in-flight probe sweep and opens a
        // socket per forward right away.
        TunnelProfileStore.save(updated)
        scheduleReload()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: Self.reloadDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            reloadTask = nil
            service.reloadProfiles()
        }
    }

    /// Settings closing must not leave the service holding a stale profile
    /// list until a debounce that nothing will trigger again happens to
    /// fire on its own.
    private func flushReload() {
        guard reloadTask != nil else { return }
        reloadTask?.cancel()
        reloadTask = nil
        service.reloadProfiles()
    }

    private func addProfile() {
        profiles.append(TunnelProfile(id: UUID().uuidString, name: "", sshUser: "",
                                      sshHost: "", forwards: []))
    }

    private func remove(_ profile: TunnelProfile) {
        service.disconnect(profile.id)
        profiles.removeAll { $0.id == profile.id }
    }

    private func addForward(to profile: Binding<TunnelProfile>) {
        profile.wrappedValue.forwards.append(
            TunnelPortForward(label: "", localPort: 0, remoteHost: "", remotePort: 0))
    }
}
