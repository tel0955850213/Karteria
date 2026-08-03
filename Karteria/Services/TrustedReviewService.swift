import CloudKit
import Foundation
import SwiftUI
import UIKit

enum TrustedReviewError: LocalizedError {
    case missingLocalEvidence
    case missingContract
    case missingShare
    case alreadyCompleted
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missingLocalEvidence:
            return "Karteria could not find the private evidence needed for this trusted review."
        case .missingContract:
            return "This checkpoint needs three observable criteria before it can be shared."
        case .missingShare:
            return "Karteria could not create the trusted-review invitation."
        case .alreadyCompleted:
            return "A trusted reviewer has already completed this evidence contract."
        case .unavailable:
            return "Trusted review needs an active iCloud account."
        }
    }
}

struct TrustedReviewInvitation: Identifiable {
    let id: String
    let share: CKShare
    let container: CKContainer
}

struct TrustedReviewOwnerStatus {
    var state: TrustedReviewState
    var decisions: [ReviewDecision]
    var note: String
    var reviewedAt: Date?
}

enum TrustedReviewService {
    static let containerIdentifier = "iCloud.com.donaldlin.karteria"
    static let zoneName = "KarteriaTrustedReviews"
    static let recordType = "TrustedReviewSubmission"

    static var container: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    static func createInvitation(
        goal: GoalRecord,
        level: LevelRecord,
        baseline: [PreparedEvidenceMedia],
        checkpoint: [PreparedEvidenceMedia],
        explanation: String
    ) async throws -> TrustedReviewInvitation {
        guard level.criteria.count == 3 else { throw TrustedReviewError.missingContract }
        guard !baseline.isEmpty, !checkpoint.isEmpty else { throw TrustedReviewError.missingLocalEvidence }

        let database = container.privateCloudDatabase
        try await ensureReviewZone(in: database)

        let recordID = privateRecordID(named: "trusted-\(level.id.uuidString)")
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["goalTitle"] = goal.title as NSString
        record["contractTitle"] = level.contractTitle as NSString
        record["baselineSummary"] = level.baselineSummary as NSString
        record["criteriaJSON"] = try criteriaJSONString(level.criteria) as NSString
        record["explanation"] = String(explanation.prefix(EvidenceLimits.maximumExplanationCharacters)) as NSString
        record["trustedReviewStatus"] = "pending" as NSString
        record["submittedAt"] = Date() as NSDate
        try attach(baseline, with: "baseline", to: record)
        try attach(checkpoint, with: "checkpoint", to: record)

        let share = CKShare(rootRecord: record)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Karteria trusted review: \(level.contractTitle)" as NSString
        share[CKShare.SystemFieldKey.shareType] = "com.donaldlin.karteria.trusted-review" as NSString

        let changes = try await database.modifyRecords(
            saving: [record, share],
            deleting: [],
            savePolicy: .allKeys,
            atomically: true
        )
        for result in changes.saveResults.values {
            if let savedRecord = try? result.get(), let savedShare = savedRecord as? CKShare {
                return TrustedReviewInvitation(
                    id: recordID.recordName,
                    share: savedShare,
                    container: container
                )
            }
        }
        throw TrustedReviewError.missingShare
    }

    static func pendingSharedWorkItems() async throws -> [ReviewWorkItem] {
        let query = CKQuery(
            recordType: recordType,
            predicate: NSPredicate(format: "trustedReviewStatus == %@", "pending")
        )
        let results = try await container.sharedCloudDatabase.records(
            matching: query,
            resultsLimit: 20
        )
        return results.matchResults.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return workItem(from: record)
        }
    }

    static func ownerStatus(recordName: String) async throws -> TrustedReviewOwnerStatus {
        let record = try await container.privateCloudDatabase.record(for: privateRecordID(named: recordName))
        let isCompleted = (record["trustedReviewStatus"] as? String) == "completed"
        return TrustedReviewOwnerStatus(
            state: isCompleted ? .completed : .awaitingResponse,
            decisions: decisions(from: record),
            note: record["trustedReviewerNote"] as? String ?? "",
            reviewedAt: record["trustedReviewedAt"] as? Date
        )
    }

    static func removeOwnedInvitation(recordName: String) async throws {
        let database = container.privateCloudDatabase
        let recordID = privateRecordID(named: recordName)
        do {
            _ = try await database.modifyRecords(
                saving: [],
                deleting: [recordID],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return
        }
    }

    static func submit(
        decisions: [ReviewDecision],
        note: String,
        locator: TrustedReviewLocator
    ) async throws {
        guard decisions.count == 3 else { throw TrustedReviewError.missingContract }
        let database = container.sharedCloudDatabase
        let record = try await database.record(for: sharedRecordID(for: locator))
        guard (record["trustedReviewStatus"] as? String) == "pending" else {
            throw TrustedReviewError.alreadyCompleted
        }

        record["trustedReviewStatus"] = "completed" as NSString
        record["trustedDecision1"] = decisions[0].rawValue as NSString
        record["trustedDecision2"] = decisions[1].rawValue as NSString
        record["trustedDecision3"] = decisions[2].rawValue as NSString
        record["trustedReviewerNote"] = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280)) as NSString
        record["trustedReviewedAt"] = Date() as NSDate
        _ = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
    }

    static func accept(_ metadata: CKShare.Metadata) {
        let shareContainer = CKContainer(identifier: metadata.containerIdentifier)
        let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
        operation.perShareResultBlock = { _, _ in }
        shareContainer.add(operation)
    }

    private static func ensureReviewZone(in database: CKDatabase) async throws {
        let zoneID = privateZoneID
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneName: zoneName))
        }
    }

    private static var privateZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private static func privateRecordID(named recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: privateZoneID)
    }

    private static func sharedRecordID(for locator: TrustedReviewLocator) -> CKRecord.ID {
        CKRecord.ID(
            recordName: locator.recordName,
            zoneID: CKRecordZone.ID(zoneName: locator.zoneName, ownerName: locator.ownerName)
        )
    }

    private static func criteriaJSONString(_ criteria: [RubricCriterion]) throws -> String {
        let values = criteria.map(\.title)
        let data = try JSONEncoder().encode(values)
        return String(decoding: data, as: UTF8.self)
    }

    private static func attach(
        _ media: [PreparedEvidenceMedia],
        with prefix: String,
        to record: CKRecord
    ) throws {
        for (index, item) in media.enumerated() {
            let fileURL = EvidenceMediaStore.localURL(for: item.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw TrustedReviewError.missingLocalEvidence
            }
            let fieldIndex = index + 1
            record["\(prefix)Asset\(fieldIndex)"] = CKAsset(fileURL: fileURL)
            record["\(prefix)Kind\(fieldIndex)"] = item.kind.rawValue as NSString
        }
    }

    private static func workItem(from record: CKRecord) -> ReviewWorkItem? {
        guard let contractTitle = record["contractTitle"] as? String else { return nil }
        let criteria = decodeCriteria(record["criteriaJSON"] as? String)
        guard criteria.count == 3 else { return nil }
        let locator = TrustedReviewLocator(
            recordName: record.recordID.recordName,
            zoneName: record.recordID.zoneID.zoneName,
            ownerName: record.recordID.zoneID.ownerName
        )
        return ReviewWorkItem(
            kind: .trustedReview,
            contractTitle: contractTitle,
            context: "A person you know invited this private, evidence-only review. It never counts as an anonymous 2-of-3 vote.",
            criteria: criteria,
            baseline: preview(
                from: record,
                prefix: "baseline",
                label: "Baseline",
                summary: record["baselineSummary"] as? String ?? "Baseline evidence"
            ),
            checkpoint: preview(
                from: record,
                prefix: "checkpoint",
                label: "Checkpoint",
                summary: record["explanation"] as? String ?? "Checkpoint evidence"
            ),
            trustedReviewLocator: locator
        )
    }

    private static func preview(
        from record: CKRecord,
        prefix: String,
        label: String,
        summary: String
    ) -> ReviewEvidencePreview {
        var localFileURLs: [URL] = []
        var mediaKind: EvidenceMediaKind?
        for index in 1...EvidenceLimits.maximumImages {
            if let asset = record["\(prefix)Asset\(index)"] as? CKAsset,
               let fileURL = asset.fileURL {
                localFileURLs.append(fileURL)
            }
            if mediaKind == nil,
               let rawKind = record["\(prefix)Kind\(index)"] as? String {
                mediaKind = EvidenceMediaKind(rawValue: rawKind)
            }
        }
        return ReviewEvidencePreview(
            label: label,
            summary: summary,
            localFileURLs: localFileURLs,
            mediaKind: mediaKind
        )
    }

    private static func decodeCriteria(_ rawValue: String?) -> [RubricCriterion] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values.map { RubricCriterion(title: $0) }
    }

    private static func decisions(from record: CKRecord) -> [ReviewDecision] {
        (1...3).compactMap { index in
            guard let rawValue = record["trustedDecision\(index)"] as? String else { return nil }
            return ReviewDecision(rawValue: rawValue)
        }
    }
}

struct TrustedReviewShareSheet: UIViewControllerRepresentable {
    let invitation: TrustedReviewInvitation

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: invitation.share,
            container: invitation.container
        )
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}
}
