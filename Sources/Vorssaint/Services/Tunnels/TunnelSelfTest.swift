// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Pure-logic checks for the tunnel feature, run by `Vorssaint --selftest`.
/// The tunnel service itself needs a network and an ssh binary, so only the
/// decisions that can be wrong without either are checked here.
enum TunnelSelfTest {
    static func failures() -> [String] {
        var failures: [String] = []
        failures.append(contentsOf: backoffFailures())
        failures.append(contentsOf: terminationFailures())
        failures.append(contentsOf: aggregateFailures())
        return failures
    }

    private static func backoffFailures() -> [String] {
        var backoff = TunnelBackoff()
        let observed = (0..<7).map { _ in backoff.nextDelay() }
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30]
        var failures: [String] = []
        if observed != expected {
            failures.append("tunnel backoff sequence \(observed), expected \(expected)")
        }
        backoff.reset()
        if backoff.nextDelay() != 1 {
            failures.append("tunnel backoff did not reset")
        }
        return failures
    }

    private static func terminationFailures() -> [String] {
        var failures: [String] = []
        var backoff = TunnelBackoff()

        // A manual disconnect never reconnects, whatever else is true.
        if TunnelTerminationDecision.decide(manual: true, autoReconnect: true, sleeping: false,
                                            backoff: &backoff, stderrLine: nil, exitStatus: 0)
            != .staysDisconnected {
            failures.append("tunnel termination: manual disconnect reconnected")
        }
        // Sleep outranks auto-reconnect: the wake path restores it without backoff.
        if TunnelTerminationDecision.decide(manual: false, autoReconnect: true, sleeping: true,
                                            backoff: &backoff, stderrLine: nil, exitStatus: 0)
            != .suspendForSleep {
            failures.append("tunnel termination: sleep did not suspend")
        }
        if TunnelTerminationDecision.decide(manual: false, autoReconnect: false, sleeping: false,
                                            backoff: &backoff, stderrLine: "boom", exitStatus: 255)
            != .error("boom") {
            failures.append("tunnel termination: no auto-reconnect did not surface the error")
        }
        backoff.reset()
        if TunnelTerminationDecision.decide(manual: false, autoReconnect: true, sleeping: false,
                                            backoff: &backoff, stderrLine: nil, exitStatus: 255)
            != .reconnect(afterSeconds: 1) {
            failures.append("tunnel termination: auto-reconnect did not use the backoff")
        }
        return failures
    }

    private static func aggregateFailures() -> [String] {
        var failures: [String] = []
        let cases: [(states: [TunnelState], expected: TunnelAggregateStatus, label: String)] = [
            ([], .allOff, "empty"),
            ([.disconnected, .disconnected], .allOff, "all disconnected"),
            ([.connected, .disconnected], .allOn, "one live"),
            ([.connecting, .connected], .partial, "connecting outranks live"),
            ([.external, .disconnected], .partial, "external"),
            ([.error("x"), .connected], .error, "error outranks everything"),
        ]
        for scenario in cases where tunnelAggregate(scenario.states) != scenario.expected {
            failures.append("tunnel aggregate \(scenario.label): "
                            + "\(tunnelAggregate(scenario.states)), expected \(scenario.expected)")
        }
        return failures
    }
}
