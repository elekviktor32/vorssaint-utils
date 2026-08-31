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
        failures.append(contentsOf: sshArgumentFailures())
        failures.append(contentsOf: profileStoreFailures())
        failures.append(contentsOf: migrationFailures())
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

    private static func sshArgumentFailures() -> [String] {
        let profile = TunnelProfile(
            id: "check", name: "Check", sshUser: "user", sshHost: "relay.example",
            forwards: [
                TunnelPortForward(label: "A", localPort: 3306,
                                  remoteHost: "db.internal", remotePort: 3306),
                TunnelPortForward(label: "B", localPort: 27018,
                                  remoteHost: "docs.internal", remotePort: 27017),
            ])
        let arguments = TunnelSSHCommand.arguments(for: profile)
        var failures: [String] = []
        // ExitOnForwardFailure is what turns a busy local port into a process
        // exit we can report, instead of a connection that silently carries
        // nothing.
        if !arguments.contains("ExitOnForwardFailure=yes") {
            failures.append("tunnel ssh arguments miss ExitOnForwardFailure")
        }
        if !arguments.contains("-N") {
            failures.append("tunnel ssh arguments miss -N")
        }
        if !arguments.contains("3306:db.internal:3306")
            || !arguments.contains("27018:docs.internal:27017") {
            failures.append("tunnel ssh arguments miss a forward: \(arguments)")
        }
        if arguments.last != "user@relay.example" {
            failures.append("tunnel ssh destination is \(arguments.last ?? "nil")")
        }
        return failures
    }

    private static func profileStoreFailures() -> [String] {
        var failures: [String] = []
        let profiles = [
            TunnelProfile(id: "dev", name: "DEV", sshUser: "u", sshHost: "h",
                          forwards: [TunnelPortForward(label: "MariaDB", localPort: 3306,
                                                       remoteHost: "db", remotePort: 3306)]),
            TunnelProfile(id: "uat", name: "UAT", sshUser: "u", sshHost: "h",
                          forwards: [TunnelPortForward(label: "MariaDB", localPort: 3306,
                                                       remoteHost: "db2", remotePort: 3306)]),
        ]
        guard let encoded = TunnelProfileStore.encode(profiles) else {
            return ["tunnel profile encoding returned nil"]
        }
        if TunnelProfileStore.decode(encoded) != profiles {
            failures.append("tunnel profile round trip changed the profiles")
        }
        // A corrupt or absent blob must read as "no profiles", never crash.
        if !TunnelProfileStore.decode(nil).isEmpty {
            failures.append("tunnel profile decode of nil was not empty")
        }
        if !TunnelProfileStore.decode(Data([0x00, 0x01])).isEmpty {
            failures.append("tunnel profile decode of garbage was not empty")
        }
        // Two profiles cannot both own local port 3306; only one ssh can bind it.
        if TunnelProfileStore.duplicateLocalPorts(in: profiles) != [3306] {
            failures.append("tunnel duplicate port detection failed")
        }
        if TunnelProfileStore.isValidPort(0) || TunnelProfileStore.isValidPort(65536)
            || !TunnelProfileStore.isValidPort(3306) {
            failures.append("tunnel port validation failed")
        }
        return failures
    }

    /// Encodes to the same wrapped-object shape as the standalone TunnelBar
    /// app's config.json (an "environments" array), using the real model
    /// types so the fixture tracks their Codable behaviour instead of a
    /// hand-written string.
    private struct LegacyConfigFixture: Encodable {
        let environments: [TunnelProfile]
    }

    private static func migrationFailures() -> [String] {
        var failures: [String] = []

        let legacyProfiles = [
            TunnelProfile(id: "dev", name: "DEV", sshUser: "u", sshHost: "h",
                          forwards: [TunnelPortForward(label: "MariaDB", localPort: 3306,
                                                       remoteHost: "db", remotePort: 3306)]),
        ]
        guard let legacyData = try? JSONEncoder().encode(LegacyConfigFixture(environments: legacyProfiles)) else {
            return ["tunnel migration: could not encode the legacy fixture"]
        }

        // Every check gets its own throwaway defaults suite and temp file so
        // none of them can see another's leftovers, and both are swept
        // afterward regardless of outcome.
        func withStore(_ body: (UserDefaults, URL) -> Void) {
            let suiteName = "com.vorssaint.selftest.tunnelmigration.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                failures.append("tunnel migration: could not create a throwaway UserDefaults suite")
                return
            }
            let legacyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tunnelbar-selftest-\(UUID().uuidString).json")
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: legacyURL)
            }
            body(defaults, legacyURL)
        }

        // A legacy file in the standalone app's shape imports its profiles.
        withStore { defaults, legacyURL in
            try? legacyData.write(to: legacyURL)
            TunnelProfileStore.migrateIfNeeded(defaults: defaults, legacyURL: legacyURL)
            if TunnelProfileStore.load(defaults: defaults) != legacyProfiles {
                failures.append("tunnel migration did not import the legacy profiles")
            }
            if !defaults.bool(forKey: DefaultsKey.tunnelProfilesMigrated) {
                failures.append("tunnel migration did not set the marker after a successful import")
            }
        }

        // A second run must not import again, nor overwrite what the user
        // has done to the list since the first run.
        withStore { defaults, legacyURL in
            try? legacyData.write(to: legacyURL)
            TunnelProfileStore.migrateIfNeeded(defaults: defaults, legacyURL: legacyURL)
            TunnelProfileStore.save([], defaults: defaults)
            TunnelProfileStore.migrateIfNeeded(defaults: defaults, legacyURL: legacyURL)
            if !TunnelProfileStore.load(defaults: defaults).isEmpty {
                failures.append("tunnel migration ran a second time and overwrote the current list")
            }
        }

        // A deliberately emptied list (a stored empty-array blob, marker not
        // yet set) must not be refilled from the legacy file.
        withStore { defaults, legacyURL in
            try? legacyData.write(to: legacyURL)
            TunnelProfileStore.save([], defaults: defaults)
            TunnelProfileStore.migrateIfNeeded(defaults: defaults, legacyURL: legacyURL)
            if !TunnelProfileStore.load(defaults: defaults).isEmpty {
                failures.append("tunnel migration refilled a deliberately emptied list")
            }
            if !defaults.bool(forKey: DefaultsKey.tunnelProfilesMigrated) {
                failures.append("tunnel migration did not set the marker over an already-emptied list")
            }
        }

        // No legacy file present is handled without error, and still sets
        // the marker so this does not get retried forever.
        withStore { defaults, legacyURL in
            TunnelProfileStore.migrateIfNeeded(defaults: defaults, legacyURL: legacyURL)
            if !defaults.bool(forKey: DefaultsKey.tunnelProfilesMigrated) {
                failures.append("tunnel migration did not set the marker with no legacy file present")
            }
            if !TunnelProfileStore.load(defaults: defaults).isEmpty {
                failures.append("tunnel migration produced profiles with no legacy file present")
            }
        }

        return failures
    }
}
