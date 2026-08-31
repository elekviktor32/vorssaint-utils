// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// One local port carried to a host reachable from the relay.
///
/// The identity is its own value rather than the port number: a row being
/// typed still holds port 0, and two of those sharing an id would collapse
/// into one in every list that renders them. It stays out of the JSON, so a
/// config written by the standalone app still decodes, and out of equality,
/// so a decoded profile compares equal to the one that was encoded.
struct TunnelPortForward: Codable, Identifiable {
    var id = UUID()
    var label: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int

    private enum CodingKeys: String, CodingKey {
        case label, localPort, remoteHost, remotePort
    }
}

extension TunnelPortForward: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.localPort == rhs.localPort
            && lhs.remoteHost == rhs.remoteHost && lhs.remotePort == rhs.remotePort
    }
}

/// One ssh connection and every port it carries. `id` is stable across edits
/// and is what running state is keyed by, so renaming a profile never orphans
/// a live tunnel.
struct TunnelProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var sshUser: String
    var sshHost: String
    var forwards: [TunnelPortForward]
}
