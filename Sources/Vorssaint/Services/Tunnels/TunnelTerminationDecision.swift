// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// What to do once the ssh process has exited.
enum TunnelTerminationDecision: Equatable {
    case staysDisconnected
    /// Torn down for sleep; the wake path brings it back with no backoff.
    case suspendForSleep
    case reconnect(afterSeconds: TimeInterval)
    case error(String)

    /// Order matters: a manual disconnect is the user's decision and outranks
    /// everything, and sleep outranks auto-reconnect so waking does not start
    /// at the far end of the backoff.
    static func decide(manual: Bool,
                       autoReconnect: Bool,
                       sleeping: Bool,
                       backoff: inout TunnelBackoff,
                       stderrLine: String?,
                       exitStatus: Int32) -> TunnelTerminationDecision {
        if manual { return .staysDisconnected }
        if sleeping { return .suspendForSleep }
        guard autoReconnect else {
            return .error(stderrLine ?? "ssh exited (status \(exitStatus))")
        }
        return .reconnect(afterSeconds: backoff.nextDelay())
    }
}
