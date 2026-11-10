import SwiftUI

/// Reference-lap outline (coloured by speed) with a dot per checked lap at the shared cursor.
struct TrackMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let map: MapData? = model.analysis.map
        let cursor: Double? = model.cursorDistance
        let refLength: Double = model.analysis.refLength

        VStack(spacing: 4) {
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                guard let m = map else { return }
                TrackMapRenderer.draw(map: m, cursor: cursor, refLength: refLength, context: &context, size: size)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if map == nil {
                    Text("No GPS track").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text("slow").font(.caption2).foregroundStyle(.secondary)
                LinearGradient(
                    colors: [Palette.speedColor(0), Palette.speedColor(0.5), Palette.speedColor(1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 6)
                .clipShape(Capsule())
                Text("fast").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

enum TrackMapRenderer {
    static func draw(map: MapData, cursor: Double?, refLength: Double,
                     context: inout GraphicsContext, size: CGSize) {
        let n: Int = min(map.refX.count, map.refY.count, map.speedNorm.count)
        guard n >= 2 else { return }
        let pad: CGFloat = 16
        let dx: Double = max(map.maxX - map.minX, 1e-6)
        let dy: Double = max(map.maxY - map.minY, 1e-6)
        let availW: CGFloat = max(size.width - 2 * pad, 1)
        let availH: CGFloat = max(size.height - 2 * pad, 1)
        let scale: CGFloat = min(availW / CGFloat(dx), availH / CGFloat(dy))
        let drawnW: CGFloat = CGFloat(dx) * scale
        let drawnH: CGFloat = CGFloat(dy) * scale
        let originX: CGFloat = (size.width - drawnW) / 2
        let originY: CGFloat = (size.height - drawnH) / 2

        // North up: larger y is drawn higher on screen.
        func point(_ x: Double, _ y: Double) -> CGPoint {
            return CGPoint(x: originX + CGFloat(x - map.minX) * scale,
                           y: originY + CGFloat(map.maxY - y) * scale)
        }

        for i in 1..<n {
            let x0: Double = map.refX[i - 1]
            let y0: Double = map.refY[i - 1]
            let x1: Double = map.refX[i]
            let y1: Double = map.refY[i]
            if !(x0.isFinite && y0.isFinite && x1.isFinite && y1.isFinite) { continue }
            var path: Path = Path()
            path.move(to: point(x0, y0))
            path.addLine(to: point(x1, y1))
            let color: Color = Palette.speedColor(map.speedNorm[i])
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }

        if let c = cursor, refLength > 0 {
            let fraction: Double = c / refLength
            for lap in map.laps {
                guard let p = lap.position(fraction: fraction) else { continue }
                let center: CGPoint = point(p.x, p.y)
                let rect: CGRect = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
                let dot: Path = Path(ellipseIn: rect)
                context.fill(dot, with: .color(Palette.color(lap.colorIndex)))
                context.stroke(dot, with: .color(Color.white), lineWidth: 2)
            }
        }
    }
}
