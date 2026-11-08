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

import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd

extension AkariDemo.SceneEdit
{
  nonisolated static func describe(_ attribute: Usd.Attribute, _ t: Pixar.UsdTimeCode) -> Attribute
  {
    var value = Pixar.VtValue()
    _ = attribute.Get(&value, t)
    return describe(attribute.name, value, type: attribute.typeName, animated: attribute.GetNumTimeSamples() > 0)
  }

  nonisolated static func describe(_ name: Tf.Token, _ value: Pixar.VtValue, type: Sdf.ValueTypeName,
                                   animated: Bool) -> Attribute
  {
    var numbers = [Double](repeating: 0, count: 3)
    let count = Int(Pixar.HdAkariValueNumbers(value, &numbers))
    let text = String(Pixar.HdAkariDescribeValue(value))
    return Attribute(name: name, isColor: type == .color3f || type == .color3d || type == .color3h,
                     value: animated ? text + "  (animated)" : text,
                     components: count == 1 || count == 3 ? count : 0, values: numbers)
  }

  /// `shader`'s definition in the Sdr registry, nil when none is registered.
  nonisolated static func definition(_ shader: Pixar.UsdShadeShader) -> Pixar.SdrShaderNode?
  {
    var id = Tf.Token()
    guard shader.GetShaderId(&id) else { return nil }
    return Pixar.SdrRegistry.GetInstance().GetShaderNodeByIdentifier(id, Pixar.TfTokenVector())
  }

  /// The type `name` takes when `prim` is a shader whose definition has that input.
  nonisolated static func definedType(_ prim: UsdPrim, _ name: Tf.Token) -> Sdf.ValueTypeName?
  {
    let namespace = Tf.Token.inputs.string
    guard prim.isA(.shader), name.string.hasPrefix(namespace),
          let property = definition(Pixar.UsdShadeShader(prim))?.GetShaderInput(Tf.Token(String(name.string.dropFirst(namespace.count))))
    else { return nil }
    return property.sdfType
  }

  nonisolated static func boundMaterial(_ prim: UsdPrim) -> Pixar.UsdShadeMaterial?
  {
    func bound(_ p: UsdPrim) -> Pixar.UsdShadeMaterial?
    {
      let material = Pixar.UsdShadeMaterialBindingAPI(p).ComputeBoundMaterial(.allPurpose, nil, true)
      return material.GetPrim().isValid ? material : nil
    }

    if let material = bound(prim) { return material }

    let range = Pixar.UsdPrimRange(prim, Pixar.UsdTraverseInstanceProxies())
    for child in IteratorSequence(range)
    {
      if !child.isA(.gprim) { continue }

      if let material = bound(child) { return material }
    }

    return nil
  }

  nonisolated static func inspect(_ stage: UsdStage, _ path: String, _ time: Double) -> Prim
  {
    guard let prim = prim(stage, path) else { return Prim() }
    let t = Pixar.UsdTimeCode(time)
    var out = Prim(valid: true, typeName: prim.typeName)
    var kind = Tf.Token()
    if Pixar.UsdModelAPI(prim).GetKind(&kind) { out.kind = kind.string }
    out.active = prim.IsActive()
    out.instanceable = prim.IsInstanceable()
    out.camera = prim.isA(.camera)
    out.light = prim.hasAPI(.lightAPI)
    if out.camera { _ = Pixar.UsdGeomCamera(prim).GetProjectionAttr().Get(&out.projection, t) }
    out.route = AkariDemo.Authoring.site(stage, path)?.label ?? ""
    if prim.isA(.imageable)
    {
      let imageable = Pixar.UsdGeomImageable(prim)
      out.visible = !invisible(prim, t)
      _ = imageable.GetPurposeAttr().Get(&out.purpose, Pixar.UsdTimeCode.Default())
    }

    out.geometry = prim.isA(.gprim) || (prim.IsModel() && !out.camera && !out.light)
    out.attributes = prim.GetAuthoredAttributes().map { describe($0, t) }
    guard out.geometry, let material = boundMaterial(prim) else { return out }
    out.material = material.GetPath().string
    var ri = Pixar.TfTokenVector()
    ri.push_back(.riRenderContext)
    let rman = material.ComputeSurfaceSource(ri, nil, nil)
    var id = Tf.Token()
    let lookdev = rman.GetPrim().isValid && rman.GetShaderId(&id) && id == UsdShade.Shader.ShaderId.pxrSurface.getToken()
    var contexts = Pixar.TfTokenVector()
    contexts.push_back(.universalRenderContext)
    contexts.push_back(.riRenderContext)
    let shader = lookdev ? rman : material.ComputeSurfaceSource(contexts, nil, nil)
    guard shader.GetPrim().isValid else { return out }
    out.shader = shader.GetPath().string
    out.materialRoute = AkariDemo.Authoring.site(stage, out.shader)?.label ?? ""
    func described(_ input: Pixar.UsdShadeInput) -> Attribute
    {
      #if compiler(>=6.4)
        var a = describe(input.GetAttrConsuming(), t)
      #else
        var a = describe(input.GetAttr(), t)
      #endif
      a.texture = source(of: input, t)
      return a
    }
    // every input the definition has, at its default until authored, on the page the definition puts it.
    var listed = Set<Tf.Token>()
    if let node = definition(shader)
    {
      for name in node.shaderInputNames
      {
        guard let property = node.GetShaderInput(name) else { continue }
        let input = shader.GetInput(name)
        var a = input.IsDefined() ? described(input)
          : describe(Tf.Token(Tf.Token.inputs.string + name.string), property.defaultValueAsSdfType,
                     type: property.sdfType, animated: false)
        a.label = property.label.string
        a.page = property.page.string
        a.options = property.options.map { Option(label: $0.label.string, value: Double($0.value.string) ?? 0) }
        a.checkbox = property.widget == .checkBox
        out.inputs.append(a)
        listed.insert(name)
      }
    }

    for input in shader.GetInputs(true) where !listed.contains(input.GetBaseName())
    {
      out.inputs.append(described(input))
    }

    return out
  }

  /// The texture file, or else the shader, feeding `input`, empty when nothing does.
  nonisolated static func source(of input: Pixar.UsdShadeInput, _ t: Pixar.UsdTimeCode) -> String
  {
    guard input.HasConnectedSource() else { return "" }
    let producers = input.GetValueProducingAttributes(false)
    for i in 0 ..< Int(producers.size())
    {
      let shader = producers[i].GetPrim()
      for input in [AkariDemo.ShaderInput.file, .filename]
      {
        guard let attribute = shader.attribute(named: input.attribute) else { continue }
        var file = Pixar.SdfAssetPath()
        guard attribute.Get(&file, t) else { continue }
        #if compiler(>=6.4)
          let path = String(file.GetAssetPathConsuming())
        #else
          let path = String(file.GetAssetPath())
        #endif
        if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
      }

      return shader.name.string
    }

    return ""
  }

  nonisolated static func values(_ stage: UsdStage, _ path: String, _ names: [Tf.Token], _ time: Double) -> [Double]
  {
    let p = prim(stage, path)
    let t = Pixar.UsdTimeCode(time)
    return names.flatMap
    { name -> [Double] in
      var n = [Double](repeating: .nan, count: 3)
      if let p, let attribute = p.attribute(named: name)
      {
        var value = Pixar.VtValue()
        if attribute.Get(&value, t) { _ = Pixar.HdAkariValueNumbers(value, &n) }
      }

      return n
    }
  }

  @discardableResult
  nonisolated static func setValue(_ stage: UsdStage, _ path: String, _ name: Tf.Token, _ values: [Double],
                                   type: Sdf.ValueTypeName) -> Bool
  {
    guard !values.isEmpty else { return false }
    let source = prim(stage, path)?.attribute(named: name)
    let wrote = AkariDemo.Authoring.edit(stage, path)
    { prim, _ in
      var attribute = prim.attribute(named: name)
      if attribute == nil
      {
        attribute = source.map { prim.CreateAttribute(name, $0.typeName, $0.IsCustom(), $0.GetVariability()) }
          ?? prim.createAttribute(name: name, typeName: definedType(prim, name) ?? type)
      }

      guard let attribute, attribute.isValid else { return false }
      let x = values[0], y = values.count > 1 ? values[1] : x, z = values.count > 2 ? values[2] : x
      let time = Pixar.UsdTimeCode.Default()
      switch attribute.typeName
      {
        case .float: return attribute.set(Float(x))
        case .double: return attribute.set(x)
        case .int: return attribute.set(Int32(x.rounded()))
        case .bool: return attribute.set(x != 0)
        case .float2: return attribute.Set(Pixar.GfVec2f(Float(x), Float(y)), time)
        case .double2: return attribute.Set(Pixar.GfVec2d(x, y), time)
        case .color3f, .float3, .vector3f, .normal3f, .point3f: return attribute.set(Pixar.GfVec3f(Float(x), Float(y), Float(z)))
        case .color3d, .double3, .vector3d, .normal3d, .point3d: return attribute.set(Pixar.GfVec3d(x, y, z))
        default: return false
      }
    }

    if wrote, let shader = prim(stage, path) { syncPreview(stage, shader) }
    return wrote
  }

  @discardableResult
  nonisolated static func setToken(_ stage: UsdStage, _ path: String, _ name: Tf.Token, _ value: Tf.Token) -> Bool
  {
    AkariDemo.Authoring.edit(stage, path)
    { prim, _ in
      let attribute = prim.attribute(named: name) ?? prim.createAttribute(name: name, typeName: .token)
      return attribute?.Set(value, Pixar.UsdTimeCode.Default()) ?? false
    }
  }

  @discardableResult
  nonisolated static func setActive(_ stage: UsdStage, _ path: String, _ active: Bool) -> Bool
  {
    AkariDemo.Authoring.edit(stage, path) { prim, _ in prim.SetActive(active) }
  }

  @discardableResult
  nonisolated static func setInstanceable(_ stage: UsdStage, _ path: String, _ instanceable: Bool) -> Bool
  {
    AkariDemo.Authoring.edit(stage, path) { prim, _ in prim.SetInstanceable(instanceable) }
  }

  /// The UsdPreviewSurface on the universal surface of the material whose ri surface is `shader`.
  nonisolated static func previewOf(_ shader: UsdPrim) -> UsdPrim?
  {
    var p = shader.GetParent()
    while p.isValid, !p.isA(.material) { p = p.GetParent() }
    guard p.isValid else { return nil }
    let material = Pixar.UsdShadeMaterial(p)
    func source(_ context: Tf.Token, _ id: UsdShade.Shader.ShaderId) -> UsdPrim?
    {
      var contexts = Pixar.TfTokenVector()
      contexts.push_back(context)
      let s = material.ComputeSurfaceSource(contexts, nil, nil)
      var found = Tf.Token()
      guard s.GetPrim().isValid, s.GetShaderId(&found), found == id.getToken() else { return nil }
      return s.GetPrim()
    }

    guard let rman = source(.riRenderContext, .pxrSurface), rman.GetPath() == shader.GetPath() else { return nil }
    return source(.universalRenderContext, .usdPreviewSurface)
  }

  /// Writes `shader`'s PxrSurface onto its preview with HdAkari's mapping, skipping connected inputs.
  nonisolated static func syncPreview(_ stage: UsdStage, _ shader: UsdPrim)
  {
    guard let preview = previewOf(shader) else { return }
    let t = Pixar.UsdTimeCode.Default()
    let pxr = Pixar.UsdShadeShader(shader), surface = Pixar.UsdShadeShader(preview)
    // an input a shader doesn't have comes back without a prim, which USD throws on, not just invalid.
    func authored(_ s: Pixar.UsdShadeShader, _ input: AkariDemo.ShaderInput) -> Pixar.UsdShadeInput?
    {
      let found = s.GetInput(input.token)
      return found.IsDefined() ? found : nil
    }

    func connected(_ s: Pixar.UsdShadeShader, _ input: AkariDemo.ShaderInput) -> Bool
    {
      authored(s, input)?.HasConnectedSource() ?? false
    }

    var pxrSurface = Pixar.HdAkariPxrSurface()
    for input in pxr.GetInputs(true)
    {
      #if compiler(>=6.4)
        let attribute = input.GetAttrConsuming()
      #else
        let attribute = input.GetAttr()
      #endif
      var value = Pixar.VtValue()
      if attribute.Get(&value, t) { _ = Pixar.HdAkariSetPxrSurfaceInput(&pxrSurface, input.GetBaseName(), value) }
    }

    let look = Pixar.HdAkariApproximatePxrSurface(pxrSurface)
    let base = SIMD3(look.color[0], look.color[1], look.color[2])
    let emissive = SIMD3(look.emissive[0], look.emissive[1], look.emissive[2])
    let floats: [(AkariDemo.ShaderInput, Float, [AkariDemo.ShaderInput])] = [
      (.metallic, look.metallic, [.diffuseGain, .specularFaceColor]),
      (.roughness, look.roughness, [.specularRoughness]),
      (.opacity, look.opacity, [.presence])
    ]
    let colors: [(AkariDemo.ShaderInput, SIMD3<Float>, [AkariDemo.ShaderInput])] = [
      (.diffuseColor, base, [.diffuseColor, .specularFaceColor]),
      (.emissiveColor, emissive, [.glowColor, .glowGain])
    ]
    let free = { (input: AkariDemo.ShaderInput, from: [AkariDemo.ShaderInput]) in
      !connected(surface, input) && !from.contains(where: { connected(pxr, $0) })
    }

    _ = AkariDemo.Authoring.edit(stage, preview.GetPath().string)
    { prim, _ in
      var target = Pixar.UsdShadeShader(prim)
      for (input, value, from) in floats where free(input, from)
      {
        _ = target.CreateInput(input.token, .float).set(value)
      }

      for (input, value, from) in colors where free(input, from)
      {
        _ = target.CreateInput(input.token, .color3f).set(Pixar.GfVec3f(value.x, value.y, value.z))
      }

      return true
    }
  }

  /// A PxrSurface material for `path` on the ri surface, its UsdPreviewSurface on the universal one, in the department layer.
  nonisolated static func newMaterial(_ stage: UsdStage, _ path: String) -> String
  {
    guard let target = prim(stage, path), !target.IsInstanceProxy() else { return "" }
    let department = AkariDemo.Authoring.department(stage)
    Pixar.HdAkariJournalWatch(department)
    let previous = AkariDemo.Authoring.editTarget(stage)
    stage.SetEditTarget(AkariDemo.Authoring.target(department))
    defer { stage.SetEditTarget(previous) }
    let home = stage.GetDefaultPrim()
    let owner: Pixar.SdfPath = home.isValid ? home.getPath() : Sdf.Path.absoluteRootPath()
    let scope = owner.AppendChild(Tf.Token("Materials"))
    if !stage.GetPrimAtPath(scope).isValid { _ = stage.DefinePrim(scope, .scope) }
    let materialPath = uniqueChild(stage, scope, "Material")
    let material = UsdShade.Material.define(stage, path: materialPath)
    var shader = UsdShade.Shader.define(stage, path: materialPath.AppendChild(UsdShade.Shader.ShaderId.pxrSurface.getToken()))
    _ = shader.createIdAttr(.pxrSurface)
    func input(_ input: AkariDemo.ShaderInput, _ type: Sdf.ValueTypeName) -> Pixar.UsdShadeInput
    {
      shader.CreateInput(input.token, type)
    }

    _ = input(.diffuseGain, .float).set(Float(1))
    _ = input(.diffuseColor, .color3f).set(Pixar.GfVec3f(0.8, 0.8, 0.8))
    _ = input(.specularFaceColor, .color3f).set(Pixar.GfVec3f(0.04, 0.04, 0.04))
    _ = input(.specularEdgeColor, .color3f).set(Pixar.GfVec3f(1, 1, 1))
    _ = input(.specularRoughness, .float).set(Float(0.5))
    _ = input(.clearcoatFaceColor, .color3f).set(Pixar.GfVec3f(0, 0, 0))
    _ = input(.clearcoatRoughness, .float).set(Float(0.03))
    _ = input(.glowGain, .float).set(Float(0))
    _ = input(.glowColor, .color3f).set(Pixar.GfVec3f(1, 1, 1))
    _ = input(.presence, .float).set(Float(1))
    let bxdf = shader.CreateOutput(Tf.Token("out"), .token)
    _ = material.createSurfaceOutput(renderContext: .riRenderContext).ConnectToSource(bxdf)
    var preview = UsdShade.Shader.define(stage, path: materialPath.AppendChild(Tf.Token("PreviewSurface")))
    _ = preview.createIdAttr(.usdPreviewSurface)
    let surface = preview.CreateOutput(.surface, .token)
    _ = material.createSurfaceOutput().ConnectToSource(surface)
    _ = UsdShade.MaterialBindingAPI.apply(target).bind(material)
    syncPreview(stage, shader.GetPrim())
    return materialPath.string
  }
}
