import AVKit
import SwiftUI
import UIKit

struct KarteriaHeader: View {
    let section: String
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KarteriaMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Karteria")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.karteriaInk)
                Text(section.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.karteriaCobalt)
            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Settings")
        }
    }
}

struct ReviewSeatDiagram: View {
    let levelStatus: LevelStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private var labels: [(String, Color)] {
        switch levelStatus {
        case .awaitingReview:
            return [("Open", .karteriaCobalt), ("Open", .karteriaCobalt), ("Open", .karteriaCobalt)]
        case .verified:
            return [("Met", .karteriaSignal), ("Met", .karteriaSignal), ("Met", .karteriaSignal)]
        case .needsMorePractice:
            return [("Review", .karteriaCoral), ("Review", .karteriaCoral), ("Review", .karteriaSignal)]
        default:
            return [("Seat", .karteriaLine), ("Seat", .karteriaLine), ("Seat", .karteriaLine)]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let center = CGPoint(x: width * 0.5, y: 76)
            ZStack {
                Path { path in
                    [0.16, 0.50, 0.84].forEach { position in
                        path.move(to: CGPoint(x: width * position, y: 26))
                        path.addLine(to: center)
                    }
                }
                .stroke(Color.karteriaLine, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    VStack(spacing: 5) {
                        Circle()
                            .fill(label.1)
                            .frame(width: 24, height: 24)
                            .overlay {
                                Image(systemName: levelStatus == .verified ? "checkmark" : "person.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        Text(label.0)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.karteriaMuted)
                    }
                    .position(x: width * [0.16, 0.50, 0.84][index], y: 28)
                    .opacity(hasAppeared ? 1 : 0)
                    .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.82)
                }

                Circle()
                    .fill(levelStatus == .verified ? Color.karteriaSignal : Color.karteriaInk)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: levelStatus == .verified ? "checkmark.seal.fill" : "checkmark")
                            .foregroundStyle(.white)
                            .font(.headline)
                    }
                    .position(center)
            }
        }
        .frame(height: 104)
        .task {
            guard !reduceMotion else {
                hasAppeared = true
                return
            }
            withAnimation(.easeOut(duration: 0.42)) {
                hasAppeared = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Three anonymous review seats converge on one verification result")
    }
}

struct EvidenceComparisonScrubber: View {
    let baseline: ReviewEvidencePreview
    let checkpoint: ReviewEvidencePreview

    @State private var split: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    EvidencePreviewPanel(
                        evidence: checkpoint,
                        accent: .karteriaSignal
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)

                    EvidencePreviewPanel(
                        evidence: baseline,
                        accent: .karteriaCoral
                    )
                    .frame(width: max(0, proxy.size.width * split), height: proxy.size.height)
                    .clipped()

                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .shadow(radius: 1)
                        .position(x: proxy.size.width * split, y: proxy.size.height * 0.5)

                    Circle()
                        .fill(Color.karteriaInk)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .position(x: proxy.size.width * split, y: proxy.size.height * 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            split = min(max(value.location.x / max(proxy.size.width, 1), 0.05), 0.95)
                        }
                )
            }
            .frame(height: 230)

            HStack {
                Text("Before")
                Slider(value: $split, in: 0.05...0.95)
                    .tint(.karteriaCobalt)
                Text("After")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.karteriaMuted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before and after evidence comparison")
    }
}

struct EvidencePreviewPanel: View {
    let evidence: ReviewEvidencePreview
    let accent: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.karteriaInk
            media

            VStack(alignment: .leading, spacing: 6) {
                Text(evidence.label.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Text(evidence.summary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.karteriaInk.opacity(0.82), in: Rectangle())

            Rectangle()
                .fill(accent)
                .frame(height: 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder
    private var media: some View {
        if let url = evidence.localFileURLs.first {
            if evidence.mediaKind == .video {
                VideoPlayer(player: AVPlayer(url: url))
                    .accessibilityLabel("Video evidence. Use the playback controls to inspect it.")
            } else if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                evidenceFallback
            }
        } else if let url = evidence.remoteURLs.first {
            if evidence.mediaKind == .video {
                VideoPlayer(player: AVPlayer(url: url))
                    .accessibilityLabel("Video evidence. Use the playback controls to inspect it.")
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        evidenceFallback
                    default:
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        } else {
            evidenceFallback
        }
    }

    private var evidenceFallback: some View {
        VStack(spacing: 10) {
            Image(systemName: evidence.mediaKind == .video ? "video" : "photo")
                .font(.title2)
            Text("Evidence preview")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.78))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusChip: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}
