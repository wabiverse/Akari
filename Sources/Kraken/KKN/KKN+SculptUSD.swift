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
import CxxStdlib
import Foundation
import HydraKit
import simd
import VoxSplat

extension Kraken
{
  /// reading and writing a sculpt as usd prims in its own binary layer beside the scene, the whole sculpt kept there
  enum SculptUSD
  {
    nonisolated static let voxelName = Tf.Token("akari:sculpt:voxelSize")
    /// where older scenes pointed at a volume file beside them, read but never written
    nonisolated static let volumeName = Tf.Token("akari:sculpt:volume")
    nonisolated static let baseName = Tf.Token("akari:sculpt:base")
    nonisolated static let glossName = Tf.Token("akari:gloss")
    nonisolated static let maskName = Tf.Token("akari:mask")
    nonisolated static let referenceName = Tf.Token("akari:sculpt:reference")
    nonisolated static let surfaceName = Tf.Token("Surface")
    nonisolated static let strokesName = Tf.Token("Strokes")
    nonisolated static let pencilName = Tf.Token("Pencil")

    /// everything a write puts on the stage, made off the main thread
    struct Payload: Sendable
    {
      var path: String?
      var voxel: Float
      var base: SIMD4<UInt8>
      /// the scene the sculpt's own layer goes beside, nil while the scene has never been saved
      var scene: URL?
      var reference: String?
      var points: [SIMD3<Float>] = []
      var normals: [SIMD3<Float>] = []
      var colors: [SIMD3<Float>] = []
      var gloss: [Float] = []
      /// the mask one per point, empty when nothing is masked
      var mask: [Float] = []
      var indices: [Int32] = []
      var splats: SculptSplats?
      var pencil: [SculptPencilStroke] = []
      /// what the surface hashes to, the name its volume is cached under
      var key = ""
    }

    /// a surface color byte as the linear value usd keeps colors in
    nonisolated static func linear(_ byte: UInt8) -> Float
    {
      let c = Float(byte) / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    nonisolated static func linear(_ c: SIMD3<Float>) -> SIMD3<Float>
    {
      SIMD3(c.x <= 0.04045 ? c.x / 12.92 : pow((c.x + 0.055) / 1.055, 2.4),
            c.y <= 0.04045 ? c.y / 12.92 : pow((c.y + 0.055) / 1.055, 2.4),
            c.z <= 0.04045 ? c.z / 12.92 : pow((c.z + 0.055) / 1.055, 2.4))
    }

    nonisolated static func display(_ c: SIMD3<Float>) -> SIMD3<Float>
    {
      SIMD3(c.x <= 0.0031308 ? c.x * 12.92 : 1.055 * pow(c.x, 1 / 2.4) - 0.055,
            c.y <= 0.0031308 ? c.y * 12.92 : 1.055 * pow(c.y, 1 / 2.4) - 0.055,
            c.z <= 0.0031308 ? c.z * 12.92 : 1.055 * pow(c.z, 1 / 2.4) - 0.055)
    }

    /// builds the payload, the welded surface and the splats laid over it
    nonisolated static func payload(chunks: [SculptChunk], pencil: [SculptPencilStroke], frozen: SculptVolume.Frozen, path: String?,
                                    scene: URL?, splatLook: SculptSplats.Look?) -> Payload
    {
      let voxel = frozen.voxel
      let mesh = SculptMesher.welded(chunks, voxel: voxel)
      var out = Payload(path: path, voxel: voxel, base: frozen.base, scene: scene)

      // the scene gets the surface thinned where it is flat and one paint, the painterly strokes still sit on every point
      let dense = SculptSimplify.Surface(points: mesh.points, normals: mesh.normals, colors: mesh.colors,
                                         mask: mask(at: mesh.points, frozen), indices: mesh.indices)
      let thin = SculptSimplify.simplify(dense, tolerance: voxel * 0.05, longest: voxel * 32)
      out.points = thin.points
      out.normals = thin.normals
      out.indices = thin.indices
      out.colors = thin.colors.map { SIMD3(linear($0.x), linear($0.y), linear($0.z)) }
      out.gloss = thin.colors.map { Float($0.w) / 255 }
      out.mask = thin.mask
      out.pencil = pencil
      if let splatLook
      {
        out.splats = SculptSplats.make(points: mesh.points, normals: mesh.normals, colors: mesh.colors, voxel: voxel, look: splatLook)
      }

      out.key = SculptCache.key(points: flat(out.points), indices: out.indices, colors: flat(out.colors), gloss: out.gloss, mask: out.mask)
      return out
    }

    /// the points one after another as plain floats, the way usd lays them out
    nonisolated static func flat(_ points: [SIMD3<Float>]) -> [Float]
    {
      var out: [Float] = []
      out.reserveCapacity(points.count * 3)
      for p in points { out += [p.x, p.y, p.z] }
      return out
    }

    /// the mask at each point from the grid point nearest it, empty when the volume has none
    nonisolated static func mask(at points: [SIMD3<Float>], _ frozen: SculptVolume.Frozen) -> [Float]
    {
      guard frozen.masks.contains(where: { $0.contains { $0 != 0 } }) else { return [] }

      var index: [SIMD3<Int32>: Int] = [:]
      for (i, k) in frozen.keys.enumerated() { index[k] = i }
      return points.map
      { p in
        let g = SIMD3<Int32>((p / frozen.voxel).rounded(.toNearestOrAwayFromZero))
        guard let i = index[SculptVolume.key(g)] else { return 0 }
        let l = SculptVolume.local(g)
        return Float(frozen.masks[i][SculptBrick.index(l.x, l.y, l.z)]) / 255
      }
    }

    /// the sculpt's own layer beside the scene, made and sublayered the first time, nil for a scene never saved
    private nonisolated static func layer(_ stage: UsdStage, scene: URL, name: String) -> SdfLayerHandle?
    {
      let root = stage.getRootLayer()
      guard !root.pointee.IsAnonymous() else { return nil }

      let file = "\(scene.deletingPathExtension().lastPathComponent).\(name).usd"
      let url = scene.deletingLastPathComponent().appendingPathComponent(file).standardizedFileURL
      func inStack() -> SdfLayerHandle?
      {
        stage.GetLayerStack(false).first { URL(fileURLWithPath: $0.realPath).standardizedFileURL == url }
      }

      if let found = inStack() { return found }

      // a new layer named usd is written binary, the scene keeps it as a sublayer so it reads as part of the scene
      let made = FileManager.default.fileExists(atPath: url.path)
        ? Pixar.SdfLayer.FindOrOpen(std.string(url.path), Pixar.SdfLayer.FileFormatArguments())
        : Pixar.SdfLayer.CreateNew(std.string(url.path), Pixar.SdfLayer.FileFormatArguments())

      // a scene opened from somewhere the app can only read keeps its sculpt in the scene's own layers
      guard Pixar.HdAkariIsLayer(made) else { return nil }
      _ = made.pointee.Save(false)
      layers.append(made)
      root.pointee.InsertSubLayerPath(std.string("./\(file)"), 0)
      return inStack()
    }

    nonisolated(unsafe) private static var layers: [Pixar.SdfLayerRefPtr] = []

    /// moves what the scene's other layers hold of the sculpt into its own layer, so none of it stays behind as text
    private nonisolated static func gather(_ stage: UsdStage, _ path: Pixar.SdfPath, into layer: SdfLayerHandle)
    {
      for handle in stage.GetLayerStack(false) where handle.identifier != layer.identifier
      {
        guard handle.pointee.HasSpec(path) else { continue }

        if !layer.pointee.HasSpec(path)
        {
          if !path.GetParentPath().IsAbsoluteRootPath() { _ = Pixar.SdfCreatePrimInLayer(layer, path.GetParentPath()) }
          _ = Pixar.SdfCopySpec(handle, path, layer, path)
        }

        let previous = Kraken.Authoring.editTarget(stage)
        Pixar.HdAkariJournalWatch(handle)
        stage.SetEditTarget(Kraken.Authoring.target(handle))
        _ = stage.RemovePrim(path)
        stage.SetEditTarget(previous)
      }
    }

    /// what a mesh holds of its surface, the part a sculpt on it rewrites
    private nonisolated static let surfaceProperties = ["points", "faceVertexCounts", "faceVertexIndices", "normals", "extent",
                                                        "subdivisionScheme", "creaseIndices", "creaseLengths", "creaseSharpnesses",
                                                        "cornerIndices", "cornerSharpnesses", "holeIndices", "akari:sharpEdges"]

    /// moves a mesh's surface out of the scene's other layers into `layer`, leaving its definition and placement in place
    private nonisolated static func gatherSurface(_ stage: UsdStage, _ path: Pixar.SdfPath, into layer: SdfLayerHandle)
    {
      let prim = stage.GetPrimAtPath(path)
      guard prim.isValid else { return }

      var names = surfaceProperties
      for primvar in Pixar.UsdGeomPrimvarsAPI(prim).GetPrimvars()
      {
        #if compiler(>=6.4) && canImport(Usd)
          let attribute = primvar.GetAttrConsuming()
        #else
          let attribute = primvar.GetAttr()
        #endif
        names += [attribute.name.string, primvar.GetIndicesAttr().name.string]
      }

      for handle in stage.GetLayerStack(false) where handle.identifier != layer.identifier
      {
        guard handle.pointee.HasSpec(path) else { continue }

        let held = names.map { Tf.Token($0) }.filter { handle.pointee.HasSpec(path.AppendProperty($0)) }
        guard !held.isEmpty else { continue }

        // the strongest layer goes first, so what the stage showed is what lands in the sculpt's layer
        for name in held where !layer.pointee.HasSpec(path.AppendProperty(name))
        {
          _ = Pixar.SdfCreatePrimInLayer(layer, path)
          _ = Pixar.SdfCopySpec(handle, path.AppendProperty(name), layer, path.AppendProperty(name))
        }

        let previous = Kraken.Authoring.editTarget(stage)
        Pixar.HdAkariJournalWatch(handle)
        stage.SetEditTarget(Kraken.Authoring.target(handle))
        var owner = stage.GetPrimAtPath(path)
        for name in held { _ = owner.RemoveProperty(name) }
        stage.SetEditTarget(previous)
      }
    }

    /// an image path as the sculpt keeps it, beside the scene when it lives in the scene's folder
    private nonisolated static func asset(_ path: String, scene: URL?) -> String
    {
      guard let scene else { return path }
      let folder = scene.deletingLastPathComponent().standardizedFileURL.path + "/"
      let file = URL(fileURLWithPath: path).standardizedFileURL.path
      return file.hasPrefix(folder) ? "./" + file.dropFirst(folder.count) : path
    }

    /// puts the payload in the sculpt's own layer, or the department layer for an unsaved scene, and returns the sculpt's path
    nonisolated static func author(_ stage: UsdStage, _ payload: Payload) -> String
    {
      let existing = payload.path.map { stage.GetPrimAtPath(Sdf.Path($0)) }
      let path: Pixar.SdfPath
      if let existing, existing.isValid
      {
        path = existing.GetPath()
      }
      else
      {
        let home = stage.GetDefaultPrim()
        let parent: Pixar.SdfPath = home.isValid && home.isA(.xformable) ? home.GetPath() : Sdf.Path.absoluteRootPath()
        path = SceneEdit.uniqueChild(stage, parent, "Sculpt")
      }

      // a mesh sculpted in place carries the sculpt on itself, a sculpt of its own is an xform holding its surface
      let onMesh = stage.GetPrimAtPath(path).isValid && stage.GetPrimAtPath(path).isA(.mesh)
      let surface = onMesh ? path : path.AppendChild(surfaceName)

      let write =
      { () -> String in
        let time = Pixar.UsdTimeCode.Default()
        let any = Pixar.VtValue()
        var root = stage.GetPrimAtPath(path)

        if !root.isValid
        {
          root = UsdGeom.Xform.define(stage, path: path).GetPrim()

          // the sculpt is y up in meters, the stage may be z up in other units
          let unit = Double(SceneEdit.units(stage))
          var m = simd_double4x4(diagonal: SIMD4(unit, unit, unit, 1))
          if !SceneEdit.yUp(stage)
          {
            m = simd_double4x4(columns: (SIMD4(unit, 0, 0, 0), SIMD4(0, 0, unit, 0), SIMD4(0, -unit, 0, 0), SIMD4(0, 0, 0, 1)))
          }

          let op = UsdGeom.Xformable(root).addXformOp(type: .transform, precision: .double)
          _ = op.Set(SceneEdit.matrix(Kraken.Layout.array(m)), time)
        }

        if let attribute = root.attribute(named: voxelName) ?? root.createAttribute(name: voxelName, typeName: .float, custom: true)
        {
          attribute.set(payload.voxel)
        }

        // the volume lives in the caches folder now, found by what the surface hashes to
        if root.attribute(named: volumeName) != nil { _ = root.RemoveProperty(volumeName) }

        let base = payload.base
        if let attribute = root.attribute(named: baseName) ?? root.createAttribute(name: baseName, typeName: .intArray, custom: true)
        {
          _ = attribute.Set(SceneEdit.intArray([Int32(base.x), Int32(base.y), Int32(base.z), Int32(base.w)]), time)
        }

        if let reference = payload.reference,
           let attribute = root.attribute(named: referenceName) ?? root.createAttribute(name: referenceName, typeName: .asset, custom: true)
        {
          attribute.set(Pixar.SdfAssetPath(asset(reference, scene: payload.scene)))
        }

        authorSurface(stage, surface, payload, replacing: onMesh, time: time, any: any)

        // a mesh keeps the material it already wears, the paint only gets one of its own when it has none
        let own = stage.GetPrimAtPath(path.AppendChild(Tf.Token("Material"))).isValid
        let worn = Pixar.UsdShadeMaterialBindingAPI(root).ComputeBoundMaterial(.allPurpose, nil, true).GetPrim().isValid
        if !onMesh || own || !worn { authorMaterial(stage, root: path, surface: surface, gloss: payload.gloss) }

        let strokes = path.AppendChild(strokesName)
        if let splats = payload.splats, !splats.positions.isEmpty
        {
          let field = UsdVol.ParticleField3DGaussianSplat.define(stage, path: strokes)
          field.set(positions: splats.positions, orientations: splats.orientations, scales: splats.scales,
                    opacities: splats.opacities, colors: splats.colors, time: time)
        }
        else if stage.GetPrimAtPath(strokes).isValid
        {
          _ = stage.RemovePrim(strokes)
        }

        authorPencil(stage, path.AppendChild(pencilName), payload.pencil, time: time, any: any)
        return path.string
      }

      guard let scene = payload.scene, let layer = layer(stage, scene: scene, name: String(path.string.split(separator: "/").last ?? "Sculpt")) else
      {
        if onMesh { gatherSurface(stage, path, into: Kraken.Authoring.department(stage)) }
        return Kraken.Authoring.inDepartment(stage, for: path, write)
      }

      // a mesh stays defined and placed where it was, only its surface moves into the sculpt's layer
      if onMesh { gatherSurface(stage, path, into: layer) } else { gather(stage, path, into: layer) }
      let previous = Kraken.Authoring.editTarget(stage)
      Pixar.HdAkariJournalWatch(layer)
      stage.SetEditTarget(Kraken.Authoring.target(layer))
      defer { stage.SetEditTarget(previous) }
      return write()
    }

    private nonisolated static func authorSurface(_ stage: UsdStage, _ path: Pixar.SdfPath, _ payload: Payload, replacing: Bool,
                                                  time: Pixar.UsdTimeCode, any: Pixar.VtValue)
    {
      let mesh = UsdGeom.Mesh.define(stage, path: path)
      if replacing { forget(mesh.GetPrim()) }
      let points = SceneEdit.vec3fArray(payload.points)
      _ = mesh.GetPointsAttr().Set(points, time)
      _ = mesh.GetFaceVertexCountsAttr().Set(SceneEdit.intArray([Int32](repeating: 3, count: payload.indices.count / 3)), time)
      _ = mesh.GetFaceVertexIndicesAttr().Set(SceneEdit.intArray(payload.indices), time)
      _ = mesh.GetNormalsAttr().Set(SceneEdit.vec3fArray(payload.normals), time)
      var surface = mesh
      _ = surface.SetNormalsInterpolation(.vertex)
      _ = mesh.CreateSubdivisionSchemeAttr(any, false).Set(Tf.Token.none_, time)

      var extent = Pixar.VtVec3fArray()
      if Pixar.UsdGeomPointBased.ComputeExtent(points, &extent) { _ = mesh.GetExtentAttr().Set(extent, time) }

      let primvars = Pixar.UsdGeomPrimvarsAPI(mesh.GetPrim())
      _ = primvars.CreatePrimvar(Tf.Token("displayColor"), .color3fArray, .vertex, -1).Set(SceneEdit.vec3fArray(payload.colors), time)
      _ = primvars.CreatePrimvar(glossName, .floatArray, .vertex, -1).Set(SceneEdit.floatArray(payload.gloss), time)
      if !payload.mask.isEmpty
      {
        _ = primvars.CreatePrimvar(maskName, .floatArray, .vertex, -1).Set(SceneEdit.floatArray(payload.mask), time)
      }
      else
      {
        var prim = mesh.GetPrim()
        if prim.attribute(named: Tf.Token("primvars:akari:mask")) != nil { _ = prim.RemoveProperty(Tf.Token("primvars:akari:mask")) }
      }
    }

    /// what a mesh held about its old faces, blocked so none of it is read against the sculpted surface
    private nonisolated static func forget(_ prim: UsdPrim)
    {
      let primvars = Pixar.UsdGeomPrimvarsAPI(prim)
      for primvar in primvars.GetPrimvars() where primvar.GetInterpolation() != .constant
      {
        #if compiler(>=6.4) && canImport(Usd)
          primvar.GetAttrConsuming().Block()
        #else
          primvar.GetAttr().Block()
        #endif

        let indices = primvar.GetIndicesAttr()
        if indices.isValid { indices.Block() }
      }

      let stale = ["creaseIndices", "creaseLengths", "creaseSharpnesses", "cornerIndices", "cornerSharpnesses", "holeIndices"]
      for name in stale + ["akari:sharpEdges"]
      {
        if let attribute = prim.attribute(named: Tf.Token(name)) { attribute.Block() }
      }

      // face sets name faces that are gone
      var children = prim.GetAllChildren()
      while let child = children.next()
      {
        guard child.isA(.geomSubset), let indices = child.attribute(named: Tf.Token("indices")) else { continue }
        indices.Block()
      }
    }

    /// a pxrsurface reading the paint through a primvar, with its preview surface beside it, made once and kept in the sculpt
    private nonisolated static func authorMaterial(_ stage: UsdStage, root: Pixar.SdfPath, surface: Pixar.SdfPath, gloss: [Float])
    {
      let path = root.AppendChild(Tf.Token("Material"))
      let roughness = 1 - 0.8 * (gloss.isEmpty ? 0.15 : gloss.reduce(0, +) / Float(gloss.count))

      func reads(_ prim: UsdPrim, _ name: String)
      {
        let varname = Tf.Token("inputs:varname")
        if let attribute = prim.attribute(named: varname) ?? prim.createAttribute(name: varname, typeName: .string, custom: false)
        {
          attribute.set(name)
        }
      }

      if !stage.GetPrimAtPath(path).isValid
      {
        let material = UsdShade.Material.define(stage, path: path)

        var shader = UsdShade.Shader.define(stage, path: path.AppendChild(Tf.Token("PxrSurface")))
        _ = shader.createIdAttr(.pxrSurface)
        _ = shader.CreateInput(Kraken.ShaderInput.diffuseGain.token, .float).set(Float(1))
        _ = shader.CreateInput(Kraken.ShaderInput.specularFaceColor.token, .color3f).set(Pixar.GfVec3f(0.04, 0.04, 0.04))
        _ = shader.CreateInput(Kraken.ShaderInput.specularEdgeColor.token, .color3f).set(Pixar.GfVec3f(1, 1, 1))
        _ = shader.CreateInput(Kraken.ShaderInput.presence.token, .float).set(Float(1))
        let diffuse = shader.CreateInput(Kraken.ShaderInput.diffuseColor.token, .color3f)
        _ = diffuse.set(Pixar.GfVec3f(1, 1, 1))

        var primvar = UsdShade.Shader.define(stage, path: path.AppendChild(Tf.Token("Paint")))
        _ = primvar.createIdAttr(.pxrPrimvar)
        reads(primvar.GetPrim(), "displayColor")
        let typeName = Tf.Token("inputs:type")
        if let attribute = primvar.GetPrim().createAttribute(name: typeName, typeName: .string, custom: false) { attribute.set("color") }
        _ = diffuse.ConnectToSource(primvar.CreateOutput(Tf.Token("resultRGB"), .color3f))

        _ = material.createSurfaceOutput(renderContext: .riRenderContext).ConnectToSource(shader.CreateOutput(Tf.Token("out"), .token))

        var preview = UsdShade.Shader.define(stage, path: path.AppendChild(Tf.Token("PreviewSurface")))
        _ = preview.createIdAttr(.usdPreviewSurface)
        var reader = UsdShade.Shader.define(stage, path: path.AppendChild(Tf.Token("PaintReader")))
        _ = reader.createIdAttr(.usdPrimvarReaderFloat3)
        reads(reader.GetPrim(), "displayColor")
        let previewColor = preview.CreateInput(Kraken.ShaderInput.diffuseColor.token, .color3f)
        _ = previewColor.ConnectToSource(reader.CreateOutput(Tf.Token("result"), .float3))
        _ = material.createSurfaceOutput().ConnectToSource(preview.CreateOutput(.surface, .token))

        _ = UsdShade.MaterialBindingAPI.apply(stage.GetPrimAtPath(surface)).bind(material)
      }

      // gloss painted on the surface sets how rough the material reads overall
      let shader = stage.GetPrimAtPath(path.AppendChild(Tf.Token("PxrSurface")))
      guard shader.isValid else { return }
      var surface = Pixar.UsdShadeShader(shader)
      _ = surface.CreateInput(Kraken.ShaderInput.specularRoughness.token, .float).set(roughness)
      SceneEdit.syncPreview(stage, shader)
    }

    private nonisolated static func authorPencil(_ stage: UsdStage, _ path: Pixar.SdfPath, _ strokes: [SculptPencilStroke],
                                                 time: Pixar.UsdTimeCode, any: Pixar.VtValue)
    {
      if stage.GetPrimAtPath(path).isValid { _ = stage.RemovePrim(path) }
      guard !strokes.isEmpty else { return }

      _ = stage.DefinePrim(path, .scope)
      for (i, line) in strokes.enumerated() where line.points.count > 1
      {
        let curves = UsdGeom.BasisCurves.define(stage, path: path.AppendChild(Tf.Token(String(format: "Stroke_%03d", i))))
        _ = curves.CreateTypeAttr(any, false).Set(Tf.Token.linear, time)
        _ = curves.GetPointsAttr().Set(SceneEdit.vec3fArray(line.points), time)
        _ = curves.CreateCurveVertexCountsAttr(any, false).Set(SceneEdit.intArray([Int32(line.points.count)]), time)
        _ = curves.CreateWidthsAttr(any, false).Set(SceneEdit.floatArray(line.widths), time)
        var shaped = curves
        _ = shaped.SetWidthsInterpolation(.vertex)

        let primvars = Pixar.UsdGeomPrimvarsAPI(curves.GetPrim())
        _ = primvars.CreatePrimvar(Tf.Token("displayColor"), .color3fArray, .constant, -1)
          .Set(SceneEdit.vec3fArray([linear(line.color)]), time)
        _ = primvars.CreatePrimvar(Tf.Token("displayOpacity"), .floatArray, .constant, -1)
          .Set(SceneEdit.floatArray([line.opacity]), time)
      }
    }

    // MARK: reading

    /// what a scene keeps of a sculpt, voxel size, base paint, painted surface and pencil strokes
    struct Found: Sendable
    {
      var path: String
      var voxel: Float
      var base: SIMD4<UInt8>?
      var volume: URL?
      var reference: URL?
      var surface: SceneEdit.Mesh
      /// normals, linear paint, gloss and mask one per point as plain floats, empty when the surface has none
      var normals: [Float] = []
      var colors: [Float] = []
      var gloss: [Float] = []
      var mask: [Float] = []
      var pencil: [SculptPencilStroke]

      /// what the surface hashes to, matching the key it was cached under when written
      var key: String
      {
        SculptCache.key(points: surface.points, indices: surface.indices, colors: colors, gloss: gloss, mask: mask)
      }

      /// the surface ready to rebuild a volume from, nil unless it is all triangles
      var triangles: SculptSurface?
      {
        guard surface.valid, !surface.counts.isEmpty, surface.counts.allSatisfy({ $0 == 3 }) else { return nil }

        let count = surface.points.count / 3
        func vectors(_ flat: [Float]) -> [SIMD3<Float>]
        {
          stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
        }

        var out = SculptSurface()
        out.points = vectors(surface.points)
        out.triangles = surface.indices
        if normals.count == count * 3 { out.normals = vectors(normals) }
        if colors.count == count * 3
        {
          let glossy = gloss.count == count
          out.colors = (0 ..< count).map
          { i in
            let c = SculptUSD.display(SIMD3(colors[i * 3], colors[i * 3 + 1], colors[i * 3 + 2]))
            let rgb = SIMD3<UInt8>(simd_clamp(c * 255, SIMD3(repeating: 0), SIMD3(repeating: 255)).rounded(.toNearestOrAwayFromZero))
            let g = glossy ? UInt8(simd_clamp(gloss[i] * 255, 0, 255).rounded()) : (base?.w ?? 40)
            return SIMD4(rgb, g)
          }
        }
        if mask.count == count { out.mask = mask.map { UInt8(simd_clamp($0 * 255, 0, 255).rounded()) } }
        return out
      }
    }

    /// whether the prim at path, or the one above it, is a sculpt
    nonisolated static func sculptPath(_ stage: UsdStage, _ path: String) -> String?
    {
      var prim = stage.GetPrimAtPath(Sdf.Path(path))
      for _ in 0 ..< 2
      {
        guard prim.isValid else { return nil }
        if prim.attribute(named: voxelName) != nil { return prim.GetPath().string }
        prim = prim.GetParent()
      }

      return nil
    }

    /// what sculpting opens with nothing selected, the default prim if it has geometry, else the biggest surface under it or on the stage
    nonisolated static func defaultTarget(_ stage: UsdStage, _ time: Double) -> String?
    {
      let t = Pixar.UsdTimeCode(time)
      var boxes = SceneEdit.bboxCache(t)

      func sculptable(_ prim: UsdPrim) -> Bool
      {
        prim.attribute(named: voxelName) != nil || prim.isA(.mesh)
          || SceneEdit.implicitMesh(prim, Pixar.UsdTimeCode.Default().GetValue()) != nil
      }

      func size(_ prim: UsdPrim) -> Double
      {
        let range = boxes.ComputeWorldBound(prim).ComputeAlignedRange()
        guard !range.IsEmpty() else { return 0 }
        #if compiler(>=6.4) && canImport(Usd)
          let lo = SceneEdit.numbers(range.GetMinConsuming()), hi = SceneEdit.numbers(range.GetMaxConsuming())
        #else
          let lo = SceneEdit.numbers(range.GetMin()), hi = SceneEdit.numbers(range.GetMax())
        #endif
        return simd_length(SIMD3(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]))
      }

      // a sculpt prim counts once, its surface mesh below it is part of it
      func biggest(under root: UsdPrim) -> String?
      {
        var best: (path: String, size: Double)?
        func visit(_ prim: UsdPrim)
        {
          for child in SceneEdit.children(prim) where !child.IsInstanceProxy()
          {
            if SceneEdit.invisible(child, t) { continue }
            guard sculptable(child) else
            {
              visit(child)
              continue
            }

            let s = size(child)
            if best == nil || s > best!.size { best = (child.GetPath().string, s) }
          }
        }

        visit(root)
        return best?.path
      }

      let home = stage.GetDefaultPrim()
      if home.isValid
      {
        if sculptable(home) { return home.GetPath().string }
        if let inside = biggest(under: home) { return inside }
      }

      return biggest(under: stage.GetPseudoRoot())
    }

    nonisolated static func read(_ stage: UsdStage, _ path: String) -> Found?
    {
      let root = stage.GetPrimAtPath(Sdf.Path(path))
      guard root.isValid, let voxelAttribute = root.attribute(named: voxelName) else { return nil }

      let time = Pixar.UsdTimeCode.Default()
      var voxel: Float = 0
      _ = voxelAttribute.Get(&voxel, time)

      var url: URL?
      var asset = Pixar.SdfAssetPath()
      if let attribute = root.attribute(named: volumeName), attribute.Get(&asset, time)
      {
        #if compiler(>=6.4)
          let resolved = String(asset.GetResolvedPathConsuming())
          let authored = String(asset.GetAssetPathConsuming())
        #else
          let resolved = String(asset.GetResolvedPath())
          let authored = String(asset.GetAssetPath())
        #endif
        if !resolved.isEmpty { url = URL(fileURLWithPath: resolved) }
        else if authored.hasPrefix("/") { url = URL(fileURLWithPath: authored) }
      }

      var referenceURL: URL?
      var image = Pixar.SdfAssetPath()
      if let attribute = root.attribute(named: referenceName), attribute.Get(&image, time)
      {
        #if compiler(>=6.4)
          let resolved = String(image.GetResolvedPathConsuming()), authored = String(image.GetAssetPathConsuming())
        #else
          let resolved = String(image.GetResolvedPath()), authored = String(image.GetAssetPath())
        #endif
        let path = resolved.isEmpty ? authored : resolved
        if !path.isEmpty { referenceURL = URL(fileURLWithPath: path) }
      }

      let surfacePath = root.isA(.mesh) ? root.GetPath() : root.GetPath().AppendChild(surfaceName)
      let surface = SceneEdit.mesh(stage, surfacePath.string, time.GetValue())

      // what is painted on the surface, read back exactly as it was written
      var normals: [Float] = [], colors: [Float] = [], gloss: [Float] = [], mask: [Float] = []
      let surfacePrim = stage.GetPrimAtPath(surfacePath)
      if surfacePrim.isValid, surfacePrim.isA(.mesh)
      {
        func floats(_ array: Pixar.VtVec3fArray) -> [Float]
        {
          guard let xyz: UnsafePointer<Pixar.GfVec3f> = Overlay.cdata(array) else { return [] }
          return Array(UnsafeBufferPointer(start: UnsafeRawPointer(xyz).assumingMemoryBound(to: Float.self), count: array.size() * 3))
        }

        func floats(_ array: Pixar.VtFloatArray) -> [Float]
        {
          guard let values: UnsafePointer<Float> = Overlay.cdata(array) else { return [] }
          return Array(UnsafeBufferPointer(start: values, count: array.size()))
        }

        let primvars = Pixar.UsdGeomPrimvarsAPI(surfacePrim)
        var vectors = Pixar.VtVec3fArray(), values = Pixar.VtFloatArray()
        if Pixar.UsdGeomMesh(surfacePrim).GetNormalsAttr().Get(&vectors, time) { normals = floats(vectors) }
        vectors = Pixar.VtVec3fArray()
        if primvars.GetPrimvar(Tf.Token("displayColor")).Get(&vectors, time) { colors = floats(vectors) }
        if primvars.GetPrimvar(glossName).Get(&values, time) { gloss = floats(values) }
        values = Pixar.VtFloatArray()
        if primvars.GetPrimvar(maskName).Get(&values, time) { mask = floats(values) }
      }

      var base: SIMD4<UInt8>?
      var baseValues = Pixar.VtIntArray()
      if let attribute = root.attribute(named: baseName), attribute.Get(&baseValues, time), baseValues.size() == 4,
         let b: UnsafePointer<Int32> = Overlay.cdata(baseValues)
      {
        base = SIMD4(UInt8(clamping: b[0]), UInt8(clamping: b[1]), UInt8(clamping: b[2]), UInt8(clamping: b[3]))
      }

      var pencil: [SculptPencilStroke] = []
      let scope = stage.GetPrimAtPath(root.GetPath().AppendChild(pencilName))
      if scope.isValid
      {
        var children = scope.GetAllChildren()
        while let child = children.next()
        {
          guard child.isA(.basisCurves) else { continue }
          let curves = Pixar.UsdGeomBasisCurves(child)
          var points = Pixar.VtVec3fArray(), widths = Pixar.VtFloatArray()
          guard curves.GetPointsAttr().Get(&points, time) else { continue }
          _ = curves.GetWidthsAttr().Get(&widths, time)

          var line = SculptPencilStroke()
          if let xyz: UnsafePointer<Pixar.GfVec3f> = Overlay.cdata(points)
          {
            let flat = UnsafeBufferPointer(start: UnsafeRawPointer(xyz).assumingMemoryBound(to: Float.self), count: points.size() * 3)
            line.points = stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
          }

          if let w: UnsafePointer<Float> = Overlay.cdata(widths) { line.widths = Array(UnsafeBufferPointer(start: w, count: widths.size())) }
          if line.widths.count != line.points.count { line.widths = [Float](repeating: line.widths.first ?? 0.01, count: line.points.count) }

          let primvars = Pixar.UsdGeomPrimvarsAPI(child)
          var color = Pixar.VtVec3fArray()
          if primvars.GetPrimvar(Tf.Token("displayColor")).Get(&color, time), color.size() > 0,
             let c: UnsafePointer<Pixar.GfVec3f> = Overlay.cdata(color)
          {
            let rgb = UnsafeRawPointer(c).assumingMemoryBound(to: Float.self)
            line.color = display(SIMD3(rgb[0], rgb[1], rgb[2]))
          }

          var opacity = Pixar.VtFloatArray()
          if primvars.GetPrimvar(Tf.Token("displayOpacity")).Get(&opacity, time), opacity.size() > 0,
             let o: UnsafePointer<Float> = Overlay.cdata(opacity)
          {
            line.opacity = o[0]
          }

          pencil.append(line)
        }
      }

      return Found(path: root.GetPath().string, voxel: voxel, base: base, volume: url, reference: referenceURL, surface: surface,
                   normals: normals, colors: colors, gloss: gloss, mask: mask, pencil: pencil)
    }

    /// a mesh in the sculpt's space as flat triangles, from a prim anywhere in the scene
    nonisolated static func triangles(_ stage: UsdStage, mesh path: String, into sculpt: String?)
      -> (points: [SIMD3<Float>], triangles: [Int32])?
    {
      let time = Pixar.UsdTimeCode.Default()
      let mesh = SceneEdit.mesh(stage, path, time.GetValue())
      guard mesh.valid, !mesh.points.isEmpty else { return nil }

      var cache = Pixar.UsdGeomXformCache(time)
      let world = Kraken.Layout.matrix(SceneEdit.rows(cache.GetLocalToWorldTransform(stage.GetPrimAtPath(Sdf.Path(path)))))

      // into the sculpt's frame, or the frame a new sculpt would get
      var frame: simd_double4x4
      if let sculpt, case let root = stage.GetPrimAtPath(Sdf.Path(sculpt)), root.isValid
      {
        frame = Kraken.Layout.matrix(SceneEdit.rows(cache.GetLocalToWorldTransform(root)))
      }
      else
      {
        let unit = Double(SceneEdit.units(stage))
        frame = SceneEdit.yUp(stage)
          ? simd_double4x4(diagonal: SIMD4(unit, unit, unit, 1))
          : simd_double4x4(columns: (SIMD4(unit, 0, 0, 0), SIMD4(0, 0, unit, 0), SIMD4(0, -unit, 0, 0), SIMD4(0, 0, 0, 1)))
      }

      let toSculpt = frame.inverse * world
      var points: [SIMD3<Float>] = []
      points.reserveCapacity(mesh.points.count / 3)
      for i in stride(from: 0, to: mesh.points.count - 2, by: 3)
      {
        let p = toSculpt * SIMD4(Double(mesh.points[i]), Double(mesh.points[i + 1]), Double(mesh.points[i + 2]), 1)
        points.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
      }

      var tris: [Int32] = []
      var at = 0
      for count in mesh.counts.map(Int.init)
      {
        guard count >= 3, at + count <= mesh.indices.count else
        {
          at += max(count, 0)
          continue
        }

        for k in 1 ..< count - 1 { tris += [mesh.indices[at], mesh.indices[at + k], mesh.indices[at + k + 1]] }
        at += count
      }

      return (points, tris)
    }

    /// a plain mesh as clay in its own space, triangles split for voxelizing and one flat color, nil when it isn't a mesh
    nonisolated static func clay(_ stage: UsdStage, mesh path: String)
      -> (surface: SculptSurface, base: SIMD4<UInt8>?, counts: (vertices: Int, faces: Int))?
    {
      guard let mesh = triangles(stage, mesh: path, into: path), mesh.triangles.count >= 3 else { return nil }
      let faces = SceneEdit.mesh(stage, path, Pixar.UsdTimeCode.Default().GetValue()).counts.count

      var surface = SculptSurface()
      surface.points = mesh.points
      surface.triangles = mesh.triangles

      var base: SIMD4<UInt8>?
      let primvar = Pixar.UsdGeomPrimvarsAPI(stage.GetPrimAtPath(Sdf.Path(path))).GetPrimvar(Tf.Token("displayColor"))
      var colors = Pixar.VtVec3fArray()
      if primvar.GetInterpolation() == .constant, primvar.Get(&colors, Pixar.UsdTimeCode.Default()), colors.size() > 0,
         let c: UnsafePointer<Pixar.GfVec3f> = Overlay.cdata(colors)
      {
        let rgb = UnsafeRawPointer(c).assumingMemoryBound(to: Float.self)
        let shown = simd_clamp(display(SIMD3(rgb[0], rgb[1], rgb[2])) * 255, SIMD3(repeating: 0), SIMD3(repeating: 255))
        base = SIMD4(SIMD3<UInt8>(shown.rounded(.toNearestOrAwayFromZero)), 40)
      }

      return (surface, base, (mesh.points.count, faces))
    }

    /// how big a sculpt's space is, half its widest side, so a detail level means the same on a pebble and a house
    nonisolated static func unit(of points: [SIMD3<Float>]) -> Float
    {
      guard var lo = points.first else { return 1 }
      var hi = lo
      for p in points
      {
        lo = simd_min(lo, p)
        hi = simd_max(hi, p)
      }

      let widest = simd_reduce_max(hi - lo)
      return widest > 1e-6 ? widest / 2 : 1
    }
  }
}

extension Kraken.SculptSurface
{
  /// the surface with every triangle longer than `longest` split until none is, so voxelizing never searches a huge box
  func split(longest: Float) -> Kraken.SculptSurface
  {
    guard longest > 0 else { return self }

    var out = Kraken.SculptSurface()
    out.points = points
    let hasNormals = normals.count == points.count, hasColors = colors.count == points.count, hasMask = mask.count == points.count
    if hasNormals { out.normals = normals }
    if hasColors { out.colors = colors }
    if hasMask { out.mask = mask }
    var middles: [SIMD2<Int32>: Int32] = [:]

    // a new point halfway along an edge, its paint, normal and mask halfway between the ends too
    func middle(_ a: Int32, _ b: Int32) -> Int32
    {
      let key = SIMD2(min(a, b), max(a, b))
      if let found = middles[key] { return found }
      let i = Int(a), j = Int(b)
      out.points.append((out.points[i] + out.points[j]) * 0.5)
      if hasNormals
      {
        let n = out.normals[i] + out.normals[j]
        out.normals.append(simd_length_squared(n) > 1e-12 ? simd_normalize(n) : out.normals[i])
      }
      if hasColors
      {
        let sum = SIMD4<UInt16>(truncatingIfNeeded: out.colors[i]) &+ SIMD4<UInt16>(truncatingIfNeeded: out.colors[j]) &+ 1
        out.colors.append(SIMD4<UInt8>(truncatingIfNeeded: sum / 2))
      }
      if hasMask { out.mask.append(UInt8((UInt16(out.mask[i]) + UInt16(out.mask[j]) + 1) / 2)) }
      let index = Int32(out.points.count - 1)
      middles[key] = index
      return index
    }

    var pending: [SIMD3<Int32>] = stride(from: 0, to: triangles.count - 2, by: 3).map
    {
      SIMD3(triangles[$0], triangles[$0 + 1], triangles[$0 + 2])
    }

    // only the longest edge is halved each time, so a long thin triangle becomes a short row rather than thousands
    while let t = pending.popLast()
    {
      let ab = simd_distance(out.points[Int(t.x)], out.points[Int(t.y)])
      let bc = simd_distance(out.points[Int(t.y)], out.points[Int(t.z)])
      let ca = simd_distance(out.points[Int(t.z)], out.points[Int(t.x)])
      guard max(ab, max(bc, ca)) > longest else
      {
        out.triangles += [t.x, t.y, t.z]
        continue
      }

      // turned so the longest edge runs from the first corner to the second, the winding kept
      let r = ab >= bc && ab >= ca ? t : bc >= ca ? SIMD3(t.y, t.z, t.x) : SIMD3(t.z, t.x, t.y)
      let m = middle(r.x, r.y)
      pending += [SIMD3(r.x, m, r.z), SIMD3(m, r.y, r.z)]
    }

    return out
  }
}

// MARK: volume files

extension Kraken.SculptVolume
{
  private static let magic: UInt32 = 0x4C56_4B41

  /// the bricks as plain arrays, safe to encode on another thread while strokes go on
  struct Frozen: Sendable
  {
    var voxel: Float
    var base: SIMD4<UInt8>
    var keys: [SIMD3<Int32>]
    var distances: [[Float]]
    var colors: [[SIMD4<UInt8>]]
    var masks: [[UInt8]]
    var inside: [SIMD3<Int32>]
  }

  func frozen() -> Frozen
  {
    let keys = Array(bricks.keys)
    return Frozen(voxel: voxel, base: base, keys: keys,
                  distances: keys.map { bricks[$0]!.distance },
                  colors: keys.map { bricks[$0]!.color },
                  masks: keys.map { bricks[$0]!.mask },
                  inside: Array(inside))
  }

  /// the volume as a compressed file, distances as halves
  static func encode(_ frozen: Frozen) -> Data?
  {
    var data = Data()
    func put<T>(_ value: T)
    {
      withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    put(magic)
    put(UInt32(1))
    put(frozen.voxel)
    put(frozen.base)
    put(UInt32(frozen.keys.count))
    put(UInt32(frozen.inside.count))
    for k in frozen.inside { put(k.x); put(k.y); put(k.z) }

    for (i, k) in frozen.keys.enumerated()
    {
      put(k.x)
      put(k.y)
      put(k.z)
      let halves = frozen.distances[i].map { Float16($0 / frozen.voxel) }
      halves.withUnsafeBytes { data.append(contentsOf: $0) }
      frozen.colors[i].withUnsafeBytes { data.append(contentsOf: $0) }
      frozen.masks[i].withUnsafeBytes { data.append(contentsOf: $0) }
    }

    return try? (data as NSData).compressed(using: .lzfse) as Data
  }

  static func decode(_ compressed: Data) -> Kraken.SculptVolume?
  {
    guard let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }

    var at = 0
    func get<T>(_: T.Type) -> T?
    {
      let size = MemoryLayout<T>.size
      guard at + size <= data.count else { return nil }
      defer { at += size }
      return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: T.self) }
    }

    func bytes(_ count: Int) -> Data?
    {
      guard at + count <= data.count else { return nil }
      defer { at += count }
      return data.subdata(in: at ..< at + count)
    }

    guard get(UInt32.self) == magic, get(UInt32.self) == 1, let voxel = get(Float.self), let base = get(SIMD4<UInt8>.self),
          let denseCount = get(UInt32.self), let insideCount = get(UInt32.self)
    else { return nil }

    let volume = Kraken.SculptVolume(voxel: voxel)
    volume.base = base
    for _ in 0 ..< insideCount
    {
      guard let x = get(Int32.self), let y = get(Int32.self), let z = get(Int32.self) else { return nil }
      volume.inside.insert(SIMD3(x, y, z))
    }

    let count = Kraken.SculptBrick.count
    for _ in 0 ..< denseCount
    {
      guard let x = get(Int32.self), let y = get(Int32.self), let z = get(Int32.self),
            let halves = bytes(count * 2), let colors = bytes(count * 4), let masks = bytes(count)
      else { return nil }

      let brick = Kraken.SculptBrick(fill: 0, color: base)
      halves.withUnsafeBytes
      { raw in
        let h = raw.bindMemory(to: Float16.self)
        for i in 0 ..< count { brick.distance[i] = Float(h[i]) * voxel }
      }

      colors.withUnsafeBytes { raw in brick.color = Array(raw.bindMemory(to: SIMD4<UInt8>.self)) }
      brick.mask = Array(masks)
      volume.bricks[SIMD3(x, y, z)] = brick
    }

    return volume
  }

  /// a volume from a voxelized surface, distances to the surface planes near it and inside marked by flooding from outside
  static func fromSurface(_ voxels: [VoxSplat.SurfaceVoxel], voxel: Float) -> Kraken.SculptVolume
  {
    let volume = Kraken.SculptVolume(voxel: voxel)
    guard !voxels.isEmpty else { return volume }

    let band = volume.band
    let reach: Int32 = 3
    var nearest: [SIMD3<Int32>: Float] = [:]
    nearest.reserveCapacity(voxels.count * 20)

    // every grid point near a surface voxel takes the plane distance of the closest one
    for sample in voxels
    {
      let n = simd_length(sample.normal) > 1e-6 ? simd_normalize(sample.normal) : SIMD3<Float>(0, 1, 0)
      let center = SIMD3<Int32>((sample.point / voxel).rounded(.toNearestOrAwayFromZero))
      for z in -reach ... reach
      {
        for y in -reach ... reach
        {
          for x in -reach ... reach
          {
            let g = center &+ SIMD3(x, y, z)
            let p = SIMD3<Float>(g) * voxel
            let offset = p - sample.point
            let euclid = simd_length(offset)
            guard euclid <= Float(reach) * voxel else { continue }

            let signed = simd_dot(offset, n)
            let d = (signed < 0 ? -1 : 1) * min(euclid, max(abs(signed), euclid * 0.5))
            if let old = nearest[g], abs(old) <= abs(d) { continue }
            nearest[g] = d
          }
        }
      }
    }

    var known: [SIMD3<Int32>: [Bool]] = [:]
    for (g, d) in nearest
    {
      let k = key(g)
      let brick = volume.densify(k)
      let l = local(g)
      let i = Kraken.SculptBrick.index(l.x, l.y, l.z)
      brick.distance[i] = max(min(d, band), -band)
      known[k, default: [Bool](repeating: false, count: Kraken.SculptBrick.count)][i] = true
    }

    settle(volume, known: known)
    return volume
  }
}

// MARK: layout

extension Kraken.Layout
{
  /// writes the sculpt into the scene off the main thread unless `now` is set for a save, its volume going to the cache
  func writeSculpt(_ sculpt: Kraken.Sculpt, now: Bool = false)
  {
    let chunks = Array(sculpt.chunks.values)
    let pencil = sculpt.pencil
    let frozen = sculpt.volume.frozen()
    let path = sculpt.primPath
    let scene = sceneURL
    let look = sculpt.writesSplats ? sculpt.splatLook : nil
    let reference = sculpt.reference?.url.path
    let owner = "\(UInt(bitPattern: ObjectIdentifier(sculpt).hashValue))"
    let hydra = hydra
    edited = true

    let work: @Sendable () -> Void =
    {
      var built = Kraken.SculptUSD.payload(chunks: chunks, pencil: pencil, frozen: frozen, path: path, scene: scene, splatLook: look)
      built.reference = reference
      if let data = Kraken.SculptVolume.encode(frozen) { Kraken.SculptCache.store(data, key: built.key, owner: owner, claim: now) }
      let payload = built
      let counts = (vertices: payload.points.count, faces: payload.indices.count / 3)
      hydra.performOnFrameQueue
      {
        let written = Kraken.SculptUSD.author(hydra.stage, payload)
        DispatchQueue.main.async
        { [weak self, weak sculpt] in
          guard let self, let sculpt else { return }
          self.primsChanged()
          guard sculpt.primPath == path else { return }
          sculpt.counts = counts
          guard written != path else { return }
          sculpt.primPath = written
        }
      }
    }

    if now { work() } else { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
  }

  /// opens the sculpt at `path` or the one the selection belongs to, turning a plain mesh into clay in place
  func loadSculpt(_ path: String)
  {
    let sculpt = sculpt
    let detail = sculpt.detail
    let name = String(path.split(separator: "/").last ?? "")
    sculpt.opening = path

    onStage
    { [weak self] stage in
      let upright = Kraken.Layout.sculptUpright(stage)
      guard let root = Kraken.SculptUSD.sculptPath(stage, path), let found = Kraken.SculptUSD.read(stage, root) else
      {
        // a cube, sphere or other implicit shape becomes the mesh it draws as first, the way edit mode takes it
        if let prim = Kraken.SceneEdit.prim(stage, path), !prim.IsInstanceProxy(),
           Kraken.SceneEdit.implicitMesh(prim, Pixar.UsdTimeCode.Default().GetValue()) != nil
        {
          DispatchQueue.main.async
          {
            guard let self, sculpt.opening == path else { return }
            self.checkpoint()
            self.onStage
            { stage in
              let made = Kraken.SceneEdit.makeMesh(stage, path, Pixar.UsdTimeCode.Default().GetValue())
              DispatchQueue.main.async
              {
                guard sculpt.opening == path else { return }
                sculpt.opening = nil
                if made { self.loadSculpt(path) } else { sculpt.status = "\(name) is not a mesh" }
              }
            }
          }
          return
        }

        let frame = Kraken.Layout.sculptFrame(stage, path, upright: upright)
        guard let clay = Kraken.SculptUSD.clay(stage, mesh: path) else
        {
          DispatchQueue.main.async
          {
            guard sculpt.opening == path else { return }
            sculpt.opening = nil
            sculpt.status = "\(name) is not a mesh"
          }
          return
        }

        DispatchQueue.main.async { sculpt.status = "Turning \(name) into clay…" }
        DispatchQueue.global(qos: .userInitiated).async
        {
          let unit = Kraken.SculptUSD.unit(of: clay.surface.points)
          let voxel = detail.voxel * unit
          let volume = Kraken.SculptVolume.fromMesh(clay.surface.split(longest: voxel * 12), voxel: voxel,
                                                    base: clay.base ?? Kraken.SculptVolume(voxel: voxel).base)
          let meshed = Kraken.Sculpt.meshAll(volume)
          DispatchQueue.main.async
          {
            guard sculpt.opening == path else { return }
            sculpt.opening = nil
            guard !volume.isEmpty else
            {
              sculpt.status = "\(name) has no surface to sculpt"
              return
            }

            sculpt.adopt(volume, pencil: [], path: path, unit: unit, frame: frame, meshed: meshed)
            sculpt.counts = clay.counts
            sculpt.layout?.refreshSculptScene(takesCamera: false)
            sculpt.status = "Sculpting \(name)"
          }
        }
        return
      }

      let frame = Kraken.Layout.sculptFrame(stage, found.path, upright: upright)

      // a sculpt kept on a mesh sizes its detail to that mesh, one of its own is in meters
      let flat = found.surface.points
      let unit = stage.GetPrimAtPath(Sdf.Path(found.path)).isA(.mesh)
        ? Kraken.SculptUSD.unit(of: stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) })
        : 1

      // the cached volume when its surface is unchanged, else the file an older scene pointed at
      let key = found.key
      var volume = Kraken.SculptCache.load(key) ?? found.volume.flatMap { try? Data(contentsOf: $0) }.flatMap { Kraken.SculptVolume.decode($0) }

      // without either it is rebuilt from the surface, which holds the whole sculpt, and cached for next time
      if volume == nil, let surface = found.triangles
      {
        let voxel = found.voxel > 0 ? found.voxel : Kraken.SculptDetail.standard.voxel

        // the scene keeps flat ground as a few large triangles, split fine again so the rebuild stays local
        let rebuilt = Kraken.SculptVolume.fromMesh(surface.split(longest: voxel * 12), voxel: voxel,
                                                   base: found.base ?? Kraken.SculptVolume(voxel: voxel).base)
        if !rebuilt.isEmpty
        {
          volume = rebuilt
          if let data = Kraken.SculptVolume.encode(rebuilt.frozen()) { Kraken.SculptCache.store(data, key: key, owner: found.path, claim: true) }
        }
      }

      // a surface that is not the sculpt's own triangles is voxelized the plain way
      if volume == nil, found.surface.valid
      {
        let flat = found.surface.points
        let points = stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
        let voxel = found.voxel > 0 ? found.voxel : Kraken.SculptDetail.standard.voxel
        volume = Kraken.SculptVolume.fromSurface(VoxSplat.voxelize(points: points, triangles: found.surface.indices, voxelSize: voxel),
                                                 voxel: voxel)
      }

      guard let volume else
      {
        DispatchQueue.main.async { if sculpt.opening == path { sculpt.opening = nil } }
        return
      }

      // the meshing leaves the stage queue free, the scene keeps drawing while the sculpt is meshed
      DispatchQueue.global(qos: .userInitiated).async
      {
        let meshed = Kraken.Sculpt.meshAll(volume)
        DispatchQueue.main.async
        {
          guard sculpt.opening == path else { return }
          sculpt.opening = nil
          sculpt.adopt(volume, pencil: found.pencil, path: found.path, unit: unit, frame: frame, meshed: meshed)
          sculpt.counts = (found.surface.points.count / 3, found.surface.counts.count)
          sculpt.layout?.refreshSculptScene(takesCamera: false)
          if let reference = found.reference, sculpt.reference?.url != reference { sculpt.loadReference(reference) }
          sculpt.status = "Opened \(found.path)"
        }
      }
    }
  }
}
