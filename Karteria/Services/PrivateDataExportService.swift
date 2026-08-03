import Foundation
import SwiftData
import ZIPFoundation

@MainActor
enum PrivateDataExportService {
    static func prepareArchive(modelContext: ModelContext) throws -> URL {
        let profiles = try modelContext.fetch(FetchDescriptor<ProfileRecord>())
        let goals = try modelContext.fetch(FetchDescriptor<GoalRecord>())
        let levels = try modelContext.fetch(FetchDescriptor<LevelRecord>())
        let reps = try modelContext.fetch(FetchDescriptor<PracticeRepRecord>())
        let evidence = try modelContext.fetch(FetchDescriptor<EvidenceRecord>())

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Karteria-Export-\(UUID().uuidString)", isDirectory: true)
        let evidenceDirectory = directory.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        let document = PrivateJourneyExport(
            exportedAt: .now,
            profile: profiles.sorted { $0.createdAt < $1.createdAt }.first.map(ProfileExport.init),
            goals: goals.map(GoalExport.init),
            levels: levels.map(LevelExport.init),
            practiceReps: reps.map(PracticeRepExport.init),
            evidence: evidence.map(EvidenceExport.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: directory.appendingPathComponent("Karteria-Journey.json"),
            options: .atomic
        )

        for item in evidence {
            let source = EvidenceMediaStore.localURL(for: item.localRelativePath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let extensionName = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let destination = evidenceDirectory
                .appendingPathComponent(item.id.uuidString)
                .appendingPathExtension(extensionName)
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let archive = directory.deletingPathExtension().appendingPathExtension("zip")
        let zip = try Archive(url: archive, accessMode: .create)
        try zip.addEntry(with: "Karteria-Journey.json", relativeTo: directory, compressionMethod: .deflate)
        let copiedEvidence = try FileManager.default.contentsOfDirectory(
            at: evidenceDirectory,
            includingPropertiesForKeys: nil
        )
        for file in copiedEvidence {
            try zip.addEntry(
                with: "Evidence/\(file.lastPathComponent)",
                relativeTo: directory,
                compressionMethod: .deflate
            )
        }
        return archive
    }

    static func erasePrivateJourney(modelContext: ModelContext) throws {
        try EvidenceMediaStore.eraseAllPersistedEvidence()
        for profile in try modelContext.fetch(FetchDescriptor<ProfileRecord>()) {
            modelContext.delete(profile)
        }
        for goal in try modelContext.fetch(FetchDescriptor<GoalRecord>()) {
            modelContext.delete(goal)
        }
        for level in try modelContext.fetch(FetchDescriptor<LevelRecord>()) {
            modelContext.delete(level)
        }
        for rep in try modelContext.fetch(FetchDescriptor<PracticeRepRecord>()) {
            modelContext.delete(rep)
        }
        for item in try modelContext.fetch(FetchDescriptor<EvidenceRecord>()) {
            modelContext.delete(item)
        }
        try modelContext.save()
    }
}

private struct PrivateJourneyExport: Codable {
    var schemaVersion = 1
    var product = "Karteria"
    var exportedAt: Date
    var profile: ProfileExport?
    var goals: [GoalExport]
    var levels: [LevelExport]
    var practiceReps: [PracticeRepExport]
    var evidence: [EvidenceExport]
}

private struct ProfileExport: Codable {
    var createdAt: Date
    var reviewCredits: Int
    var calibrationCompleted: Int
    var calibrationCorrect: Int
    var calibrationStatus: String
    var birthDate: Date?

    init(_ profile: ProfileRecord) {
        createdAt = profile.createdAt
        reviewCredits = profile.reviewCredits
        calibrationCompleted = profile.calibrationCompleted
        calibrationCorrect = profile.calibrationCorrect
        calibrationStatus = profile.calibrationStatusRaw
        birthDate = profile.birthDate
    }
}

private struct GoalExport: Codable {
    var id: UUID
    var identityStatement: String
    var title: String
    var outcomeStatement: String
    var status: String
    var createdAt: Date
    var updatedAt: Date
    var scheduleWeekdays: String
    var scheduleHour: Int
    var activeLevelNumber: Int

    init(_ goal: GoalRecord) {
        id = goal.id
        identityStatement = goal.identityStatement
        title = goal.title
        outcomeStatement = goal.outcomeStatement
        status = goal.statusRaw
        createdAt = goal.createdAt
        updatedAt = goal.updatedAt
        scheduleWeekdays = goal.scheduleWeekdays
        scheduleHour = goal.scheduleHour
        activeLevelNumber = goal.activeLevelNumber
    }
}

private struct LevelExport: Codable {
    var id: UUID
    var goalID: UUID
    var number: Int
    var title: String
    var focus: String
    var status: String
    var contractTitle: String
    var baselineSummary: String
    var criteria: [String]
    var submittedAt: Date?
    var settledAt: Date?
    var settlementOutcome: String?
    var reviewSubmissionID: UUID?
    var trustedReviewRecordName: String?
    var trustedReviewState: String
    var trustedReviewNote: String
    var trustedReviewedAt: Date?

    init(_ level: LevelRecord) {
        id = level.id
        goalID = level.goalID
        number = level.number
        title = level.title
        focus = level.focus
        status = level.statusRaw
        contractTitle = level.contractTitle
        baselineSummary = level.baselineSummary
        criteria = [level.criterionOne, level.criterionTwo, level.criterionThree]
        submittedAt = level.submittedAt
        settledAt = level.settledAt
        settlementOutcome = level.settlementOutcomeRaw
        reviewSubmissionID = level.reviewSubmissionID
        trustedReviewRecordName = level.trustedReviewRecordName
        trustedReviewState = level.trustedReviewStateRaw
        trustedReviewNote = level.trustedReviewNote
        trustedReviewedAt = level.trustedReviewedAt
    }
}

private struct PracticeRepExport: Codable {
    var id: UUID
    var goalID: UUID
    var levelID: UUID
    var completedAt: Date
    var minutes: Int
    var note: String
    var usedTwoMinuteFallback: Bool

    init(_ rep: PracticeRepRecord) {
        id = rep.id
        goalID = rep.goalID
        levelID = rep.levelID
        completedAt = rep.completedAt
        minutes = rep.minutes
        note = rep.note
        usedTwoMinuteFallback = rep.usedTwoMinuteFallback
    }
}

private struct EvidenceExport: Codable {
    var id: UUID
    var goalID: UUID
    var levelID: UUID
    var kind: String
    var exportedFileName: String
    var byteCount: Int
    var durationSeconds: Double
    var caption: String
    var isBaseline: Bool
    var createdAt: Date

    init(_ evidence: EvidenceRecord) {
        id = evidence.id
        goalID = evidence.goalID
        levelID = evidence.levelID
        kind = evidence.kindRaw
        let source = URL(fileURLWithPath: evidence.localRelativePath)
        let extensionName = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        exportedFileName = "Evidence/\(evidence.id.uuidString).\(extensionName)"
        byteCount = evidence.byteCount
        durationSeconds = evidence.durationSeconds
        caption = evidence.caption
        isBaseline = evidence.isBaseline
        createdAt = evidence.createdAt
    }
}
