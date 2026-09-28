//
//  Icons.swift
//  NucleantCEFDemo
//
//  The toolbar's icons, drawn as paths — the bundled face has no arrow or
//  reload glyphs.
//

import Foundation
import NucleantUI

enum BrowserIcon {
    case back, forward, reload, stop, close, plus

    /// The icon in a `size` box, as lines to stroke.
    func path(in size: Size) -> Path {
        let w = size.width, h = size.height
        var path = Path()
        switch self {
        case .back:
            path.move(to: Point(x: w * 0.62, y: h * 0.2))
            path.addLine(to: Point(x: w * 0.32, y: h * 0.5))
            path.addLine(to: Point(x: w * 0.62, y: h * 0.8))
        case .forward:
            path.move(to: Point(x: w * 0.38, y: h * 0.2))
            path.addLine(to: Point(x: w * 0.68, y: h * 0.5))
            path.addLine(to: Point(x: w * 0.38, y: h * 0.8))
        case .stop, .close:
            let inset = self == .close ? 0.3 : 0.25
            path.move(to: Point(x: w * inset, y: h * inset))
            path.addLine(to: Point(x: w * (1 - inset), y: h * (1 - inset)))
            path.move(to: Point(x: w * (1 - inset), y: h * inset))
            path.addLine(to: Point(x: w * inset, y: h * (1 - inset)))
        case .plus:
            path.move(to: Point(x: w * 0.5, y: h * 0.22))
            path.addLine(to: Point(x: w * 0.5, y: h * 0.78))
            path.move(to: Point(x: w * 0.22, y: h * 0.5))
            path.addLine(to: Point(x: w * 0.78, y: h * 0.5))
        case .reload:
            // Most of a circle, open at the top right, with an arrowhead
            // where it starts.
            let center = Point(x: w / 2, y: h / 2)
            let radius = min(w, h) * 0.3
            let start = -40.0 * .pi / 180
            let end = 250.0 * .pi / 180
            Self.addArc(to: &path, center: center, radius: radius, from: start, to: end)
            let tip = Point(x: center.x + radius * cos(start), y: center.y + radius * sin(start))
            let head = radius * 0.6
            path.move(to: Point(x: tip.x - head, y: tip.y - head * 0.15))
            path.addLine(to: tip)
            path.addLine(to: Point(x: tip.x + head * 0.1, y: tip.y - head))
        }
        return path
    }

    /// A circular arc from angle `from` to `to` (radians, y down), as cubic
    /// segments of at most a quarter turn each.
    private static func addArc(to path: inout Path, center: Point, radius: Double, from: Double, to: Double) {
        let segments = max(1, Int((abs(to - from) / (.pi / 2)).rounded(.up)))
        let step = (to - from) / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ angle: Double) -> Point {
            Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        path.move(to: point(from))
        for index in 0..<segments {
            let a0 = from + step * Double(index)
            let a1 = a0 + step
            let p0 = point(a0), p1 = point(a1)
            path.addCurve(
                to: p1,
                control1: Point(x: p0.x - k * radius * sin(a0), y: p0.y + k * radius * cos(a0)),
                control2: Point(x: p1.x + k * radius * sin(a1), y: p1.y - k * radius * cos(a1))
            )
        }
    }
}

/// An icon, stroked in the foreground color.
@View
struct IconView {
    let icon: BrowserIcon
    var color: Color = .primary
    var lineWidth: Double = 1.8

    var body: some View {
        PathShape { size in icon.path(in: size) }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}
