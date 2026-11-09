/* -----------------------------------------------------------------
 * :: :  A  K  A  R  I  :                                         ::
 * -----------------------------------------------------------------
 * Redistribution  and  use  in  source  and  binary  forms, with or
 * without  modification,  are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions  in  binary  form  must  reproduce  the  above
 *    copyright  notice,  this  list of conditions and the following
 *    disclaimer   in   the  documentation  and/or  other  materials
 *    provided with the distribution.
 *
 * 3. Neither the name of  the copyright holder nor the names of its
 *    contributors  may  be  used  to  endorse  or  promote products
 *    derived  from  this  software  without  specific prior written
 *    permission.
 *
 * THIS   SOFTWARE   IS   PROVIDED  BY  THE  COPYRIGHT  HOLDERS  AND
 * CONTRIBUTORS  "AS  IS"  AND  ANY  EXPRESS  OR IMPLIED WARRANTIES,
 * INCLUDING,   BUT  NOT  LIMITED  TO,  THE  IMPLIED  WARRANTIES  OF
 * MERCHANTABILITY   AND   FITNESS  FOR  A  PARTICULAR  PURPOSE  ARE
 * DISCLAIMED.   IN   NO   EVENT   SHALL  THE  COPYRIGHT  HOLDER  OR
 * CONTRIBUTORS  BE  LIABLE  FOR  ANY  DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL,  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
 * USE,  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND  ON  ANY  THEORY  OF  LIABILITY,  WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY  WAY  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 *                               Copyright (C) 2026 Wabi Foundation.
 *                                              All rights reserved.
 * -----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ----------------------------------------------------------------- */

import Foundation
import SwiftCrossUI

extension Kraken
{
  /// The UI's icons, drawn in a unit square as layers of shapes.
  struct IconPart: Shape
  {
    enum Kind
    {
      case videoBody, videoLens
      case bulbGlass, bulbBase
      case selectBox, pointer
      case ring, crosshair
      case moveLines, moveHeads
      case rotateArc, rotateHead
      case scaleSmall, scaleCorner, scaleLine, scaleHead
      case renderHump, renderBody, renderBands, renderFinder, renderLight
      case printerTop, printerLegs, printerSheet, sheetMountain, sheetSun
      case drop, sceneDot, sceneRing, sceneLens
      case earth, continents, orbit
      case objectCorners, objectSquare
      case materialRing, materialQuarters
    }

    let kind: Kind

    nonisolated func path(in b: Path.Rect) -> Path
    {
      let p = { (x: Double, y: Double) in SIMD2(b.x + x * b.width, b.y + y * b.height) }
      let r = { (x: Double, y: Double, w: Double, h: Double) in
        Path.Rect(x: b.x + x * b.width, y: b.y + y * b.height, width: w * b.width, height: h * b.height)
      }

      let s = b.width
      func triangle(_ a: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Path
      {
        Path().move(to: p(a.0, a.1)).addLine(to: p(c.0, c.1)).addLine(to: p(d.0, d.1)).addLine(to: p(a.0, a.1))
      }

      switch kind
      {
        case .videoBody:
          return rounded(r(0.04, 0.26, 0.62, 0.48), 0.1 * s)
        case .videoLens:
          return triangle((0.7, 0.5), (0.96, 0.26), (0.96, 0.74))
        case .bulbGlass:
          return Path()
            .addCircle(center: p(0.5, 0.38), radius: 0.32 * s)
            .addRectangle(r(0.34, 0.5, 0.32, 0.22))
        case .bulbBase:
          return rounded(r(0.34, 0.76, 0.32, 0.18), 0.06 * s)
        case .selectBox:
          var path = Path()
          for (a, z) in [((0.06, 0.06), (0.94, 0.06)), ((0.94, 0.06), (0.94, 0.62)), ((0.06, 0.06), (0.06, 0.94)),
                         ((0.06, 0.94), (0.52, 0.94))]
          {
            let steps = 4
            for k in 0 ..< steps
            {
              let t0 = Double(k) / Double(steps), t1 = t0 + 0.55 / Double(steps)
              path = path.move(to: p(a.0 + (z.0 - a.0) * t0, a.1 + (z.1 - a.1) * t0))
                .addLine(to: p(a.0 + (z.0 - a.0) * t1, a.1 + (z.1 - a.1) * t1))
            }
          }

          return path
        case .pointer:
          return Path()
            .move(to: p(0.56, 0.46)).addLine(to: p(0.56, 1.0)).addLine(to: p(0.68, 0.88))
            .addLine(to: p(0.78, 1.0)).addLine(to: p(0.86, 0.94)).addLine(to: p(0.76, 0.84))
            .addLine(to: p(0.92, 0.82)).addLine(to: p(0.56, 0.46))
        case .ring:
          return Path().addCircle(center: p(0.5, 0.5), radius: 0.3 * s)
        case .crosshair:
          return Path()
            .move(to: p(0.5, 0.0)).addLine(to: p(0.5, 0.34)).move(to: p(0.5, 0.66)).addLine(to: p(0.5, 1.0))
            .move(to: p(0.0, 0.5)).addLine(to: p(0.34, 0.5)).move(to: p(0.66, 0.5)).addLine(to: p(1.0, 0.5))
        case .moveLines:
          return Path()
            .move(to: p(0.5, 0.16)).addLine(to: p(0.5, 0.84))
            .move(to: p(0.16, 0.5)).addLine(to: p(0.84, 0.5))
        case .moveHeads:
          return triangle((0.5, 0.0), (0.34, 0.2), (0.66, 0.2))
            .addSubpath(triangle((0.5, 1.0), (0.34, 0.8), (0.66, 0.8)))
            .addSubpath(triangle((0.0, 0.5), (0.2, 0.34), (0.2, 0.66)))
            .addSubpath(triangle((1.0, 0.5), (0.8, 0.34), (0.8, 0.66)))
        case .rotateArc:
          return Path()
            .move(to: p(0.5 + 0.38 * cos(0.35), 0.5 + 0.38 * sin(0.35)))
            .addArc(center: p(0.5, 0.5), radius: 0.38 * s, startAngle: 0.35, endAngle: 1.75 * .pi, clockwise: true)
        case .rotateHead:
          let tip = (0.5 + 0.38 * cos(1.75 * .pi), 0.5 + 0.38 * sin(1.75 * .pi))
          return triangle((tip.0 + 0.2, tip.1 + 0.04), (tip.0 - 0.06, tip.1 - 0.14), (tip.0 - 0.02, tip.1 + 0.18))
        case .scaleSmall:
          return Path().addRectangle(r(0.04, 0.6, 0.36, 0.36))
        case .scaleCorner:
          return Path()
            .move(to: p(0.04, 0.42)).addLine(to: p(0.04, 0.04)).addLine(to: p(0.96, 0.04)).addLine(to: p(0.96, 0.96))
            .addLine(to: p(0.58, 0.96))
        case .scaleLine:
          return Path().move(to: p(0.4, 0.6)).addLine(to: p(0.78, 0.22))
        case .scaleHead:
          return triangle((0.86, 0.14), (0.52, 0.22), (0.78, 0.48))
        case .renderHump:
          return rounded(r(0.22, 0.02, 0.3, 0.24), 0.07 * s)
        case .renderBody:
          return rounded(r(0.04, 0.18, 0.92, 0.78), 0.06 * s)
        case .renderBands:
          return Path().addRectangle(r(0.0, 0.14, 1.0, 0.16)).addRectangle(r(0.0, 0.84, 1.0, 0.16))
        case .renderFinder:
          return Path().addRectangle(r(0.72, 0.3, 0.24, 0.54))
            .move(to: p(0.72, 0.56)).addLine(to: p(0.96, 0.56))
        case .renderLight:
          return Path().addRectangle(r(0.76, 0.02, 0.14, 0.06))
        case .printerTop:
          return rounded(r(0.0, 0.0, 1.0, 0.3), 0.06 * s)
        case .printerLegs:
          return Path().addRectangle(r(0.0, 0.28, 0.14, 0.28)).addRectangle(r(0.86, 0.28, 0.14, 0.28))
        case .printerSheet:
          return Path().addRectangle(r(0.21, 0.36, 0.58, 0.64))
        case .sheetMountain:
          return triangle((0.27, 0.9), (0.44, 0.62), (0.61, 0.9))
            .addSubpath(triangle((0.5, 0.9), (0.62, 0.74), (0.74, 0.9)))
        case .sheetSun:
          return Path().addCircle(center: p(0.64, 0.52), radius: 0.06 * s)
        case .drop:
          return Path()
            .move(to: p(0.3, 0.0))
            .addCubicCurve(control1: p(0.34, 0.24), control2: p(0.58, 0.44), to: p(0.58, 0.72))
            .addArc(center: p(0.3, 0.72), radius: 0.28 * s, startAngle: 0, endAngle: .pi, clockwise: true)
            .addCubicCurve(control1: p(0.02, 0.44), control2: p(0.26, 0.24), to: p(0.3, 0.0))
        case .sceneDot:
          return Path().addCircle(center: p(0.86, 0.14), radius: 0.13 * s)
        case .sceneRing:
          return Path().addCircle(center: p(0.75, 0.73), radius: 0.24 * s)
        case .sceneLens:
          return Path().addCircle(center: p(0.7, 0.71), radius: 0.08 * s)
        case .earth:
          return Path().addCircle(center: p(0.46, 0.54), radius: 0.36 * s)
        case .continents:
          return Path()
            .addSubpath(ellipse(p(0.34, 0.44), 0.1 * s, 0.13 * s))
            .addSubpath(ellipse(p(0.56, 0.7), 0.13 * s, 0.08 * s))
        case .orbit:
          // a ring tilted up to the right, around the globe.
          var path = Path()
          let angle = -0.7, steps = 40
          for k in 0 ... steps
          {
            let t = Double(k) / Double(steps) * 2 * .pi
            let x = 0.54 * cos(t), y = 0.2 * sin(t)
            let q = p(0.5 + x * cos(angle) - y * sin(angle), 0.5 + x * sin(angle) + y * cos(angle))
            path = k == 0 ? path.move(to: q) : path.addLine(to: q)
          }

          return path
        case .objectCorners:
          var path = Path()
          for (x, y, dx, dy) in [(0.04, 0.06, 1.0, 1.0), (0.96, 0.06, -1.0, 1.0), (0.04, 0.94, 1.0, -1.0), (0.96, 0.94, -1.0, -1.0)]
          {
            path = path.move(to: p(x, y + dy * 0.26)).addLine(to: p(x, y)).addLine(to: p(x + dx * 0.26, y))
          }

          return path
        case .objectSquare:
          return Path().addRectangle(r(0.22, 0.28, 0.56, 0.5))
        case .materialRing:
          return Path().addCircle(center: p(0.5, 0.5), radius: 0.42 * s)
        case .materialQuarters:
          let c = p(0.5, 0.5), radius = 0.42 * s
          return Path()
            .move(to: c).addLine(to: p(0.08, 0.5))
            .addArc(center: c, radius: radius, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
            .addLine(to: c)
            .move(to: c).addLine(to: p(0.92, 0.5))
            .addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi / 2, clockwise: true)
            .addLine(to: c)
      }
    }

    private func rounded(_ rect: Path.Rect, _ k: Double) -> Path
    {
      let (l, t, r, bottom) = (rect.x, rect.y, rect.x + rect.width, rect.y + rect.height)
      return Path()
        .move(to: SIMD2(l + k, t))
        .addLine(to: SIMD2(r - k, t))
        .addQuadCurve(control: SIMD2(r, t), to: SIMD2(r, t + k))
        .addLine(to: SIMD2(r, bottom - k))
        .addQuadCurve(control: SIMD2(r, bottom), to: SIMD2(r - k, bottom))
        .addLine(to: SIMD2(l + k, bottom))
        .addQuadCurve(control: SIMD2(l, bottom), to: SIMD2(l, bottom - k))
        .addLine(to: SIMD2(l, t + k))
        .addQuadCurve(control: SIMD2(l, t), to: SIMD2(l + k, t))
    }

    private func ellipse(_ c: SIMD2<Double>, _ rx: Double, _ ry: Double) -> Path
    {
      let k = 0.5523
      return Path()
        .move(to: SIMD2(c.x, c.y - ry))
        .addCubicCurve(control1: SIMD2(c.x + rx * k, c.y - ry), control2: SIMD2(c.x + rx, c.y - ry * k), to: SIMD2(c.x + rx, c.y))
        .addCubicCurve(control1: SIMD2(c.x + rx, c.y + ry * k), control2: SIMD2(c.x + rx * k, c.y + ry), to: SIMD2(c.x, c.y + ry))
        .addCubicCurve(control1: SIMD2(c.x - rx * k, c.y + ry), control2: SIMD2(c.x - rx, c.y + ry * k), to: SIMD2(c.x - rx, c.y))
        .addCubicCurve(control1: SIMD2(c.x - rx, c.y - ry * k), control2: SIMD2(c.x - rx * k, c.y - ry), to: SIMD2(c.x, c.y - ry))
    }
  }

  /// The icon colors.
  enum IconColor
  {
    static let grey = Color(white: 0.753)
    static let greyDim = Color(white: 0.569)
    static let world = Color(red: 0.765, green: 0.4, blue: 0.435)
    static let object = Color(red: 0.929, green: 0.616, blue: 0.365)
    static let objectDim = Color(red: 0.655, green: 0.471, blue: 0.322)
    static let data = Color(red: 0.035, green: 0.69, blue: 0.537)
    static let material = Color(red: 0.765, green: 0.4, blue: 0.435)
  }

  /// A properties tab's icon.
  @MainActor
  struct TabIcon: View
  {
    enum Kind
    {
      case render, output, scene, world, object, camera, light, material
    }

    let kind: Kind
    let background: Double

    var body: some View
    {
      let gap = Color(white: background)
      let line = StrokeStyle(width: 1.1, cap: .round, join: .round)
      return ZStack
      {
        switch kind
        {
          case .render:
            IconPart(kind: .renderHump).stroke(IconColor.grey, style: line)
            IconPart(kind: .renderBody).fill(gap)
            IconPart(kind: .renderBody).stroke(IconColor.grey, style: line)
            IconPart(kind: .renderBands).fill(IconColor.grey)
            IconPart(kind: .renderFinder).stroke(IconColor.grey, style: line)
            IconPart(kind: .renderLight).fill(IconColor.greyDim)
          case .output:
            IconPart(kind: .printerTop).fill(IconColor.grey)
            IconPart(kind: .printerLegs).fill(IconColor.grey)
            IconPart(kind: .printerSheet).stroke(gap, style: StrokeStyle(width: 1.4))
            IconPart(kind: .printerSheet).fill(IconColor.greyDim)
            IconPart(kind: .sheetMountain).fill(gap)
            IconPart(kind: .sheetSun).fill(gap)
          case .scene:
            IconPart(kind: .drop).fill(IconColor.grey)
            IconPart(kind: .sceneDot).fill(IconColor.grey)
            IconPart(kind: .sceneRing).fill(gap)
            IconPart(kind: .sceneRing).stroke(IconColor.grey, style: line)
            IconPart(kind: .sceneLens).fill(IconColor.grey)
          case .world:
            IconPart(kind: .orbit).stroke(IconColor.world, style: line)
            IconPart(kind: .earth).stroke(gap, style: StrokeStyle(width: 1.6))
            IconPart(kind: .earth).fill(IconColor.world)
            IconPart(kind: .continents).fill(gap)
          case .object:
            IconPart(kind: .objectCorners).stroke(IconColor.objectDim, style: StrokeStyle(width: 1.1))
            IconPart(kind: .objectSquare).fill(IconColor.object)
          case .camera:
            IconPart(kind: .videoBody).fill(IconColor.data)
            IconPart(kind: .videoLens).fill(IconColor.data)
          case .light:
            IconPart(kind: .bulbGlass).fill(IconColor.data)
            IconPart(kind: .bulbBase).fill(IconColor.data)
          case .material:
            IconPart(kind: .materialQuarters).fill(IconColor.material)
            IconPart(kind: .materialRing).stroke(IconColor.material, style: line)
        }
      }
      .frame(width: 14, height: 14)
    }
  }

  /// The viewport's tool icons, all one size.
  @MainActor
  struct ToolIcon: View
  {
    let tool: Layout.Tool

    var body: some View
    {
      let ink = Color(white: 0.92)
      let line = StrokeStyle(width: 1.3, cap: .round, join: .round)
      return ZStack
      {
        switch tool
        {
          case .select:
            IconPart(kind: .selectBox).stroke(ink, style: line)
            IconPart(kind: .pointer).fill(ink)
          case .cursor:
            IconPart(kind: .ring).stroke(Color(red: 1, green: 0.3, blue: 0.3), style: StrokeStyle(width: 1.6))
            IconPart(kind: .crosshair).stroke(ink, style: line)
          case .move:
            IconPart(kind: .moveLines).stroke(ink, style: line)
            IconPart(kind: .moveHeads).fill(ink)
          case .rotate:
            IconPart(kind: .rotateArc).stroke(ink, style: StrokeStyle(width: 1.6, cap: .round))
            IconPart(kind: .rotateHead).fill(ink)
          case .scale:
            IconPart(kind: .scaleCorner).stroke(ink, style: line)
            IconPart(kind: .scaleSmall).fill(ink)
            IconPart(kind: .scaleLine).stroke(ink, style: line)
            IconPart(kind: .scaleHead).fill(ink)
          case .transform:
            IconPart(kind: .ring).stroke(ink, style: line)
            IconPart(kind: .moveLines).stroke(ink, style: line)
            IconPart(kind: .moveHeads).fill(ink)
        }
      }
      .frame(width: 16, height: 16)
    }
  }

  /// The toolbar down the viewport's left side.
  @MainActor
  struct LayoutToolbar: View
  {
    let layout: Layout

    init(layout: Layout)
    {
      self.layout = layout
    }

    var body: some View
    {
      VStack(spacing: 2)
      {
        if layout.showsToolbar
        {
          ForEach(Layout.Tool.allCases, id: \.self)
          { tool in
            ToolIcon(tool: tool)
              .frame(width: 28, height: 28)
              .background(RoundedRectangle(cornerRadius: 4)
                .fill(layout.tool == tool ? Properties.accent : Color(white: 0.16, opacity: 0.92)))
              .onTapGesture { layout.tool = tool }
          }
        }
      }
      .padding(8)
    }
  }
}
