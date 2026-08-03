import Foundation

enum RemoteEvidenceDeletionError: LocalizedError {
    case anonymousExchangeAccessRequired
    case anonymousExchangeNotConfigured

    var errorDescription: String? {
        switch self {
        case .anonymousExchangeAccessRequired:
            return "Reconnect the same iCloud and Sign in with Apple account before removing the remaining public evidence copy."
        case .anonymousExchangeNotConfigured:
            return "This build cannot remove public evidence until its anonymous exchange Worker is configured."
        }
    }
}

@MainActor
enum RemoteEvidenceDeletionService {
    static func removeRemoteCopies(
        for levels: [LevelRecord],
        communityAccess: CommunityAccessStore,
        exchangeClient: ReviewExchangeClient = ReviewExchangeClient()
    ) async throws {
        let trustedRecordNames = Set(levels.compactMap(\.trustedReviewRecordName))
        for recordName in trustedRecordNames {
            try await TrustedReviewService.removeOwnedInvitation(recordName: recordName)
        }

        let submissionIDs = Set(levels.compactMap(\.reviewSubmissionID))
        guard !submissionIDs.isEmpty, !communityAccess.allowsLocalDemo else { return }
        guard communityAccess.canUseAnonymousExchange else {
            throw RemoteEvidenceDeletionError.anonymousExchangeAccessRequired
        }
        guard exchangeClient.isConfigured else {
            throw RemoteEvidenceDeletionError.anonymousExchangeNotConfigured
        }
        for submissionID in submissionIDs {
            try await exchangeClient.removeOwnSubmission(
                submissionID: submissionID,
                identityToken: communityAccess.identityToken
            )
        }
    }
}
