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
import AkariHydra
import AkariRender
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published

extension Kraken
{
  /// The Material tab's own Akari viewport: the active material, referenced live out of the scene's
  /// layers, on one of the preview shapes. Its engine renders on the scene's device between the scene's frames.
  @MainActor
  final class MaterialPreview: ObservableObject
  {
    @Published private(set) var hydra: Hydra.RenderEngine?
    @Published private(set) var shape = PreviewShape.sphere

    private let host: Hydra.RenderEngine
    private let engine: Akari.RenderEngine
    private var driver: Akari.FrameDriver?
    private var material = ""

    nonisolated static let root = "/Preview"
    nonisolated static let materialPath = "/Preview/Material"
    nonisolated static let shapePath = "/Preview/Shape"

    init(host: Hydra.RenderEngine)
    {
      self.host = host
      var settings = RenderSettings(quality: .high)
      settings.features.subtract([.dynamicResolution, .lightProbes, .volumetrics, .hardwareRayTracing])
      settings.upscaler = .taaResolve
      nonisolated(unsafe) let engine = Akari.RenderEngine(settings: settings)
      self.engine = engine
      let shape = shape
      host.performOnFrameQueue
      { [weak self] in
        let stage = Self.makeStage(shape)
        engine.labfx.setStageUpAxis(isZUp: false)
        engine.labfx.setStageMetersPerUnit(1)
        engine.adoptColorManagement(of: stage)
        let hydra = withAkariRenderer(engine)
        {
          Hydra.RenderEngine(stage: stage, rendererPluginId: Tf.Token(Akari.rendererPluginId), sharing: host)
        }

        Self.frame(hydra)

        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          let driver = Akari.FrameDriver(hydra: hydra, akari: engine)
          driver.outlinesSelection = false
          self.driver = driver
          self.hydra = hydra
          show(material: material)
        }
      }
    }

    /// Previews the material at `path` in the scene, none when empty.
    func show(material path: String)
    {
      material = path
      guard let hydra else { return }
      let host = host
      hydra.performOnFrameQueue
      {
        let source = Authoring.identifier(host.stage.getRootLayer())
        var references = hydra.stage.GetPrimAtPath(Sdf.Path(Self.materialPath)).getReferences()
        _ = references.ClearReferences()
        if !path.isEmpty { references.addReference(assetPath: source, primPath: Sdf.Path(path)) }
      }
    }

    func show(_ next: PreviewShape)
    {
      guard next != shape else { return }
      shape = next
      guard let hydra else { return }
      hydra.performOnFrameQueue
      {
        Self.author(next, on: hydra.stage)
        Self.frame(hydra)
      }
    }

    // MARK: stage

    /// Looks at the shape a little from above, the backdrop filling the view behind it.
    private nonisolated static func frame(_ hydra: Hydra.RenderEngine)
    {
      hydra.viewCamera.rotation = Pixar.GfVec3d(-12, 0, 0)
      hydra.viewCamera.focus = Pixar.GfVec3d(0, -0.2, 0)
      hydra.viewCamera.distance = 7.5
      hydra.viewCamera.gfCamera.focalLength = 35
      hydra.viewCamera.standardFocalLength = 35
    }

    private nonisolated static func makeStage(_ shape: PreviewShape) -> UsdStage
    {
      let stage = UsdStage.createInMemory("materialPreview.usda")
      _ = UsdGeom.setUpAxis(for: stage, to: .y)
      _ = UsdGeom.setMetersPerUnit(for: stage, to: 1)
      _ = UsdGeom.Xform.define(stage, path: Sdf.Path(root))
      _ = stage.DefinePrim(Sdf.Path(materialPath), .material)
      let any = Pixar.VtValue()
      let sun = UsdLux.DistantLight.define(stage, path: Sdf.Path(root).AppendChild(Tf.Token("Key")))
      // the brightness of its two degree disk, 3 delivered.
      sun.CreateIntensityAttr(any, false).set(Float(3135))
      sun.CreateAngleAttr(any, false).set(Float(2))
      _ = UsdGeom.Xformable(sun.GetPrim()).addXformOp(type: .rotateXYZ, precision: .float)
        .Set(Pixar.GfVec3f(-40, -35, 0), Pixar.UsdTimeCode.Default())
      let backdrop = Sdf.Path(root).AppendChild(Tf.Token("Backdrop"))
      _ = UsdGeom.Xform.define(stage, path: backdrop)
      let squares = PreviewShape.backdrop()
      for (name, mesh, albedo) in [("Light", squares.light, Float(0.6)), ("Dark", squares.dark, Float(0.2))]
      {
        let path = backdrop.AppendChild(Tf.Token(name))
        let prim = define(mesh, at: path, on: stage)
        _ = UsdShade.MaterialBindingAPI.apply(prim).bind(matte(albedo, at: path.AppendChild(Tf.Token("Material")), on: stage))
      }

      author(shape, on: stage)
      return stage
    }

    /// A rough, plain colored surface for the backdrop.
    private nonisolated static func matte(_ albedo: Float, at path: Pixar.SdfPath, on stage: UsdStage) -> UsdShade.Material
    {
      let material = UsdShade.Material.define(stage, path: path)
      var shader = UsdShade.Shader.define(stage, path: path.AppendChild(Tf.Token("PxrSurface")))
      shader.createIdAttr(.pxrSurface)
      shader.createInput(for: .diffuseColor, type: .color3f).set(Pixar.GfVec3f(albedo, albedo, albedo))
      shader.createInput(for: .specularFaceColor, type: .color3f).set(Pixar.GfVec3f(0, 0, 0))
      shader.createInput(for: .specularRoughness, type: .float).set(Float(1))
      material.createSurfaceOutput(renderContext: .riRenderContext).connectTo(source: shader.createOutput(for: .out, type: .token))
      return material
    }

    private nonisolated static func define(_ m: PreviewShape.Mesh, at path: Pixar.SdfPath, on stage: UsdStage) -> UsdPrim
    {
      let any = Pixar.VtValue()
      let time = Pixar.UsdTimeCode.Default()
      let mesh = UsdGeom.Mesh.define(stage, path: path)
      let points = SceneEdit.vec3fArray(m.points)
      _ = mesh.GetPointsAttr().Set(points, time)
      _ = mesh.GetFaceVertexCountsAttr().Set(SceneEdit.intArray(m.faces.map { Int32($0.count) }), time)
      _ = mesh.GetFaceVertexIndicesAttr().Set(SceneEdit.intArray(m.faces.flatMap { $0.map(Int32.init) }), time)
      if !m.smooth { _ = mesh.CreateSubdivisionSchemeAttr(any, false).Set(Tf.Token.none_, time) }
      var extent = Pixar.VtVec3fArray()
      if Pixar.UsdGeomPointBased.ComputeExtent(points, &extent) { _ = mesh.GetExtentAttr().Set(extent, time) }
      let uvs: Pixar.VtVec2fArray = m.uvs.map { Pixar.GfVec2f($0.x, $0.y) }
        .withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
      _ = Pixar.UsdGeomPrimvarsAPI(mesh.GetPrim())
        .CreatePrimvar(.primaryUVSet, .texCoord2fArray, .faceVarying, -1).Set(uvs, time)
      return mesh.GetPrim()
    }

    /// Puts `shape` in place of the one shown, bound to the previewed material.
    private nonisolated static func author(_ shape: PreviewShape, on stage: UsdStage)
    {
      let base = Sdf.Path(shapePath)
      _ = stage.RemovePrim(base)
      _ = UsdGeom.Xform.define(stage, path: base)
      let material = Pixar.UsdShadeMaterial(stage.GetPrimAtPath(Sdf.Path(materialPath)))
      let any = Pixar.VtValue()
      let time = Pixar.UsdTimeCode.Default()
      for (i, part) in shape.parts.enumerated()
      {
        let path = base.AppendChild(Tf.Token("Part\(i)"))
        let prim: UsdPrim
        switch part
        {
          case let .mesh(m):
            prim = define(m, at: path, on: stage)
          case let .curves(c):
            var curves = UsdGeom.BasisCurves.define(stage, path: path)
            _ = curves.CreateTypeAttr(any, false).Set(Tf.Token.linear, time)
            _ = curves.GetPointsAttr().Set(SceneEdit.vec3fArray(c.points), time)
            _ = curves.CreateCurveVertexCountsAttr(any, false).Set(SceneEdit.intArray(c.counts.map(Int32.init)), time)
            let widths: Pixar.VtFloatArray = (c.widths.isEmpty ? [c.width] : c.widths)
              .withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
            _ = curves.CreateWidthsAttr(any, false).Set(widths, time)
            if c.widths.isEmpty { _ = curves.SetWidthsInterpolation(.constant) }
            prim = curves.GetPrim()
        }

        _ = UsdShade.MaterialBindingAPI.apply(prim).bind(material)
      }
    }
  }

  /// The material Preview panel: the preview, and the shapes to show it on down its side.
  @MainActor
  struct MaterialPreviewView: View
  {
    @State private var preview: MaterialPreview

    init(preview: MaterialPreview)
    {
      _preview = State(wrappedValue: preview)
    }

    private static func symbol(_ shape: PreviewShape) -> String
    {
      switch shape
      {
        case .flat: "square.fill"
        case .sphere: "circle.fill"
        case .cube: "cube.fill"
        case .hair: "wind"
        case .teapot: "cup.and.saucer.fill"
        case .cloth: "flag.fill"
        case .fluid: "drop.fill"
      }
    }

    var body: some View
    {
      // the shape buttons centered between the preview and the panel's edge.
      let gap = 13.0, side = Double(Properties.width - 30 - 26) - gap
      return HStack(alignment: .top, spacing: Int(gap))
      {
        if let hydra = preview.hydra
        {
          Hydra.Viewport(engine: hydra, framesPerSecond: 30)
            .frame(width: side, height: side * 0.8)
            .cornerRadius(6)
        }
        else
        {
          Rectangle()
            .fill(Properties.field)
            .frame(width: side, height: side * 0.8)
            .cornerRadius(6)
        }

        VStack(spacing: 2)
        {
          ForEach(PreviewShape.allCases, id: \.self)
          { shape in
            SymbolIcon(Self.symbol(shape), size: 11, white: preview.shape == shape ? 1 : 0.76)
              .frame(width: 26, height: 22)
              .background(RoundedRectangle(cornerRadius: 4).fill(preview.shape == shape ? Properties.accent : Properties.field))
              .onTapGesture { preview.show(shape) }
          }
        }
      }
    }
  }
}
