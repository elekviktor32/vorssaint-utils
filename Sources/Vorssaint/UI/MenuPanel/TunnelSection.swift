// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Panel section listing every tunnel profile with its live state. Being on
/// screen is itself a signal: while this section is visible the service
/// probes ports every few seconds instead of once a minute.
struct TunnelSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = TunnelService.shared
    var collapsible = true

    private var strings: TunnelFeatureStrings { FeatureStrings.tunnels(l10n.language) }

    var body: some View {
        PanelSection(.tunnels, title: strings.pageTitle, collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 10) {
                if !service.profiles.isEmpty {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if service.profiles.isEmpty {
                    Text(strings.noProfiles)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.profiles) { profile in
                        row(profile)
                    }
                    Divider()
                    Toggle(strings.autoReconnect, isOn: $service.autoReconnect)
                        .font(.system(size: 10.5, weight: .medium))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(strings.autoReconnectCaption)
                }
            }
            .panelCard()
            .onAppear { service.panelDidAppear() }
            .onDisappear { service.panelDidDisappear() }
        }
    }

    private var summary: String {
        let states = service.profiles.map { service.state(of: $0.id) }
        switch tunnelAggregate(states) {
        case .error: return strings.summaryError
        case .partial:
            return states.contains(.connecting) ? strings.summaryConnecting : strings.summaryExternal
        case .allOn: return strings.summaryLive(states.filter { $0 == .connected }.count)
        case .allOff: return strings.summaryIdle
        }
    }

    private func row(_ profile: TunnelProfile) -> some View {
        let state = service.state(of: profile.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: state))
                    .frame(width: 7, height: 7)
                Text(profile.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(isBusy(state) ? strings.disconnect : strings.connect) {
                    service.toggle(profile.id)
                }
                .font(.system(size: 10.5, weight: .medium))
                .buttonStyle(.borderless)
                // .external reads Connect, never Disconnect, so nothing here
                // offers to kill an ssh we do not own. Left enabled: greying
                // it made someone else's listener a dead end with no per-row
                // explanation, while pressing it runs the precheck, which
                // names the port that is taken.
            }
            HStack(spacing: 4) {
                ForEach(profile.forwards) { forward in
                    Text("\(forward.label) \(forward.localPort)")
                        .font(.system(size: 9.5).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(
                                (service.portOpen[forward.localPort] == true ? Color.green : Color.secondary)
                                    .opacity(0.16)))
                        .foregroundStyle(.secondary)
                }
            }
            if case .error(let message) = state {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func isBusy(_ state: TunnelState) -> Bool {
        state == .connected || state == .connecting
    }

    private func color(for state: TunnelState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .external: return .yellow
        case .error: return .red
        case .disconnected: return .secondary
        }
    }
}
