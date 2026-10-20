//
//  UserProfile.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//


//
//  UserProfile.swift
//  Marathon
//

import Foundation

struct UserProfile: Identifiable, Codable, Sendable {
    var id: String
    var displayName: String
    var initials: String
    var colorHex: String

    // Link to the device's iCloud account (CloudKit user record name).
    // Set automatically on first save/selection; optional so old data decodes fine.
    var ownerUserRecordName: String? = nil
}

extension UserProfile {
    nonisolated static func mePlaceholder() -> UserProfile {
        // Keep an explicit sentinel rather than an empty identifier. Startup code
        // needs to distinguish "no profile selected" from a real saved profile.
        UserProfile(id: "me", displayName: "", initials: "", colorHex: "#34C759")
    }
}
