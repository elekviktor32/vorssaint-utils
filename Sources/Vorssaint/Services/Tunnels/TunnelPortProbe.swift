// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Network

/// Whether a local port accepts a connection right now. This is the only
/// honest way to tell a working forward from a live ssh process that is
/// carrying nothing.
enum TunnelPortProbe {
    static func isOpen(port: Int, timeout: TimeInterval = 2) async -> Bool {
        await withCheckedContinuation { continuation in
            guard port > 0, port <= 65535,
                  let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
            let lock = NSLock()
            var finished = false
            // The state handler can fire after cancel(), and a continuation
            // resumed twice is a crash, not a warning.
            func finish(_ isOpen: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: isOpen)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
