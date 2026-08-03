import SwiftUI

/// Renders all menu bar icon states into NSImage so the view identity stays
/// stable across state transitions (no flicker). Idle rasterizes an SF
/// Symbol; recording draws red level-tracking bars; the working states
/// (transcription, cleanup LLM call) draw pulsing bars whose phase must be
/// advanced by an external timer — nothing observable ticks while they run.
enum MenuBarIconRenderer {
    // Bar geometry for the recording meter
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let maxHeight: CGFloat = 16
    private static let sideScale: CGFloat = 0.65
    private static let minFraction: CGFloat = 0.2

    static func render(
        state: RecordingState, meterLevel: Double, isCleanupProcessing: Bool = false,
        processingPhase: Double = 0
    ) -> NSImage {
        // Cleanup's LLM call wins over the generic processing icon — it's a
        // distinct step of the same dictation flow, so the menu bar should
        // reflect that's what's running now (distinct tint).
        if isCleanupProcessing {
            return renderPulsingBars(phase: processingPhase, color: .systemPurple)
        }
        switch state {
        case .recording:
            return renderMeterBars(level: meterLevel)
        case .processing:
            return renderPulsingBars(phase: processingPhase, color: .systemOrange)
        default:
            return idleIcon
        }
    }

    // Idle waveform geometry
    private static let iconSize: CGFloat = 18
    private static let strokeWidth: CGFloat = 1.7
    /// Keeps the stroke's outer edge and its round caps inside the canvas.
    /// Half the stroke would be the minimum; the rest is optical breathing room
    /// so the glyph does not crowd the menu bar items either side.
    private static let iconInset: CGFloat = 1.6

    /// The FalaDan mark: a wave that climbs to a tall peak and trails off right.
    ///
    /// Normalised to the unit square, y measured from the bottom. Read these as
    /// the wave's turning points — the renderer rounds the corners between them
    /// into a continuous curve.
    private static let waveKeyPoints: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.46),
        CGPoint(x: 0.13, y: 0.70),
        CGPoint(x: 0.27, y: 0.30),
        CGPoint(x: 0.45, y: 1.00),
        CGPoint(x: 0.62, y: 0.06),
        CGPoint(x: 0.78, y: 0.62),
        CGPoint(x: 1.00, y: 0.44),
    ]

    /// The idle waveform, drawn rather than loaded.
    ///
    /// Drawn for the same reason the meter and pulse states are: a path is
    /// resolution-independent, so it stays crisp at any menu bar size and on any
    /// display, and there is no resource to copy into the bundle and no failure
    /// mode where a packaging slip leaves the menu bar blank. It also sidesteps
    /// the supplied bitmap's clipped right edge, which could not be recovered by
    /// scaling.
    ///
    /// Built once — the menu bar re-renders on every state change, and this
    /// never varies.
    private static let idleIcon: NSImage = {
        let size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: size, flipped: false) { _ in
            let span = iconSize - iconInset * 2
            let points = waveKeyPoints.map {
                CGPoint(x: iconInset + $0.x * span, y: iconInset + $0.y * span)
            }

            let path = smoothPath(through: points)
            path.lineWidth = strokeWidth
            // Round caps and joins so the trailing tip and the peaks read as a
            // drawn stroke rather than a chart line.
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        // Template: macOS discards the colour and renders the shape as a
        // silhouette that inverts against a light menu bar and dims when the app
        // is inactive. Drawing in black above is arbitrary — only coverage
        // survives.
        image.isTemplate = true
        return image
    }()

    /// A path through every point, with the corners rounded off.
    ///
    /// Catmull-Rom, converted to the cubic Béziers AppKit draws. Straight
    /// segments would make the wave look like a chart; this keeps the turning
    /// points smooth while still passing through each one exactly, so the
    /// key points above stay readable as the shape they describe.
    private static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }

        for i in 0..<(points.count - 1) {
            // Clamp at the ends so the curve starts and finishes level instead
            // of overshooting past the first and last points.
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]

            // The 6.0 is Catmull-Rom's standard tension: tangents are a sixth of
            // the span to the neighbour on either side.
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    /// Draw three rounded red bars whose height tracks the mic level.
    private static func renderMeterBars(level: Double) -> NSImage {
        let effectiveLevel = minFraction + CGFloat(level) * (1.0 - minFraction)
        let scales: [CGFloat] = [sideScale, 1.0, sideScale]
        return drawBars(heightFractions: scales.map { effectiveLevel * $0 }, color: .systemRed)
    }

    /// Calm pulsing bars for the "working" states (transcription, cleanup
    /// LLM call). Same geometry as the recording meter but a non-red tint and
    /// a self-driven wave, so "working" reads differently from "listening"
    /// while still clearly not idle.
    private static func renderPulsingBars(phase: Double, color: NSColor) -> NSImage {
        drawBars(heightFractions: pulsingBarFractions(phase: phase), color: color)
    }

    /// Gentle travelling wave around mid-height; per-bar offset makes the
    /// motion read left-to-right. `phase` is one full cycle over [0, 1).
    static func pulsingBarFractions(phase: Double) -> [CGFloat] {
        (0..<3).map { i in
            let angle = 2 * Double.pi * phase - Double(i) * 0.9
            return 0.45 + 0.2 * CGFloat(sin(angle))
        }
    }

    private static func drawBars(heightFractions: [CGFloat], color: NSColor) -> NSImage {
        let totalWidth =
            barWidth * CGFloat(heightFractions.count)
            + barSpacing * CGFloat(heightFractions.count - 1)
        let size = NSSize(width: totalWidth, height: maxHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            for (i, fraction) in heightFractions.enumerated() {
                let barHeight = max(maxHeight * fraction, barWidth)
                let x = CGFloat(i) * (barWidth + barSpacing)
                let y = (maxHeight - barHeight) / 2.0
                let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(
                    roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                color.setFill()
                path.fill()
            }
            return true
        }

        image.isTemplate = false
        return image
    }
}
