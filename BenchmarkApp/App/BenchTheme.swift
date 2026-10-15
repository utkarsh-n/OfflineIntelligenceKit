import SwiftUI

enum BenchTheme {
    static let canvas = Color(red: 0.025, green: 0.042, blue: 0.058)
    static let panel = Color(red: 0.045, green: 0.070, blue: 0.087)
    static let metalLight = Color(red: 0.055, green: 0.073, blue: 0.090)
    static let metalDark = Color(red: 0.021, green: 0.032, blue: 0.042)
    static let cyan = Color(red: 0.34, green: 0.93, blue: 0.96)
    static let amber = Color(red: 1, green: 0.74, blue: 0.37)
    static let violet = Color(red: 0.76, green: 0.57, blue: 1)
    static let ink = Color(red: 0.91, green: 0.95, blue: 0.97)
    static let secondary = Color(red: 0.60, green: 0.69, blue: 0.73)
}

struct BenchBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            BenchTheme.canvas
            if !reduceTransparency {
                RadialGradient(colors: [BenchTheme.cyan.opacity(0.065), .clear], center: .topTrailing, startRadius: 4, endRadius: 620)
            }
            Canvas { context, size in
                var path = Path()
                for x in stride(from: 0.0, through: size.width, by: 28) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 28) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.025)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BenchPanel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BenchTheme.panel, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(contrast == .increased ? 0.22 : 0.09), lineWidth: 1)
            }
    }
}

struct MetricReadout: View {
    let label: String
    let value: String
    let unit: String
    var accent: Color = BenchTheme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(BenchTheme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.caption2.monospaced())
                    .foregroundStyle(BenchTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value == "—" ? "Not measured" : "\(value) \(unit)")
    }
}
