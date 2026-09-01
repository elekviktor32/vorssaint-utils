// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import os.log

/// Profile persistence. The list rides in defaults as JSON, the way the
/// radial menu stores its items, so it travels with the settings backup and
/// needs no file of its own.
enum TunnelProfileStore {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                    category: "tunnels")

    static func load(defaults: UserDefaults = .standard) -> [TunnelProfile] {
        decode(defaults.data(forKey: DefaultsKey.tunnelProfiles))
    }

    static func save(_ profiles: [TunnelProfile], defaults: UserDefaults = .standard) {
        guard let data = encode(profiles) else { return }
        defaults.set(data, forKey: DefaultsKey.tunnelProfiles)
    }

    /// A blob that will not decode reads as no profiles. Refusing to start
    /// over a bad byte would leave the feature permanently dead with no way
    /// out from the UI.
    static func decode(_ data: Data?) -> [TunnelProfile] {
        guard let data, let profiles = try? JSONDecoder().decode([TunnelProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func encode(_ profiles: [TunnelProfile]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(profiles)
    }

    static func isValidPort(_ port: Int) -> Bool {
        port > 0 && port <= 65535
    }

    /// Local ports claimed by more than one forward. Only one process can
    /// bind a port, so a duplicate means one of the two profiles can never
    /// connect — worth saying before it is tried.
    static func duplicateLocalPorts(in profiles: [TunnelProfile]) -> [Int] {
        var seen = Set<Int>()
        var duplicates = Set<Int>()
        for port in profiles.flatMap({ $0.forwards }).map(\.localPort) {
            if !seen.insert(port).inserted { duplicates.insert(port) }
        }
        return duplicates.sorted()
    }

    static func legacyConfigURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TunnelBar/config.json")
    }

    /// One-shot import of the standalone TunnelBar app's config. The marker
    /// is set on every path through this function once the top guard passes
    /// — after a successful import, when there is nothing to import, and
    /// also when a legacy file was found but could not be decoded — so a
    /// process that dies before reaching the `defer` (crash, force-quit)
    /// leaves the marker unset and gets a clean retry on the next launch,
    /// while any settled outcome, success or failure, is not retried. Once
    /// set, a profile list the user deliberately emptied is never refilled.
    static func migrateIfNeeded(defaults: UserDefaults = .standard,
                                legacyURL: URL = legacyConfigURL()) {
        guard !defaults.bool(forKey: DefaultsKey.tunnelProfilesMigrated) else { return }
        defer { defaults.set(true, forKey: DefaultsKey.tunnelProfilesMigrated) }
        guard defaults.data(forKey: DefaultsKey.tunnelProfiles) == nil,
              let data = try? Data(contentsOf: legacyURL) else { return }
        guard let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) else {
            // The marker still gets set (see the defer above), which
            // permanently disables the one-shot import — worth a trace,
            // since nothing else records that this happened.
            log.error("tunnel migration: legacy config found but failed to decode; import skipped")
            return
        }
        guard !legacy.environments.isEmpty else { return }
        save(legacy.environments, defaults: defaults)
    }

    /// The standalone app wrapped the list in an object; the field names of
    /// the profiles themselves already match.
    private struct LegacyConfig: Decodable {
        let environments: [TunnelProfile]
    }
}
