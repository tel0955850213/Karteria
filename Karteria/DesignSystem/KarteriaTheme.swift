import SwiftUI

extension Color {
    static let karteriaInk = Color(red: 0.10, green: 0.11, blue: 0.12)
    static let karteriaPaper = Color(red: 0.98, green: 0.96, blue: 0.92)
    static let karteriaCobalt = Color(red: 0.08, green: 0.31, blue: 0.84)
    static let karteriaCoral = Color(red: 0.90, green: 0.27, blue: 0.22)
    static let karteriaSignal = Color(red: 0.10, green: 0.62, blue: 0.35)
    static let karteriaLine = Color(red: 0.80, green: 0.78, blue: 0.72)
    static let karteriaMuted = Color(red: 0.38, green: 0.38, blue: 0.36)
}

struct KarteriaMark: View {
    var size: CGFloat = 30
    var accent: Color = .karteriaCobalt

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: max(2, size.width * 0.085), lineCap: .round, lineJoin: .round)
            let top = Path { path in
                path.move(to: CGPoint(x: size.width * 0.12, y: size.height * 0.16))
                path.addLine(to: CGPoint(x: size.width * 0.49, y: size.height * 0.50))
                path.addLine(to: CGPoint(x: size.width * 0.88, y: size.height * 0.18))
            }
            let bottom = Path { path in
                path.move(to: CGPoint(x: size.width * 0.12, y: size.height * 0.84))
                path.addLine(to: CGPoint(x: size.width * 0.49, y: size.height * 0.50))
                path.addLine(to: CGPoint(x: size.width * 0.88, y: size.height * 0.82))
            }
            let spine = Path { path in
                path.move(to: CGPoint(x: size.width * 0.12, y: size.height * 0.16))
                path.addLine(to: CGPoint(x: size.width * 0.12, y: size.height * 0.84))
            }
            context.stroke(top, with: .color(accent), style: stroke)
            context.stroke(bottom, with: .color(.karteriaCoral), style: stroke)
            context.stroke(spine, with: .color(.karteriaInk), style: stroke)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Karteria")
    }
}

struct KarteriaSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.karteriaLine.opacity(0.75), lineWidth: 1)
            }
    }
}

struct KarteriaPrimaryButton: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(.karteriaCobalt)
        .accessibilityHint(title == "Review Next" ? "Opens the next anonymous review" : "")
    }
}

struct KarteriaSectionHeading: View {
    let eyebrow: String
    let title: String
    let detail: String?

    init(_ eyebrow: String, title: String, detail: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.karteriaCobalt)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.karteriaInk)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.karteriaMuted)
            }
        }
    }
}

extension View {
    func karteriaPage() -> some View {
        self
            .background(Color.karteriaPaper)
            .tint(.karteriaCobalt)
    }
}
