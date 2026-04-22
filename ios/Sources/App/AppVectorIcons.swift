import SwiftUI

enum AppVectorGlyph {
  case story
  case compose
}

struct AppVectorIcon: View {
  let glyph: AppVectorGlyph
  let tint: Color
  var lineWidth: CGFloat = 1.5

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        switch glyph {
        case .story:
          storyPath(in: geometry.size)
            .fill(tint)
        case .compose:
          composePaths(in: geometry.size)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private func storyPath(in size: CGSize) -> Path {
    let scale = min(size.width, size.height) / 24.0
    let rect = CGRect(
      x: (size.width - 24.0 * scale) * 0.5,
      y: (size.height - 24.0 * scale) * 0.5,
      width: 24.0 * scale,
      height: 24.0 * scale
    )

    var path = Path()
    path.addEllipse(in: CGRect(x: rect.minX + 2.25 * scale, y: rect.minY + 2.25 * scale, width: 19.5 * scale, height: 19.5 * scale))
    path.addRoundedRect(in: CGRect(x: rect.minX + 11.25 * scale, y: rect.minY + 7.25 * scale, width: 1.5 * scale, height: 9.5 * scale), cornerSize: CGSize(width: 0.75 * scale, height: 0.75 * scale))
    path.addRoundedRect(in: CGRect(x: rect.minX + 7.25 * scale, y: rect.minY + 11.25 * scale, width: 9.5 * scale, height: 1.5 * scale), cornerSize: CGSize(width: 0.75 * scale, height: 0.75 * scale))
    return path
  }

  private func composePaths(in size: CGSize) -> Path {
    let scale = min(size.width, size.height) / 21.0
    let rect = CGRect(
      x: (size.width - 21.0 * scale) * 0.5,
      y: (size.height - 21.0 * scale) * 0.5,
      width: 21.0 * scale,
      height: 21.0 * scale
    )

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }

    var path = Path()
    path.move(to: point(14.0, 1.0))
    path.addQuadCurve(to: point(14.0, 4.0), control: point(15.25, 2.25))
    path.addLine(to: point(4.5, 13.5))
    path.addLine(to: point(1.5, 14.5))
    path.addLine(to: point(2.5, 10.6))
    path.addLine(to: point(12.0, 1.1))
    path.addQuadCurve(to: point(14.0, 1.0), control: point(13.0, 0.25))

    path.move(to: point(6.5, 14.5))
    path.addLine(to: point(14.5, 14.5))

    path.move(to: point(12.5, 3.5))
    path.addLine(to: point(13.5, 4.5))
    return path
  }
}
