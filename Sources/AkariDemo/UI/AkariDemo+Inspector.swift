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
  /// The active prim as the Object, Object Data and Material properties tabs show and edit it.
  @MainActor
  final class Inspector: ObservableObject
  {
    struct Field
    {
      var name: Tf.Token
      var isColor: Bool
      var value: String
      var components: Int
      var values: SIMD3<Double>
      var texture: String
      var label = ""
      var page = ""
      var options: [SceneEdit.Option] = []
      var checkbox = false
    }

    /// A page of a shader's inputs, as its definition groups them, with its nested pages.
    struct Page
    {
      var title: String
      var inputs: [Int] = []
      var pages: [Page] = []
    }

    @Published var path: String?
    @Published var typeName = Tf.Token()
    @Published var kind = ""
    @Published var purpose: String? = Tf.Token.default_.string
    @Published var active = true
    @Published var instanceable = false
    @Published var visible = true
    @Published var geometry = false
    @Published var isCamera = false
    @Published var isLight = false
    @Published var location = SIMD3<Double>.zero
    @Published var rotation = SIMD3<Double>.zero
    @Published var scale = SIMD3<Double>(repeating: 1)
    @Published var attributes: [Field] = []
    @Published var material = ""
    @Published var shader = ""
    @Published var inputs: [Field] = []
    @Published var route = ""
    @Published var materialRoute = ""
    @Published var values: [Tf.Token: [Double]] = [:]
    @Published var projection: String? = Inspector.projections[0].label

    weak var layout: Layout?
    private let hydra: Hydra.RenderEngine
    private var preview: MaterialPreview?
    private var parent = matrix_identity_double4x4
    private var lastCheckpoint = Date.distantPast

    nonisolated static let cameraNames: [Tf.Token] = [.focalLength, .horizontalAperture, .verticalAperture,
                                                      .horizontalApertureOffset, .verticalApertureOffset, .clippingRange,
                                                      .fStop, .focusDistance]
    nonisolated static let lightNames: [Tf.Token] = [.inputsIntensity, .inputsExposure, .inputsColor, .inputsRadius,
                                                     .inputsWidth, .inputsHeight, .inputsAngle, .inputsLength,
                                                     .inputsShapingConeAngle, .inputsShapingConeSoftness]
    static let purposes: [Tf.Token] = [.default_, .render, .proxy, .guide]
    static let projections: [(label: String, token: Tf.Token)] = [("Perspective", .perspective), ("Orthographic", .orthographic)]

    init(hydra: Hydra.RenderEngine)
    {
      self.hydra = hydra
    }

    var name: String
    {
      path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? ""
    }

    /// Reads the prim at `path`, or clears the tabs for none.
    func load(_ path: String?)
    {
      guard let path else
      {
        self.path = nil
        return
      }

      let time = hydra.currentTimeCode
      let names = Self.cameraNames + Self.lightNames
      hydra.performOnFrameQueue
      { [self] in
        let stage = hydra.stage
        let info = SceneEdit.inspect(stage, path, time)
        guard info.valid else { return }
        let flat = SceneEdit.values(stage, path, names, time)
        let placement = Layout.placement(stage, path, time)
        let fields = { (list: [SceneEdit.Attribute]) in
          list.map
          { a -> Field in
            let v = Array(a.values)
            return Field(name: a.name, isColor: a.isColor, value: String(a.value), components: Int(a.components),
                         values: v.count == 3 ? SIMD3(v[0], v[1], v[2]) : .zero, texture: String(a.texture),
                         label: a.label, page: a.page, options: a.options, checkbox: a.checkbox)
          }
        }

        let attributes = fields(Array(info.attributes))
        let inputs = fields(Array(info.inputs))
        let typeName = info.typeName, kind = String(info.kind), purpose = info.purpose
        let camera = info.camera, light = info.light, projection = info.projection
        let active = info.active, instanceable = info.instanceable, visible = info.visible, geometry = info.geometry
        let material = info.material, shader = info.shader, route = info.route, materialRoute = info.materialRoute
        var values: [Tf.Token: [Double]] = [:]
        for (i, name) in (Self.cameraNames + Self.lightNames).enumerated() where i * 3 + 2 < flat.count
        {
          let v = Array(flat[i * 3 ..< i * 3 + 3])
          if !v[0].isNaN { values[name] = v }
        }

        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          self.path = path
          self.typeName = typeName
          self.kind = kind
          self.purpose = purpose.string
          self.isCamera = camera
          self.isLight = light
          self.active = active
          self.instanceable = instanceable
          self.visible = visible
          self.geometry = geometry
          self.attributes = attributes
          self.material = material
          self.preview?.show(material: material)
          self.shader = shader
          self.inputs = inputs
          self.route = route
          self.materialRoute = materialRoute
          self.values = values
          self.projection = Self.projections.first { $0.token == projection }?.label ?? Self.projections[0].label
          if let placement { self.follow(placement) }
        }
      }
    }

    /// Takes a transform the viewport changed.
    func follow(_ placement: Layout.Placement)
    {
      parent = placement.parent
      let (t, r, s) = Self.euler(placement.local)
      if simd_distance(t, location) > 1e-9 { location = t }
      if simd_distance(r, rotation) > 1e-7 { rotation = r }
      if simd_distance(s, scale) > 1e-9 { scale = s }
    }

    /// Translation, XYZ Euler rotation in degrees and scale, as the properties show a transform.
    nonisolated static func euler(_ m: simd_double4x4) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
    {
      let (t, q, s) = Layout.decompose(m)
      let r = simd_double3x3(q)
      let y = asin(max(-1, min(1, -r.columns.0.z)))
      let x = atan2(r.columns.1.z, r.columns.2.z)
      let z = atan2(r.columns.0.y, r.columns.0.x)
      return (t, SIMD3(x, y, z) * 180 / .pi, s)
    }

    nonisolated static func compose(_ t: SIMD3<Double>, _ degrees: SIMD3<Double>, _ s: SIMD3<Double>) -> simd_double4x4
    {
      let r = degrees * .pi / 180
      let qx = simd_quatd(angle: r.x, axis: SIMD3(1, 0, 0))
      let qy = simd_quatd(angle: r.y, axis: SIMD3(0, 1, 0))
      let qz = simd_quatd(angle: r.z, axis: SIMD3(0, 0, 1))
      return Layout.compose(t, qz * qy * qx, s)
    }

    private func checkpoint()
    {
      if Date().timeIntervalSince(lastCheckpoint) > 1 { layout?.checkpoint() }
      lastCheckpoint = Date()
    }

    private func writeTransform()
    {
      guard let path else { return }
      checkpoint()
      layout?.setLocals([path: Self.compose(location, rotation, scale)])
    }

    func transform(_ keyPath: ReferenceWritableKeyPath<Inspector, SIMD3<Double>>, _ i: Int) -> Binding<Double>
    {
      Binding(get: { self[keyPath: keyPath][i] },
              set:
              { value in
                self[keyPath: keyPath][i] = value
                self.writeTransform()
              })
    }

    /// Writes numbers to an attribute of the prim, or of `target`.
    func write(_ name: Tf.Token, _ numbers: [Double], type: Sdf.ValueTypeNameType = .float, on target: String? = nil)
    {
      guard let path = target ?? path else { return }
      checkpoint()
      let hydra = hydra
      hydra.performOnFrameQueue
      {
        SceneEdit.setValue(hydra.stage, path, name, numbers, type: Sdf.getValueType(for: type))
      }
    }

    func token(_ name: Tf.Token, _ value: Tf.Token)
    {
      guard let path else { return }
      checkpoint()
      let hydra = hydra
      hydra.performOnFrameQueue { SceneEdit.setToken(hydra.stage, path, name, value) }
    }

    func number(_ name: Tf.Token, _ i: Int = 0, scale: Double = 1, fallback: Double = 0) -> Binding<Double>
    {
      Binding(get: { (self.values[name]?[i] ?? fallback) * scale },
              set:
              { value in
                var v = self.values[name] ?? [fallback, fallback, fallback]
                v[i] = value / scale
                self.values[name] = v
                self.write(name, name == .clippingRange ? Array(v.prefix(2)) : [v[0]], type: name == .clippingRange ? .float2 : .float)
              })
    }

    var lightColor: Binding<SIMD3<Float>>
    {
      Binding(get: { SIMD3<Float>((self.values[.inputsColor].map { SIMD3($0[0], $0[1], $0[2]) } ?? SIMD3(1, 1, 1))) },
              set:
              { color in
                let v = [Double(color.x), Double(color.y), Double(color.z)]
                self.values[.inputsColor] = v
                self.write(.inputsColor, v, type: .color3f)
              })
    }

    enum Flag
    {
      case visible, active, instanceable
    }

    func flag(_ flag: Flag) -> Binding<Bool>
    {
      let keyPath: ReferenceWritableKeyPath<Inspector, Bool> = switch flag
      {
        case .visible: \.visible
        case .active: \.active
        case .instanceable: \.instanceable
      }

      return Binding(get: { self[keyPath: keyPath] },
                     set:
                     { on in
                       self[keyPath: keyPath] = on
                       guard let path = self.path else { return }
                       self.checkpoint()
                       let hydra = self.hydra
                       hydra.performOnFrameQueue
                       {
                         switch flag
                         {
                           case .visible: SceneEdit.setVisible(hydra.stage, path, on)
                           case .active: _ = SceneEdit.setActive(hydra.stage, path, on)
                           case .instanceable: _ = SceneEdit.setInstanceable(hydra.stage, path, on)
                         }
                       }
                     })
    }

    func input(_ i: Int) -> Binding<Double>
    {
      Binding(get: { i < self.inputs.count ? self.inputs[i].values.x : 0 },
              set:
              { value in
                guard i < self.inputs.count else { return }
                self.inputs[i].values.x = value
                self.write(self.inputs[i].name, [value], on: self.shader)
              })
    }

    func inputColor(_ i: Int) -> Binding<SIMD3<Float>>
    {
      Binding(get: { i < self.inputs.count ? SIMD3<Float>(self.inputs[i].values) : .zero },
              set:
              { color in
                guard i < self.inputs.count else { return }
                self.inputs[i].values = SIMD3<Double>(color)
                self.write(self.inputs[i].name, [Double(color.x), Double(color.y), Double(color.z)], type: .color3f,
                           on: self.shader)
              })
    }

    /// The Material tab's preview, made the first time the tab shows.
    /// The inputs on their pages in the order the definition first gives them, none when it has no pages.
    var pages: [Page]
    {
      guard inputs.contains(where: { !$0.page.isEmpty }) else { return [] }
      func slot(_ title: String, in pages: inout [Page]) -> Int
      {
        if let i = pages.firstIndex(where: { $0.title == title }) { return i }
        pages.append(Page(title: title))
        return pages.count - 1
      }

      var pages: [Page] = []
      for (i, field) in inputs.enumerated()
      {
        let path = field.page.isEmpty ? ["Other"] : field.page.split(separator: ":").map(String.init)
        let top = slot(path[0], in: &pages)
        if path.count == 1
        {
          pages[top].inputs.append(i)
        }
        else
        {
          let sub = slot(path[1...].joined(separator: " "), in: &pages[top].pages)
          pages[top].pages[sub].inputs.append(i)
        }
      }

      return pages
    }

    func inputOption(_ i: Int) -> Binding<SceneEdit.Option?>
    {
      Binding(get: { i < self.inputs.count ? self.inputs[i].options.first { $0.value == self.inputs[i].values.x } : nil },
              set:
              { option in
                guard let option, i < self.inputs.count else { return }
                self.inputs[i].values.x = option.value
                self.write(self.inputs[i].name, [option.value], type: .int, on: self.shader)
              })
    }

    func inputFlag(_ i: Int) -> Binding<Bool>
    {
      Binding(get: { i < self.inputs.count && self.inputs[i].values.x != 0 },
              set:
              { on in
                guard i < self.inputs.count else { return }
                self.inputs[i].values.x = on ? 1 : 0
                self.write(self.inputs[i].name, [on ? 1 : 0], type: .int, on: self.shader)
              })
    }

    func materialPreview() -> MaterialPreview
    {
      if let preview { return preview }
      let made = MaterialPreview(host: hydra)
      made.show(material: material)
      preview = made
      return made
    }

    func newMaterial()
    {
      guard let path else { return }
      layout?.checkpoint()
      let hydra = hydra
      hydra.performOnFrameQueue
      {
        _ = SceneEdit.newMaterial(hydra.stage, path)
        DispatchQueue.main.async { [weak self = self] in self?.load(path) }
      }
    }

    /// The UI's name for a shader input, or its own name in words.
    static func label(_ input: Tf.Token) -> String
    {
      if let known = ShaderInput.allCases.first(where: { $0.attribute == input }) { return known.label }
      let namespace = Tf.Token.inputs.string
      let name = input.string.hasPrefix(namespace) ? String(input.string.dropFirst(namespace.count)) : input.string
      var words = ""
      for c in name
      {
        if c.isUppercase, !words.isEmpty { words.append(" ") }
        words.append(words.isEmpty ? Character(c.uppercased()) : c)
      }

      return words
    }
  }
}
