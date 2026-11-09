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

import AkariCore
import AkariRender
import Foundation
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension Kraken
{
  /// A gray SF Symbol, or its first letter where there are none,
  /// the name is read as the icon updates, AppKit's representables
  /// keep the values they were made with.
  @MainActor
  struct SymbolIcon: View
  {
    let name: () -> String
    let size: Double
    let white: Double

    init(_ name: @autoclosure @escaping () -> String, size: Double, white: Double)
    {
      self.name = name
      self.size = size
      self.white = white
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeSymbol(name: name, size: size, white: white)
        #else
          Text(String(name().prefix(1)).uppercased())
            .font(.system(size: Int(size), weight: .semibold))
            .foregroundColor(Color(white: white))
        #endif
      }
    }
  }

  /// A sphere, a cube and a cone, tinted as the theme
  /// tints it, on a `background` gray it cuts gaps into.
  @MainActor
  struct SceneIcon: View
  {
    let size: Double
    let background: Double

    private static let tint = 0.8

    var body: some View
    {
      let shade = { (opacity: Double) in Color(white: background + (Self.tint - background) * opacity) }
      let gap = StrokeStyle(width: size * 0.1)
      return ZStack
      {
        ScenePart(kind: .sphere).fill(shade(0.6))
        ScenePart(kind: .cube).stroke(Color(white: background), style: gap)
        ScenePart(kind: .cube).fill(shade(0.8))
        ScenePart(kind: .cone).stroke(Color(white: background), style: gap)
        ScenePart(kind: .cone).fill(shade(1))
      }
      .frame(width: size, height: size)
    }
  }

  struct ScenePart: Shape
  {
    enum Kind
    {
      case sphere, cube, cone
    }

    let kind: Kind

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let point = { (x: Double, y: Double) in SIMD2(bounds.x + x * bounds.width, bounds.y + y * bounds.height) }
      switch kind
      {
        case .sphere:
          return Path().addCircle(center: point(0.31, 0.31), radius: 0.25 * bounds.width)
        case .cube:
          let (l, t, r, b, k) = (0.24, 0.45, 0.74, 0.95, 0.12)
          return Path()
            .move(to: point(l + k, t))
            .addLine(to: point(r - k, t))
            .addQuadCurve(control: point(r, t), to: point(r, t + k))
            .addLine(to: point(r, b - k))
            .addQuadCurve(control: point(r, b), to: point(r - k, b))
            .addLine(to: point(l + k, b))
            .addQuadCurve(control: point(l, b), to: point(l, b - k))
            .addLine(to: point(l, t + k))
            .addQuadCurve(control: point(l, t), to: point(l + k, t))
        case .cone:
          return Path()
            .move(to: point(0.70, 0.08))
            .addLine(to: point(0.97, 0.62))
            .addLine(to: point(0.43, 0.62))
            .addLine(to: point(0.70, 0.08))
      }
    }
  }

  /// A ring's outline from the top, clockwise, `progress` of the way around.
  struct ProgressRing: Shape
  {
    var progress: Double

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let center = bounds.center
      let radius = min(bounds.width, bounds.height) / 2
      let top = 1.5 * Double.pi
      let end = top + 2 * Double.pi * min(max(progress, 0), 1)
      let start = center + SIMD2(0, -radius)
      guard end > 2 * Double.pi
      else
      {
        return Path().move(to: start).addArc(center: center, radius: radius, startAngle: top, endAngle: end, clockwise: true)
      }

      return Path().move(to: start)
        .addArc(center: center, radius: radius, startAngle: top, endAngle: 2 * Double.pi, clockwise: true)
        .addArc(center: center, radius: radius, startAngle: 0, endAngle: end - 2 * Double.pi, clockwise: true)
    }
  }

  /// Reloads the stage, its outline filling in with the reload's progress.
  @MainActor
  struct ReloadButton: View
  {
    let reload: () -> Void
    /// Whether the reload is still running, and how far along.
    let status: () -> (pending: Bool, progress: Double)

    @State private var reloading = false
    @State private var progress: Double?
    @State private var hovered = false

    var body: some View
    {
      ZStack
      {
        SymbolIcon("arrow.clockwise", size: 8, white: 0.85)
        RoundedRectangle(cornerRadius: 2)
          .fill((hovered ? Properties.fieldHover : Properties.menu).opacity(progress == nil ? 0 : 1))
          .frame(width: 12, height: 12)
        ProgressRing(progress: 1)
          .stroke(Color(white: 0.45, opacity: progress == nil ? 0 : 1), style: StrokeStyle(width: 2.5))
          .frame(width: 14, height: 14)
        ProgressRing(progress: progress ?? 0)
          .stroke(Properties.accent.opacity(progress == nil ? 0 : 1), style: StrokeStyle(width: 2.5, cap: .round))
          .frame(width: 14, height: 14)
      }
      .frame(width: 24, height: 20)
      .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Properties.fieldHover : Properties.menu))
      .onHover { hovered = $0 }
      .onTapGesture
      {
        guard !reloading else { return }
        reloading = true
        progress = 0
        reload()
      }
      .task(id: reloading)
      {
        guard reloading else { return }
        try? await Task.sleep(for: .milliseconds(30))
        while status().pending
        {
          progress = status().progress
          try? await Task.sleep(for: .milliseconds(33))
        }

        progress = 1
        try? await Task.sleep(for: .milliseconds(250))
        progress = nil
        reloading = false
      }
    }
  }

  /// The viewport dimmed outside the camera's render frame.
  @MainActor
  struct Passepartout: View
  {
    let aspect: () -> Double

    init(aspect: @autoclosure @escaping () -> Double)
    {
      self.aspect = aspect
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativePassepartout(aspect: aspect)
        #endif
      }
    }
  }
}
