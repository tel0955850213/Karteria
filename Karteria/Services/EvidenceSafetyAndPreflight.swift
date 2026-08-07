import AVFoundation
import CoreImage
import Foundation
import Speech
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(SensitiveContentAnalysis)
import SensitiveContentAnalysis
#endif

enum EvidenceSafetyWarning: Equatable, Hashable, Identifiable {
    case personalInformation
    case safetyScanUnavailable
    case audioNotTranscribed

    var id: String {
        switch self {
        case .personalInformation: return "personal-information"
        case .safetyScanUnavailable: return "safety-scan-unavailable"
        case .audioNotTranscribed: return "audio-not-transcribed"
        }
    }

    var message: String {
        switch self {
        case .personalInformation:
            return "Possible personal information was found in visible text. Crop or blur it before sharing."
        case .safetyScanUnavailable:
            return "Sensitive-content analysis is unavailable on this device. Check the evidence manually."
        case .audioNotTranscribed:
            return "Audio transcription is unavailable. Reviewers will judge only the visible evidence and any written context."
        }
    }
}

enum EvidenceSafetyOutcome: Equatable {
    case clear(warnings: [EvidenceSafetyWarning])
    case blocked(reason: String)

    var warnings: [EvidenceSafetyWarning] {
        switch self {
        case .clear(let warnings): return warnings
        case .blocked: return []
        }
    }
}

enum EvidenceSafetyInspector {
    static func inspect(_ media: [PreparedEvidenceMedia]) async -> EvidenceSafetyOutcome {
        var warnings: Set<EvidenceSafetyWarning> = []
        for item in media {
            let url = EvidenceMediaStore.localURL(for: item.relativePath)
            do {
                if try await containsSensitiveContent(at: url, kind: item.kind) {
                    return .blocked(reason: "Sensitive content cannot enter anonymous review. Keep this evidence in your private journey instead.")
                }
            } catch {
                warnings.insert(.safetyScanUnavailable)
            }

            if item.kind == .image, containsPersonalInformation(at: url) {
                warnings.insert(.personalInformation)
            }
            if item.kind == .video, await EvidenceTranscriptService.transcriptIfAuthorized(for: url) == nil {
                warnings.insert(.audioNotTranscribed)
            }
        }
        return .clear(warnings: warnings.sorted { $0.id < $1.id })
    }

    private static func containsPersonalInformation(at url: URL) -> Bool {
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            return containsPIIPattern(in: text)
        } catch {
            return false
        }
    }

    private static func containsPIIPattern(in text: String) -> Bool {
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"(?:\+?\d[\d\s().-]{7,}\d)"#,
            #"(?:https?://|www\.)\S+"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func containsSensitiveContent(at url: URL, kind: EvidenceMediaKind) async throws -> Bool {
        #if canImport(SensitiveContentAnalysis)
        let analyzer = SCSensitivityAnalyzer()
        guard analyzer.analysisPolicy != .disabled else { return false }
        let analysis: SCSensitivityAnalysis
        switch kind {
        case .image:
            analysis = try await analyzer.analyzeImage(at: url)
        case .video:
            analysis = try await analyzer.videoAnalysis(forFileAt: url).hasSensitiveContent()
        }
        return analysis.isSensitive
        #else
        return false
        #endif
    }
}

enum EvidenceTranscriptService {
    static func transcriptIfAuthorized(for videoURL: URL) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable
        else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    _ = error
                    continuation.resume(returning: nil)
                } else if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

enum VideoEvidenceFrames {
    static func imageURLs(from media: [PreparedEvidenceMedia]) async throws -> [URL] {
        var urls: [URL] = []
        for item in media {
            let sourceURL = EvidenceMediaStore.localURL(for: item.relativePath)
            switch item.kind {
            case .image:
                urls.append(sourceURL)
            case .video:
                urls.append(contentsOf: try await extractFrames(from: sourceURL))
            }
        }
        return urls
    }

    private static func extractFrames(from url: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let positions = [0.05, 0.5, 0.95]
        var frameURLs: [URL] = []
        for position in positions {
            let time = CMTime(seconds: duration * position, preferredTimescale: 600)
            let generated = try await generator.image(at: time)
            let image = generated.image
            guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.75) else { continue }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("karteria-frame-\(UUID().uuidString)")
                .appendingPathExtension("jpg")
            try data.write(to: destination, options: .atomic)
            frameURLs.append(destination)
        }
        return frameURLs
    }
}

enum EvidencePreflightSource: String, Equatable {
    case onDeviceModel
    case manualChecklist
}

struct EvidencePreflightResult: Equatable {
    var source: EvidencePreflightSource
    var coverage: [Bool]
    var summary: String
    var warnings: [String]

    var allCriteriaAppearCovered: Bool { coverage.count == 3 && coverage.allSatisfy { $0 } }
}

@MainActor
final class EvidencePreflightService: ObservableObject {
    func assess(
        contract: EvidenceContract,
        media: [PreparedEvidenceMedia],
        explanation: String
    ) async -> EvidencePreflightResult {
        let manual = EvidencePreflightResult(
            source: .manualChecklist,
            coverage: Array(repeating: false, count: contract.criteria.count),
            summary: "Use the contract to confirm that each criterion is visible in the selected evidence.",
            warnings: []
        )

        #if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27.0, *), SystemLanguageModel.default.isAvailable else { return manual }
        do {
            return try await runOnDeviceAssessment(
                contract: contract,
                media: media,
                explanation: explanation,
                fallback: manual
            )
        } catch {
            return manual
        }
        #else
        return manual
        #endif
    }

    #if compiler(>=6.4) && canImport(FoundationModels)
    @available(iOS 27.0, *)
    private func runOnDeviceAssessment(
        contract: EvidenceContract,
        media: [PreparedEvidenceMedia],
        explanation: String,
        fallback: EvidencePreflightResult
    ) async throws -> EvidencePreflightResult {
        let urls = try await VideoEvidenceFrames.imageURLs(from: media)
        let attachments = urls.prefix(6).map {
            Attachment(imageURL: $0).label("evidence-\($0.lastPathComponent)")
        }
        let criteria = contract.criteria.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: "You only help a person check their evidence before submission. You never vote, approve, reject, or infer facts that are not visibly shown.")
        let response = try await session.respond {
            """
            Inspect the attached evidence against these three observable criteria:\n\(criteria)

            The submitter's context is: \(String(explanation.prefix(EvidenceLimits.maximumExplanationCharacters)))

            Return strict JSON only with this shape:
            {"coverage":[true,false,true],"summary":"short factual advice","warnings":["short warning"]}
            Mark a criterion false when it is not visibly demonstrated. Do not make a pass or fail decision.
            """
            attachments
        }
        guard let advice = try? JSONDecoder().decode(ModelAdvice.self, from: Data(response.content.utf8)),
              advice.coverage.count == 3
        else { return fallback }
        return EvidencePreflightResult(
            source: .onDeviceModel,
            coverage: advice.coverage,
            summary: String(advice.summary.prefix(500)),
            warnings: advice.warnings.map { String($0.prefix(160)) }
        )
    }
    #endif
}

private struct ModelAdvice: Decodable {
    var coverage: [Bool]
    var summary: String
    var warnings: [String]
}

enum EvidenceImageRedactor {
    static func crop(image: UIImage, normalizedRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let bounds = CGRect(origin: .zero, size: CGSize(width: cgImage.width, height: cgImage.height))
        let rect = CGRect(
            x: normalizedRect.minX * bounds.width,
            y: normalizedRect.minY * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        ).intersection(bounds)
        guard let result = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }

    static func blur(image: UIImage, normalizedRect: CGRect, radius: CGFloat = 14) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let region = CGRect(
            x: normalizedRect.minX * extent.width,
            y: (1 - normalizedRect.maxY) * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).intersection(extent)
        guard !region.isNull else { return image }
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: region)
        let output = blurred.composited(over: input)
        guard let cgImage = CIContext().createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
