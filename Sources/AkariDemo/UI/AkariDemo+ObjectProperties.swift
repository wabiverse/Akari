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
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published

extension AkariDemo
{
  /// The Object properties, for the active prim.
  @MainActor
  struct ObjectProperties: View
  {
    @State private var inspector: Inspector

    init(inspector: Inspector)
    {
      _inspector = State(wrappedValue: inspector)
    }

    private func vector(_ title: String, _ keyPath: ReferenceWritableKeyPath<Inspector, SIMD3<Double>>, step: Double,
                        _ format: @escaping (Double) -> String) -> some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        ForEach([0, 1, 2], id: \.self)
        { i in
          Properties.row(i == 0 ? title : "")
          {
            NumberField(value: inspector.transform(keyPath, i), step: step, label: ["X", "Y", "Z"][i], format: format)
          }
        }
      }
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          Properties.row("Name") { Readout(inspector.name) }
          Properties.row("Path") { Readout(inspector.path ?? "") }
          Properties.row("Edits To") { Readout(inspector.route) }
          PropertiesPanel("Transform")
          {
            vector("Location", \.location, step: 0.1) { String(format: "%.4g", $0) }
            vector("Rotation", \.rotation, step: 1) { String(format: "%.4g°", $0) }
            Properties.row("Mode") { Readout("XYZ Euler") }
            vector("Scale", \.scale, step: 0.1) { String(format: "%.4g", $0) }
          }

          PropertiesPanel("Relations")
          {
            Properties.row("Type") { Readout(inspector.typeName.IsEmpty() ? "—" : inspector.typeName.string) }
            Properties.row("Kind") { Readout(inspector.kind.isEmpty ? "—" : inspector.kind) }
            Properties.row("Parent")
            {
              Readout(inspector.path.map { ($0 as NSString).deletingLastPathComponent } ?? "")
            }

            Properties.row("Purpose")
            {
              Dropdown(options: Inspector.purposes.map(\.string),
                       selection: inspector.$purpose.onChange
                       { p in
                         if let token = Inspector.purposes.first(where: { $0.string == p }) { inspector.token(.purpose, token) }
                       })
            }
          }

          PropertiesPanel("Visibility")
          {
            Properties.check("Show in Viewports & Renders", inspector.flag(.visible))
            Properties.check("Active", inspector.flag(.active))
          }

          PropertiesPanel("Instancing", expanded: false)
          {
            Properties.check("Instanceable", inspector.flag(.instanceable))
          }

          PropertiesPanel("Custom Properties", expanded: false)
          {
            ForEach(Array(inspector.attributes.indices), id: \.self)
            { i in
              Properties.row(inspector.attributes[i].name.string) { Readout(inspector.attributes[i].value) }
            }
          }
        }
        .padding(6)
      }
    }
  }

  /// The Object Data properties, a camera's lens or a light's.
  @MainActor
  struct DataProperties: View
  {
    @State private var inspector: Inspector

    init(inspector: Inspector)
    {
      _inspector = State(wrappedValue: inspector)
    }

    private func field(_ label: String, _ binding: Binding<Double>, step: Double, range: ClosedRange<Double> = -1e9 ... 1e9,
                       _ format: @escaping (Double) -> String) -> some View
    {
      Properties.row(label) { NumberField(value: binding, range: range, step: step, format: format) }
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          Properties.row("Name") { Readout(inspector.name) }
          if inspector.isCamera { camera } else { light }
        }
        .padding(6)
      }
    }

    @ViewBuilder
    private var camera: some View
    {
      PropertiesPanel("Lens")
      {
        Properties.row("Type")
        {
          Dropdown(options: Inspector.projections.map(\.label),
                   selection: inspector.$projection.onChange
                   { p in
                     if let token = Inspector.projections.first(where: { $0.label == p })?.token { inspector.token(.projection, token) }
                   })
        }

        field("Focal Length", inspector.number(.focalLength, fallback: 50), step: 1, range: 1 ... 5000) { String(format: "%.1f mm", $0) }
        field("Shift X", inspector.number(.horizontalApertureOffset), step: 0.1) { String(format: "%.3f mm", $0) }
        field("Y", inspector.number(.verticalApertureOffset), step: 0.1) { String(format: "%.3f mm", $0) }
        field("Clip Start", inspector.number(.clippingRange, 0, fallback: 1), step: 0.1, range: 1e-6 ... 1e9) { String(format: "%.4g", $0) }
        field("End", inspector.number(.clippingRange, 1, fallback: 1_000_000), step: 10, range: 1e-6 ... 1e12) { String(format: "%.4g", $0) }
      }

      PropertiesPanel("Camera")
      {
        Properties.row("Sensor Fit") { Readout("Horizontal") }
        field("Size", inspector.number(.horizontalAperture, fallback: 20.955), step: 0.5, range: 0.01 ... 1000) { String(format: "%.2f mm", $0) }
        field("Height", inspector.number(.verticalAperture, fallback: 15.2908), step: 0.5, range: 0.01 ... 1000) { String(format: "%.2f mm", $0) }
      }

      PropertiesPanel("Depth of Field")
      {
        field("Focus Distance", inspector.number(.focusDistance), step: 0.1, range: 0 ... 1e9) { String(format: "%.3g", $0) }
        field("F-Stop", inspector.number(.fStop), step: 0.1, range: 0 ... 128) { $0 > 0 ? String(format: "%.1f", $0) : "Off" }
      }
    }

    @ViewBuilder
    private var light: some View
    {
      PropertiesPanel("Light")
      {
        Properties.row("Type") { Readout(inspector.typeName.string.replacingOccurrences(of: "Light", with: "")) }
        Properties.row("Color") { ColorField(color: inspector.lightColor) }
        field("Intensity", inspector.number(.inputsIntensity, fallback: 1), step: 1, range: 0 ... 1e9) { String(format: "%.4g", $0) }
        field("Exposure", inspector.number(.inputsExposure), step: 0.1, range: -32 ... 32) { String(format: "%+.2f EV", $0) }
        switch inspector.typeName
        {
          case .sphereLight, .diskLight:
            field("Radius", inspector.number(.inputsRadius, fallback: 0.5), step: 0.01, range: 0 ... 1e6) { String(format: "%.4g", $0) }
          case .rectLight:
            field("Size X", inspector.number(.inputsWidth, fallback: 1), step: 0.1, range: 0 ... 1e6) { String(format: "%.4g", $0) }
            field("Y", inspector.number(.inputsHeight, fallback: 1), step: 0.1, range: 0 ... 1e6) { String(format: "%.4g", $0) }
          case .distantLight:
            field("Angle", inspector.number(.inputsAngle, fallback: 0.53), step: 0.1, range: 0 ... 180) { String(format: "%.2f°", $0) }
          case .cylinderLight:
            field("Radius", inspector.number(.inputsRadius, fallback: 0.5), step: 0.01, range: 0 ... 1e6) { String(format: "%.4g", $0) }
            field("Length", inspector.number(.inputsLength, fallback: 1), step: 0.1, range: 0 ... 1e6) { String(format: "%.4g", $0) }
          default:
            EmptyView()
        }
      }

      if inspector.values[.inputsShapingConeAngle] != nil
      {
        PropertiesPanel("Spot Shape")
        {
          field("Spot Size", inspector.number(.inputsShapingConeAngle, scale: 2, fallback: 90), step: 1, range: 1 ... 360) { String(format: "%.1f°", $0) }
          field("Blend", inspector.number(.inputsShapingConeSoftness), step: 0.01, range: 0 ... 1) { String(format: "%.3f", $0) }
        }
      }
    }
  }
}
