import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum EvidenceMediaKind: String, Codable {
    case image
    case video
}

struct PreparedEvidenceMedia: Equatable, Identifiable {
    let id: UUID
    var kind: EvidenceMediaKind
    var relativePath: String
    var byteCount: Int
    var duration: TimeInterval
}

enum EvidenceMediaError: LocalizedError {
    case noSelection
    case tooManyImages
    case mixedFormats
    case videoTooLong
    case bundleTooLarge
    case unreadableMedia
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .noSelection: return "Add proof media before submitting this checkpoint."
        case .tooManyImages: return "Each proof group accepts up to three images."
        case .mixedFormats: return "Use either images or one video for each proof group."
        case .videoTooLong: return "Proof videos must be 20 seconds or shorter."
        case .bundleTooLarge: return "Compressed proof media must be 15 MB or smaller for each group."
        case .unreadableMedia: return "Karteria could not read one of the selected items."
        case .compressionFailed: return "Karteria could not prepare this video for review."
        }
    }
}

struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let extensionName = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("karteria-import-\(UUID().uuidString)")
                .appendingPathExtension(extensionName)
            try FileManager.default.copyItem(at: source, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}

enum EvidenceMediaStore {
    static func prepareImages(from items: [PhotosPickerItem]) async throws -> [PreparedEvidenceMedia] {
        guard !items.isEmpty else { throw EvidenceMediaError.noSelection }
        guard items.count <= EvidenceLimits.maximumImages else { throw EvidenceMediaError.tooManyImages }
        var prepared: [PreparedEvidenceMedia] = []
        for item in items {
            guard let sourceData = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: sourceData),
                  let jpegData = image.jpegData(compressionQuality: 0.82)
            else { throw EvidenceMediaError.unreadableMedia }
            let relativePath = try persist(data: jpegData, extensionName: "jpg")
            prepared.append(PreparedEvidenceMedia(
                id: UUID(),
                kind: .image,
                relativePath: relativePath,
                byteCount: jpegData.count,
                duration: 0
            ))
        }
        try validateBundle(prepared)
        return prepared
    }

    static func prepareVideo(from item: PhotosPickerItem?) async throws -> [PreparedEvidenceMedia] {
        guard let item else { throw EvidenceMediaError.noSelection }
        guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
            throw EvidenceMediaError.unreadableMedia
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let asset = AVURLAsset(url: movie.url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0, seconds <= EvidenceLimits.maximumVideoDuration else {
            throw EvidenceMediaError.videoTooLong
        }
        let outputURL = try await compressVideo(movie.url)
        let size = try fileSize(at: outputURL)
        let relativePath = try moveToLibrary(outputURL, extensionName: "mp4")
        let prepared = PreparedEvidenceMedia(
            id: UUID(),
            kind: .video,
            relativePath: relativePath,
            byteCount: size,
            duration: seconds
        )
        try validateBundle([prepared])
        return [prepared]
    }

    static func localURL(for relativePath: String) -> URL {
        evidenceDirectory.appendingPathComponent(relativePath)
    }

    static func eraseAllPersistedEvidence() throws {
        guard FileManager.default.fileExists(atPath: evidenceDirectory.path) else { return }
        try FileManager.default.removeItem(at: evidenceDirectory)
    }

    static func replaceImage(_ image: UIImage, for media: PreparedEvidenceMedia) throws -> PreparedEvidenceMedia {
        guard media.kind == .image,
              let jpegData = image.jpegData(compressionQuality: 0.82)
        else { throw EvidenceMediaError.unreadableMedia }
        guard jpegData.count <= EvidenceLimits.maximumBundleBytes else {
            throw EvidenceMediaError.bundleTooLarge
        }
        try jpegData.write(to: localURL(for: media.relativePath), options: .atomic)
        var updated = media
        updated.byteCount = jpegData.count
        return updated
    }

    private static func validateBundle(_ items: [PreparedEvidenceMedia]) throws {
        guard !items.isEmpty else { throw EvidenceMediaError.noSelection }
        let kinds = Set(items.map(\.kind))
        guard kinds.count == 1 else { throw EvidenceMediaError.mixedFormats }
        guard !(kinds.contains(.video) && items.count > 1) else { throw EvidenceMediaError.mixedFormats }
        guard items.reduce(0, { $0 + $1.byteCount }) <= EvidenceLimits.maximumBundleBytes else {
            throw EvidenceMediaError.bundleTooLarge
        }
    }

    private static var evidenceDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Karteria/Evidence", isDirectory: true)
    }

    private static func persist(data: Data, extensionName: String) throws -> String {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(extensionName)"
        try data.write(to: evidenceDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    private static func moveToLibrary(_ source: URL, extensionName: String) throws -> String {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(extensionName)"
        let destination = evidenceDirectory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: source, to: destination)
        return name
    }

    private static func fileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private static func compressVideo(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw EvidenceMediaError.compressionFailed
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("karteria-export-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await exporter.export(to: outputURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw EvidenceMediaError.compressionFailed
        }
        return outputURL
    }
}
