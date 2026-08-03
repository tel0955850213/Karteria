import SwiftUI

private enum RedactionGroup: String, CaseIterable, Identifiable {
    case baseline
    case checkpoint

    var id: String { rawValue }
    var title: String { self == .baseline ? "Baseline" : "Checkpoint" }
}

private enum RedactionMode: String, CaseIterable, Identifiable {
    case crop
    case blur

    var id: String { rawValue }
    var title: String { self == .crop ? "Crop" : "Blur" }
}

struct EvidenceRedactionSheet: View {
    @Binding var baseline: [PreparedEvidenceMedia]
    @Binding var checkpoint: [PreparedEvidenceMedia]
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var group: RedactionGroup = .baseline
    @State private var selectedID: UUID?
    @State private var mode: RedactionMode = .blur
    @State private var rectX: Double = 0.20
    @State private var rectY: Double = 0.20
    @State private var rectWidth: Double = 0.42
    @State private var rectHeight: Double = 0.24
    @State private var message: String?

    private var currentMedia: [PreparedEvidenceMedia] {
        (group == .baseline ? baseline : checkpoint).filter { $0.kind == .image }
    }

    private var selectedMedia: PreparedEvidenceMedia? {
        guard let selectedID else { return currentMedia.first }
        return currentMedia.first { $0.id == selectedID }
    }

    private var image: UIImage? {
        guard let selectedMedia else { return nil }
        return UIImage(contentsOfFile: EvidenceMediaStore.localURL(for: selectedMedia.relativePath).path)
    }

    private var normalizedRect: CGRect {
        CGRect(
            x: min(max(rectX, 0), 0.9),
            y: min(max(rectY, 0), 0.9),
            width: min(max(rectWidth, 0.08), 1 - rectX),
            height: min(max(rectHeight, 0.08), 1 - rectY)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Proof group", selection: $group) {
                        ForEach(RedactionGroup.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: group) { _, _ in
                        selectedID = currentMedia.first?.id
                    }

                    if currentMedia.isEmpty {
                        KarteriaSurface {
                            Text("This proof group has no editable image evidence.")
                                .font(.subheadline)
                                .foregroundStyle(Color.karteriaMuted)
                                .padding(16)
                        }
                    } else {
                        Picker("Image", selection: selectedBinding) {
                            ForEach(currentMedia) { media in
                                Text("Image \(currentMedia.firstIndex(where: { $0.id == media.id })! + 1)")
                                    .tag(Optional(media.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let image {
                            redactionPreview(image)
                        }

                        Picker("Tool", selection: $mode) {
                            ForEach(RedactionMode.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        redactionSliders

                        KarteriaPrimaryButton(
                            title: mode == .crop ? "Apply crop" : "Apply blur",
                            systemImage: mode == .crop ? "crop" : "eye.slash"
                        ) {
                            applyRedaction()
                        }
                    }
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("Redact proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Redact proof", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .onAppear {
                selectedID = currentMedia.first?.id
            }
        }
    }

    @ViewBuilder
    private func redactionPreview(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color.karteriaInk)
                Rectangle()
                    .stroke(mode == .crop ? Color.karteriaCobalt : Color.karteriaCoral, lineWidth: 3)
                    .background((mode == .crop ? Color.karteriaCobalt : Color.karteriaCoral).opacity(0.14))
                    .frame(
                        width: proxy.size.width * normalizedRect.width,
                        height: proxy.size.height * normalizedRect.height
                    )
                    .offset(
                        x: proxy.size.width * normalizedRect.minX,
                        y: proxy.size.height * normalizedRect.minY
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 260)
    }

    private var redactionSliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            redactionSlider("Left", value: $rectX)
            redactionSlider("Top", value: $rectY)
            redactionSlider("Width", value: $rectWidth)
            redactionSlider("Height", value: $rectHeight)
        }
    }

    private func redactionSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 42, alignment: .leading)
            Slider(value: value, in: 0.08...0.9)
                .tint(mode == .crop ? .karteriaCobalt : .karteriaCoral)
        }
    }

    private var selectedBinding: Binding<UUID?> {
        Binding(
            get: { selectedID ?? currentMedia.first?.id },
            set: { selectedID = $0 }
        )
    }

    private func applyRedaction() {
        guard let selectedMedia, let image else {
            message = "Karteria could not load this image proof."
            return
        }
        let result: UIImage?
        switch mode {
        case .crop:
            result = EvidenceImageRedactor.crop(image: image, normalizedRect: normalizedRect)
        case .blur:
            result = EvidenceImageRedactor.blur(image: image, normalizedRect: normalizedRect)
        }
        guard let result else {
            message = "Karteria could not apply this edit."
            return
        }
        guard let prospectiveData = result.jpegData(compressionQuality: 0.82) else {
            message = "Karteria could not encode this edited proof."
            return
        }
        let groupMedia = group == .baseline ? baseline : checkpoint
        let prospectiveGroupBytes = groupMedia
            .filter { $0.id != selectedMedia.id }
            .reduce(prospectiveData.count) { $0 + $1.byteCount }
        guard prospectiveGroupBytes <= EvidenceLimits.maximumBundleBytes else {
            message = EvidenceMediaError.bundleTooLarge.localizedDescription
            return
        }
        do {
            let updated = try EvidenceMediaStore.replaceImage(result, for: selectedMedia)
            if group == .baseline, let index = baseline.firstIndex(where: { $0.id == selectedMedia.id }) {
                baseline[index] = updated
            }
            if group == .checkpoint, let index = checkpoint.firstIndex(where: { $0.id == selectedMedia.id }) {
                checkpoint[index] = updated
            }
            onChanged()
        } catch {
            message = error.localizedDescription
        }
    }
}
