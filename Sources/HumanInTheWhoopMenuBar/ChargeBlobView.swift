import SwiftUI

/// A read-only ambient visualization of the validated Charge ledger.
///
/// The membrane and particles are deterministic, contain no mutation path,
/// and stop moving when the user enables Reduce Motion.
struct ChargeBlobView: View {
    let score: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                OrganicChargeBlobCanvas(
                    elapsed: reduceMotion ? 0 : elapsed,
                    isActive: score != nil
                )
                .accessibilityHidden(true)

                Text(score.map(String.init) ?? "—")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
            }
        }
        .frame(height: 306)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let score else { return "Charge unavailable" }
        return "Charge score \(score) out of 100"
    }
}

private struct OrganicChargeBlobCanvas: View {
    let elapsed: TimeInterval
    let isActive: Bool

    private let upperBlue = Color(red: 0.25, green: 0.54, blue: 0.75)
    private let sideTeal = Color(red: 0.35, green: 0.57, blue: 0.61)
    private let lowerGreen = Color(red: 0.45, green: 0.56, blue: 0.39)

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 13)
            let phase = elapsed * 0.20
            let membrane = blobPath(in: bounds, phase: phase, movement: isActive ? 1 : 0.18)
            let center = CGPoint(
                x: size.width * 0.51 + CGFloat(sin(phase * 0.72)) * 2,
                y: size.height * 0.50 + CGFloat(cos(phase * 0.61)) * 2
            )
            let radius = min(bounds.width, bounds.height) * 0.49

            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 14))
                glow.stroke(
                    membrane,
                    with: .linearGradient(
                        Gradient(colors: [upperBlue.opacity(0.28), lowerGreen.opacity(0.20)]),
                        startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                        endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
                    ),
                    lineWidth: 11
                )
            }

            context.fill(
                membrane,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: upperBlue.opacity(isActive ? 0.98 : 0.48), location: 0),
                        .init(color: sideTeal.opacity(isActive ? 0.92 : 0.44), location: 0.52),
                        .init(color: lowerGreen.opacity(isActive ? 0.96 : 0.46), location: 1),
                    ]),
                    startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
                )
            )

            // A radial veil creates the reference's seamless black center.
            // There is intentionally no second inner shape or hard ring.
            context.fill(
                membrane,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .black.opacity(0.99), location: 0),
                        .init(color: .black.opacity(0.98), location: 0.48),
                        .init(color: .black.opacity(0.80), location: 0.70),
                        .init(color: .black.opacity(0.24), location: 0.91),
                        .init(color: .clear, location: 1),
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )

            context.drawLayer { particles in
                particles.clip(to: membrane)
                drawParticles(
                    in: &particles,
                    size: size,
                    center: center,
                    elapsed: elapsed,
                    isActive: isActive
                )
            }

            context.stroke(
                membrane,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.31, green: 0.66, blue: 0.94), location: 0),
                        .init(color: Color.white.opacity(0.20), location: 0.47),
                        .init(color: Color(red: 0.55, green: 0.68, blue: 0.45), location: 1),
                    ]),
                    startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
                ),
                lineWidth: 2
            )
        }
        .shadow(color: Color(red: 0.08, green: 0.28, blue: 0.31).opacity(0.32), radius: 20)
    }

    private func blobPath(
        in rect: CGRect,
        phase: Double,
        movement: Double
    ) -> Path {
        let contour: [Double] = [
            0.92, 0.99, 1.04, 1.02, 0.97, 0.91, 0.93,
            1.00, 1.03, 0.98, 0.90, 0.84, 0.82, 0.87,
        ]
        let center = CGPoint(
            x: rect.midX + CGFloat(sin(phase * 0.71)) * 2.6 * movement,
            y: rect.midY + CGFloat(cos(phase * 0.57)) * 2.2 * movement
        )
        let radiusX = rect.width * 0.49
        let radiusY = rect.height * 0.49
        let points: [CGPoint] = contour.indices.map { index in
            let angle = Double(index) / Double(contour.count) * Double.pi * 2 - Double.pi / 2
            let breathing = sin(phase + Double(index) * 1.23) * 0.030 * movement
                + cos(phase * 0.71 - Double(index) * 0.79) * 0.018 * movement
            let radius = contour[index] + breathing
            return CGPoint(
                x: center.x + CGFloat(cos(angle) * radius) * radiusX,
                y: center.y + CGFloat(sin(angle) * radius) * radiusY
            )
        }

        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: midpoint(last, first))
        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(point, next), control: point)
        }
        path.closeSubpath()
        return path
    }

    private func drawParticles(
        in context: inout GraphicsContext,
        size: CGSize,
        center: CGPoint,
        elapsed: Double,
        isActive: Bool
    ) {
        let speed = isActive ? elapsed : 0
        let maxRadius = min(size.width, size.height)

        for index in 0..<92 {
            let seed = unit(index, salt: 11)
            let radiusSeed = sqrt(unit(index, salt: 29))
            let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
            let orbit = seed * Double.pi * 2
                + speed * (0.035 + unit(index, salt: 41) * 0.075) * direction
            let radius = maxRadius * (0.16 + radiusSeed * 0.29)
            let x = center.x + CGFloat(cos(orbit)) * radius
                + CGFloat(sin(speed * 0.16 + Double(index))) * 2.3
            let y = center.y + CGFloat(sin(orbit * 1.06)) * radius
                + CGFloat(cos(speed * 0.13 - Double(index))) * 1.8
            let pulse = 0.76 + sin(speed * (0.48 + seed * 0.36) + Double(index)) * 0.24
            let diameter = CGFloat(0.55 + unit(index, salt: 53) * 2.65) * CGFloat(pulse)
            let alpha = (0.24 + unit(index, salt: 67) * 0.64) * (isActive ? 1 : 0.22)
            let rect = CGRect(
                x: x - diameter / 2,
                y: y - diameter / 2,
                width: diameter,
                height: diameter
            )
            let color = y < center.y
                ? Color(red: 0.62, green: 0.84, blue: 0.96)
                : Color(red: 0.72, green: 0.87, blue: 0.72)

            if diameter > 2.05 {
                let halo = rect.insetBy(dx: -diameter * 0.70, dy: -diameter * 0.70)
                context.fill(Path(ellipseIn: halo), with: .color(color.opacity(alpha * 0.12)))
            }
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
        }
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func unit(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 97 + salt * 31)) * 43_758.545_312_3
        return value - floor(value)
    }
}
