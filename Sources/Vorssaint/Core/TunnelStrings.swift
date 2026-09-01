// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Strings for the SSH tunnels feature. Same contract as the other
/// FeatureStrings structs: memberwise init with labeled arguments in
/// declaration order, one static per language, all in this file.
struct TunnelFeatureStrings {
    let pageTitle: String
    let hubDescription: String
    let summaryIdle: String
    let summaryConnecting: String
    let summaryExternal: String
    let summaryError: String
    let connect: String
    let disconnect: String
    let autoReconnect: String
    let autoReconnectCaption: String
    let notify: String
    let notifyCaption: String
    let noProfiles: String
    let addProfile: String
    let removeProfile: String
    let profileName: String
    let sshUser: String
    let sshHost: String
    let forwards: String
    let addForward: String
    let forwardLabel: String
    let localPort: String
    let remoteHost: String
    let remotePort: String
    let invalidPort: String
    let duplicatePort: String

    /// "2 tunnels up" — the count is the whole message, so it is built here
    /// rather than stitched together at the call site.
    func summaryLive(_ count: Int) -> String {
        count == 1 ? "1 tunnel up" : "\(count) tunnels up"
    }
}

extension FeatureStrings {
    static func tunnels(_ language: AppLanguage) -> TunnelFeatureStrings {
        // English only: this is a private build, and a half-translated feature
        // reads worse than an untranslated one. The switch stays exhaustive so
        // adding a language later is a compiler-guided edit.
        switch language {
        case .enUS, .ptBR, .tr, .ru, .es, .de, .fr, .it, .ja, .ko, .zhHans, .zhTW, .zhHK:
            return .enUS
        }
    }
}

extension TunnelFeatureStrings {
    static let enUS = TunnelFeatureStrings(
        pageTitle: "SSH tunnels",
        hubDescription: "Opens and watches SSH port forwards, reconnecting them after sleep or a network change.",
        summaryIdle: "No tunnel is up",
        summaryConnecting: "Connecting…",
        summaryExternal: "An outside tunnel is holding the ports",
        summaryError: "A tunnel failed",
        connect: "Connect",
        disconnect: "Disconnect",
        autoReconnect: "Reconnect automatically",
        autoReconnectCaption: "Retries a dropped tunnel, backing off from 1 second to 30.",
        notify: "Notify when a tunnel drops",
        notifyCaption: "One notice per outage, and one when it comes back.",
        noProfiles: "No tunnel profiles yet. Add one to get started.",
        addProfile: "Add profile",
        removeProfile: "Remove profile",
        profileName: "Name",
        sshUser: "SSH user",
        sshHost: "SSH host",
        forwards: "Port forwards",
        addForward: "Add port forward",
        forwardLabel: "Label",
        localPort: "Local port",
        remoteHost: "Remote host",
        remotePort: "Remote port",
        invalidPort: "Ports must be between 1 and 65535.",
        duplicatePort: "Two forwards claim the same local port; only one can connect."
    )
}
