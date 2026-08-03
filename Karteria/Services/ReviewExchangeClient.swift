import Foundation

struct WorkerConfiguration {
    let baseURL: URL?

    init(bundle: Bundle = .main) {
        let rawValue = (bundle.object(forInfoDictionaryKey: "KARTERIA_WORKER_URL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = URL(string: rawValue)
    }
}

enum ReviewExchangeClientError: LocalizedError {
    case notConfigured
    case missingIdentityToken
    case localEvidenceMissing
    case uploadFailed(String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Anonymous exchange is not configured for this build."
        case .missingIdentityToken: return "Sign in with Apple again before requesting an anonymous review."
        case .localEvidenceMissing: return "Karteria could not find one prepared evidence file. Check the proof again before submitting."
        case .uploadFailed(let message): return message
        case .server(let message): return message
        case .invalidResponse: return "The exchange returned an unreadable response."
        }
    }
}

struct ExchangeMediaDescriptor: Codable, Identifiable {
    let id: UUID
    var kind: EvidenceMediaKind
    var mimeType: String
    var byteCount: Int
    var durationSeconds: Double
    var label: String

    init(_ media: PreparedEvidenceMedia, label: String) {
        id = media.id
        kind = media.kind
        mimeType = media.kind == .image ? "image/jpeg" : "video/mp4"
        byteCount = media.byteCount
        durationSeconds = media.duration
        self.label = label
    }
}

struct ExchangeEvidenceContract: Codable {
    var title: String
    var baselineSummary: String
    var criteria: [String]
}

struct ExchangeSubmissionManifest: Codable {
    var submissionID: UUID
    var birthDate: String
    var contract: ExchangeEvidenceContract
    var explanation: String
    var baseline: [ExchangeMediaDescriptor]
    var checkpoint: [ExchangeMediaDescriptor]
}

struct SubmissionInitiateRequest: Codable {
    var manifest: ExchangeSubmissionManifest
}

struct SubmissionUploadInstruction: Codable, Identifiable {
    var mediaID: UUID
    var fieldName: String
    var url: URL

    var id: String { fieldName }
}

struct CloudKitUploadedAsset: Codable {
    struct SingleFile: Codable {
        var fileChecksum: String
        var size: Int
        var receipt: String
        var referenceChecksum: String?
        var wrappingKey: String?
    }

    var singleFile: SingleFile
}

struct SubmissionInitiateResponse: Codable {
    var submissionID: UUID
    var alreadyFinalized: Bool
    var draftToken: String?
    var creditGateWaived: Bool
    var reviewCredits: Int?
    var uploads: [SubmissionUploadInstruction]
}

struct SubmissionFinalizeRequest: Codable {
    var manifest: ExchangeSubmissionManifest
    var draftToken: String
    var uploadedAssets: [String: CloudKitUploadedAsset]
}

struct SubmissionFinalizeResponse: Codable {
    var submissionID: UUID
    var status: String
    var alreadyFinalized: Bool
    var creditsConsumed: Int
    var creditGateWaived: Bool
    var reviewCredits: Int?
}

struct ClaimReviewRequest: Codable {
    var birthDate: String
}

struct ClaimReviewResponse: Codable {
    var workItem: ReviewWorkItem?
    var queueEmpty: Bool
}

struct CalibrationRecordRequest: Codable {
    var caseID: String
    var decisions: [ReviewDecision]
}

struct CalibrationRecordResponse: Codable {
    var reviewCredits: Int
    var calibrationCompleted: Int
    var calibrationCorrect: Int
    var calibrationStatus: String
}

struct SubmitReviewRequest: Codable {
    var submissionID: UUID
    var seatID: UUID
    var decisions: [ReviewDecision]
    var note: String
}

struct SubmitReviewResponse: Codable {
    var accepted: Bool
    var earnedCredit: Bool
    var reviewCredits: Int?
    var settlement: PublicSettlementResponse?
}

struct PublicSettlementResponse: Codable {
    var outcome: ReviewSettlement.Outcome
    var failedCriteriaIndexes: [Int]
    var reviewedAt: Date
    var cleanupAt: Date
}

struct SubmissionStatusRequest: Codable {
    var submissionID: UUID
}

struct SubmissionStatusResponse: Codable {
    var submissionID: UUID
    var state: String
    var reviewCount: Int
    var submittedAt: Date
    var canInviteTrustedReview: Bool
    var highestPriority: Bool
    var settlement: PublicSettlementResponse?
}

struct RedeemCommunityPassResponse: Codable {
    var grantedDays: Int
    var entitlementExpiresAt: Date?
}

struct ContentReportRequest: Codable {
    var submissionID: UUID
    var reason: String
    var detail: String
}

struct RemoveSubmissionRequest: Codable {
    var submissionID: UUID
}

struct BlockSubmissionRequest: Codable {
    var submissionID: UUID
}

struct BlockSubmissionResponse: Codable {
    var blocked: Bool
    var duplicate: Bool
}

final class ReviewExchangeClient {
    private let configuration: WorkerConfiguration
    private let session: URLSession

    init(configuration: WorkerConfiguration = WorkerConfiguration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    var isConfigured: Bool { configuration.baseURL != nil }

    func submitCheckpoint(
        manifest: ExchangeSubmissionManifest,
        baseline: [PreparedEvidenceMedia],
        checkpoint: [PreparedEvidenceMedia],
        identityToken: String?
    ) async throws -> SubmissionFinalizeResponse {
        let initiation: SubmissionInitiateResponse = try await post(
            path: "/submissions/initiate",
            token: identityToken,
            body: SubmissionInitiateRequest(manifest: manifest)
        )
        if initiation.alreadyFinalized {
            return SubmissionFinalizeResponse(
                submissionID: initiation.submissionID,
                status: "awaitingReview",
                alreadyFinalized: true,
                creditsConsumed: 0,
                creditGateWaived: initiation.creditGateWaived,
                reviewCredits: initiation.reviewCredits
            )
        }
        guard let draftToken = initiation.draftToken else { throw ReviewExchangeClientError.invalidResponse }
        let mediaByID = Dictionary(uniqueKeysWithValues: (baseline + checkpoint).map { ($0.id, $0) })
        var uploadedAssets: [String: CloudKitUploadedAsset] = [:]
        for instruction in initiation.uploads {
            guard let media = mediaByID[instruction.mediaID] else { throw ReviewExchangeClientError.invalidResponse }
            uploadedAssets[instruction.fieldName] = try await upload(media: media, to: instruction.url)
        }
        return try await post(
            path: "/submissions/finalize",
            token: identityToken,
            body: SubmissionFinalizeRequest(
                manifest: manifest,
                draftToken: draftToken,
                uploadedAssets: uploadedAssets
            )
        )
    }

    func recordCalibration(
        caseID: String,
        decisions: [ReviewDecision],
        identityToken: String?
    ) async throws -> CalibrationRecordResponse {
        try await post(
            path: "/calibrations/record",
            token: identityToken,
            body: CalibrationRecordRequest(caseID: caseID, decisions: decisions)
        )
    }

    func claimNext(birthDate: String, identityToken: String?) async throws -> ClaimReviewResponse {
        try await post(
            path: "/review-slots/claim",
            token: identityToken,
            body: ClaimReviewRequest(birthDate: birthDate)
        )
    }

    func submitReview(_ request: SubmitReviewRequest, identityToken: String?) async throws -> SubmitReviewResponse {
        try await post(path: "/reviews/settle", token: identityToken, body: request)
    }

    func status(submissionID: UUID, identityToken: String?) async throws -> SubmissionStatusResponse {
        try await post(
            path: "/submissions/status",
            token: identityToken,
            body: SubmissionStatusRequest(submissionID: submissionID)
        )
    }

    func redeemCommunityPass(identityToken: String?) async throws -> RedeemCommunityPassResponse {
        try await post(path: "/rewards/redeem", token: identityToken, body: EmptyRequest())
    }

    func reportContent(
        submissionID: UUID,
        reason: String,
        detail: String,
        identityToken: String?
    ) async throws {
        let _: EmptyResponse = try await post(
            path: "/reports",
            token: identityToken,
            body: ContentReportRequest(
                submissionID: submissionID,
                reason: reason,
                detail: String(detail.prefix(500))
            )
        )
    }

    func removeOwnSubmission(submissionID: UUID, identityToken: String?) async throws {
        let _: EmptyResponse = try await post(
            path: "/submissions/remove",
            token: identityToken,
            body: RemoveSubmissionRequest(submissionID: submissionID)
        )
    }

    func blockSubmissionOwner(submissionID: UUID, identityToken: String?) async throws -> BlockSubmissionResponse {
        try await post(
            path: "/blocks",
            token: identityToken,
            body: BlockSubmissionRequest(submissionID: submissionID)
        )
    }

    private func upload(media: PreparedEvidenceMedia, to url: URL) async throws -> CloudKitUploadedAsset {
        let localURL = EvidenceMediaStore.localURL(for: media.relativePath)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ReviewExchangeClientError.localEvidenceMissing
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: localURL, options: .mappedIfSafe)
        }.value
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(media.kind == .image ? "image/jpeg" : "video/mp4", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw ReviewExchangeClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewExchangeClientError.uploadFailed("Proof upload failed. Check the connection and try again.")
        }
        guard let uploaded = try? decoder.decode(CloudKitUploadedAsset.self, from: responseData) else {
            throw ReviewExchangeClientError.uploadFailed("The evidence host did not confirm this proof upload.")
        }
        guard uploaded.singleFile.size == media.byteCount else {
            throw ReviewExchangeClientError.uploadFailed("The uploaded proof size did not match the checked evidence.")
        }
        return uploaded
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        token: String?,
        body: Request
    ) async throws -> Response {
        guard let baseURL = configuration.baseURL else { throw ReviewExchangeClientError.notConfigured }
        guard let token, !token.isEmpty else { throw ReviewExchangeClientError.missingIdentityToken }
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReviewExchangeClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(WorkerErrorResponse.self, from: data).message)
            throw ReviewExchangeClientError.server(message ?? "Exchange request failed with status \(http.statusCode).")
        }
        guard let decoded = try? decoder.decode(Response.self, from: data) else {
            throw ReviewExchangeClientError.invalidResponse
        }
        return decoded
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct EmptyRequest: Codable {}
private struct EmptyResponse: Codable {}
private struct WorkerErrorResponse: Codable { let message: String }
