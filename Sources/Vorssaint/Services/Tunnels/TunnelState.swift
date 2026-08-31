// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// One profile's tunnel state.
enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    /// The ports are open, but another process opened them (a hand-run ssh,
    /// a shell script). Ours is not managing them and must not kill them.
    case external
    case error(String)
}

/// The whole feature's state, as one badge.
enum TunnelAggregateStatus: Equatable {
    case allOff
    case allOn
    case partial
    case error
}

/// Priority order: a failure is the news, then work in progress, then a live
/// tunnel, then someone else's. Anything switched off never lowers the badge.
func tunnelAggregate(_ states: [TunnelState]) -> TunnelAggregateStatus {
    if states.contains(where: { if case .error = $0 { return true } else { return false } }) {
        return .error
    }
    if states.contains(.connecting) { return .partial }
    if states.contains(.connected) { return .allOn }
    if states.contains(.external) { return .partial }
    return .allOff
}
