// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Exponential backoff for reconnect attempts: 1, 2, 4, 8, 16, 30, 30, …
struct TunnelBackoff: Equatable {
    private var attempt = 0

    init() {}

    mutating func nextDelay() -> TimeInterval {
        let delay = min(30, pow(2, Double(attempt)))
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}
