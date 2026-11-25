import SwiftUI

/// Brand colors. The gauge runs from ChatGPT teal to Claude orange.
enum Brand {
    static let teal = Color(red: 0.16, green: 0.83, blue: 0.78)
    static let amber = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let orange = Color(red: 0.96, green: 0.45, blue: 0.24)
    static let night = Color(red: 0.11, green: 0.12, blue: 0.24)
    static let ink = Color(red: 0.05, green: 0.06, blue: 0.13)
    static let gauge = Gradient(colors: [teal, amber, orange])
}

/// The AI Usage mark: a 270° gauge with a needle. Also rendered into the app icon (scripts/make-icon.swift).
struct LogoMark: View {
    var size: CGFloat
    /// Draws the dark squircle tile behind the gauge (app icon, header badge).
    var tile = true

    var body: some View {
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Brand.night, Brand.ink], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: max(0.5, size * 0.008))
            }
            gauge.frame(width: size * 0.62, height: size * 0.62).offset(y: size * 0.03)
        }
        .frame(width: size, height: size)
    }

    private var gauge: some View {
        GeometryReader { g in
            let s = g.size.width
            let line = s * 0.15
            ZStack {
                arc.stroke(.white.opacity(0.10), style: StrokeStyle(lineWidth: line, lineCap: .round))
                arc.stroke(AngularGradient(gradient: Brand.gauge, center: .center,
                                           startAngle: .degrees(135), endAngle: .degrees(405)),
                           style: StrokeStyle(lineWidth: line, lineCap: .round))
                // Needle, pivoting on the center.
                Capsule().fill(.white)
                    .frame(width: s * 0.075, height: s * 0.42)
                    .offset(y: -s * 0.17)
                    .rotationEffect(.degrees(38))
                    .shadow(color: .black.opacity(0.35), radius: s * 0.02, y: s * 0.01)
                Circle().fill(.white).frame(width: s * 0.17)
                Circle().fill(Brand.ink).frame(width: s * 0.065)
            }
            .frame(width: s, height: s)
        }
    }

    private var arc: some Shape {
        Circle().trim(from: 0, to: 0.75).rotation(.degrees(135))
    }
}

/// Title row at the top of the overview window.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            LogoMark(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Usage").font(.title3.weight(.bold))
                Text("Your plan limits, side by side").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview { LogoMark(size: 256).padding() }
