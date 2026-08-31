// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Network

/// Whether a local port accepts a connection right now. This is the only
/// honest way to tell a working forward from a live ssh process that is
/// carrying nothing.
enum TunnelPortProbe {
    /// Owns the "already resumed?" flag behind a lock. The state handler and
    /// the timeout race from different threads; a continuation resumed
    /// twice is a crash, not a warning, so the guard is not optional.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let connection: NWConnection
        private let continuation: CheckedContinuation<Bool, Never>

        init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
            self.connection = connection
            self.continuation = continuation
        }

        func finish(_ isOpen: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            connection.cancel()
            // This probe reruns every few seconds for the app's lifetime, so an
            // uncleared handler here (connection -> closure -> self) leaks a
            // connection object on every call instead of just once.
            connection.stateUpdateHandler = nil
            continuation.resume(returning: isOpen)
        }
    }

    static func isOpen(port: Int, timeout: TimeInterval = 2) async -> Bool {
        await withCheckedContinuation { continuation in
            guard port > 0, port <= 65535,
                  let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
            let resumeGuard = ResumeGuard(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resumeGuard.finish(true)
                case .failed, .waiting: resumeGuard.finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { resumeGuard.finish(false) }
        }
    }
}
