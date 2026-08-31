// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The ssh invocation behind a profile. Key-based auth only: a password
/// prompt on a process with no terminal would hang forever, so BatchMode
/// turns that case into an exit we can report.
enum TunnelSSHCommand {
    static let executablePath = "/usr/bin/ssh"

    static func arguments(for profile: TunnelProfile) -> [String] {
        var arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
        ]
        for forward in profile.forwards {
            arguments += ["-L", "\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"]
        }
        arguments.append("\(profile.sshUser)@\(profile.sshHost)")
        return arguments
    }
}
