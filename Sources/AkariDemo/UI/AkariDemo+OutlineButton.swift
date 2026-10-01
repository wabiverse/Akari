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
import HydraKit
import OpenUSDKit
import SwiftCrossUI

extension AkariDemo
{
  /// The viewport's selection outline toggle, its
  /// dropdown sets the line's thickness and color.
  @MainActor
  struct OutlineButton: View
  {
    let engine: Akari.RenderEngine
    let hydra: Hydra.RenderEngine

    @Environment(\.self) private var environment

    @State private var isOn: Bool
    @State private var isHovered = false
    @State private var showsOptions = false
    @State private var thickness: Double
    @State private var color: Color

    private static let border = Color(white: 0.24)
    private static let accent = Color(red: 0.28, green: 0.45, blue: 0.7)
    private static let well = Color(white: 0.16)

    init(engine: Akari.RenderEngine, hydra: Hydra.RenderEngine)
    {
      self.engine = engine
      self.hydra = hydra
      let c = hydra.selectionOutlineColor

      _isOn = State(wrappedValue: engine.showsSelectionOutline)
      _thickness = State(wrappedValue: Double(hydra.selectionOutlineWidth))
      _color = State(wrappedValue: Color(red: Double(c[0]),
                                         green: Double(c[1]),
                                         blue: Double(c[2]),
                                         opacity: Double(c[3])))
    }

    var body: some View
    {
      VStack(alignment: .trailing, spacing: 4)
      {
        VStack(spacing: 0)
        {
          HStack(spacing: 0)
          {
            toggleSegment
            Rectangle().fill(Self.border).frame(width: 1, height: 17)
            dropdownSegment
          }
          .cornerRadius(3)
          .padding(1)
          .background(Self.border)
          .cornerRadius(4)
        }

        if showsOptions
        {
          options
        }
      }
    }

    private var toggleSegment: some View
    {
      let fill = isOn ? Self.accent : isHovered ? Color(white: 0.2) : Self.well
      return ZStack
      {
        OutlineRing().stroke(Color(white: 0.96), style: StrokeStyle(width: 1.2))
        OutlineDisc(inset: -1.4).fill(fill)
        OutlineDisc(inset: 0).fill(Color(white: 0.98))
      }
      .frame(width: 13, height: 13)
      .frame(width: 18, height: 17)
      .background(fill)
      .onHover { isHovered = $0 }
      .onTapGesture
      {
        isOn.toggle()
        engine.showsSelectionOutline = isOn
      }
      .help(isOn ? "Hide selection outline" : "Show selection outline")
    }

    private var dropdownSegment: some View
    {
      Chevron()
        .stroke(Color(white: 0.85), style: StrokeStyle(width: 1.2))
        .frame(width: 7, height: 4)
        .frame(width: 19, height: 17)
        .background(showsOptions ? Color(white: 0.22) : Self.well)
        .onTapGesture { showsOptions.toggle() }
        .help("Selection outline options")
    }

    private var options: some View
    {
      VStack(alignment: .leading, spacing: 6)
      {
        Text("Selection Outline")
          .font(.system(size: 11, weight: .semibold))
        HStack(spacing: 6)
        {
          Text("Thickness")
            .font(.system(size: 11))
            .foregroundColor(Color(white: 0.58))
          Text("\(Int(thickness)) px")
            .font(.system(size: 11, weight: .medium).monospaced())
        }
        Slider(value: $thickness.onChange { hydra.selectionOutlineWidth = Int32($0.rounded()) },
               in: 1 ... 10)
          .frame(width: 150)
        ColorPicker("Color", selection: $color.onChange
        { color in
          let c = color.resolve(in: environment)
          hydra.selectionOutlineColor = Pixar.GfVec4f(c.red, c.green, c.blue, c.opacity)
        })
        .font(.system(size: 11))
      }
      .padding(10)
      .background(Color(white: 0.14, opacity: 0.9))
      .cornerRadius(6)
      .foregroundColor(Color(white: 0.96))
    }
  }

  /// The outline half of the overlay glyph, lower left.
  struct OutlineRing: Shape
  {
    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let size = min(bounds.width, bounds.height)
      return Path().addCircle(center: bounds.origin + SIMD2(0.36, 0.64) * size, radius: 0.3 * size)
    }
  }

  /// The solid half of the's overlay glyph, upper right.
  struct OutlineDisc: Shape
  {
    var inset: Double

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let size = min(bounds.width, bounds.height)
      return Path().addCircle(center: bounds.origin + SIMD2(0.62, 0.38) * size, radius: 0.3 * size - inset)
    }
  }

  /// The dropdown's downward chevron.
  struct Chevron: Shape
  {
    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      Path()
        .move(to: bounds.origin)
        .addLine(to: SIMD2(bounds.center.x, bounds.maxY))
        .addLine(to: SIMD2(bounds.maxX, bounds.y))
    }
  }
}
