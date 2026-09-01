// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Tunnel profile editor. Edits are held locally and written on every change,
/// then handed to the service, so a profile renamed mid-connection does not
/// drop the tunnel: running state is keyed by the profile's stable id.
struct TunnelSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = TunnelService.shared
    @AppStorage(DefaultsKey.tunnelNotify) private var notify = true
    @State private var profiles: [TunnelProfile] = []

    private var strings: TunnelFeatureStrings { FeatureStrings.tunnels(l10n.language) }

    var body: some View {
        Form {
            Section {
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
                Section(profile.name.isEmpty ? strings.profileName : profile.name) {
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
        .navigationTitle(strings.pageTitle)
        .onAppear { profiles = TunnelProfileStore.load() }
        .onChange(of: profiles) { _, updated in persist(updated) }
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
                Button(strings.removeProfile, role: .destructive) {
                    profile.wrappedValue.forwards.removeAll { $0.id == forward.id }
                }
                .font(.caption)
            }
        }
    }

    /// Both problems block a connection rather than a save: a profile half
    /// typed is a normal state, and refusing to store it would lose the work.
    private var warning: String? {
        let ports = profiles.flatMap { $0.forwards }.flatMap { [$0.localPort, $0.remotePort] }
        if ports.contains(where: { !TunnelProfileStore.isValidPort($0) }) {
            return strings.invalidPort
        }
        if !TunnelProfileStore.duplicateLocalPorts(in: profiles).isEmpty {
            return strings.duplicatePort
        }
        return nil
    }

    private func persist(_ updated: [TunnelProfile]) {
        TunnelProfileStore.save(updated)
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
