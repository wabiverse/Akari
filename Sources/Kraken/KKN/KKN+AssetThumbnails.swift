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
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

extension Kraken
{
  #if os(macOS)
    typealias PlatformImage = NSImage
  #else
    typealias PlatformImage = UIImage
  #endif

  /// the asset browser's pictures, an asset's own preview or one akari renders in the background, cached until the asset changes
  @MainActor
  final class AssetThumbnails
  {
    static let shared = AssetThumbnails()

    private(set) var images: [String: PlatformImage] = [:]
    /// assets waiting for a render, and whether one is running
    private var pending: [LibraryAsset] = []
    private var rendering = false
    private var failed: Set<String> = []

    nonisolated static let size = 256

    nonisolated static var cache: URL
    {
      URL.cachesDirectory.appendingPathComponent("Kraken/Thumbnails")
    }

    /// the cached render of an asset, named by where it lives and when it last changed
    nonisolated static func cached(_ asset: LibraryAsset) -> URL
    {
      var hash: UInt64 = 0xCBF2_9CE4_8422_2325
      for byte in "\(asset.id)|\(asset.modified)".utf8
      {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
      }

      return cache.appendingPathComponent(String(hash, radix: 16) + ".png")
    }

    /// lets the renders that failed run again, a worker that was stopped part way leaves its assets failed
    func retryFailed()
    {
      failed.removeAll()
    }

    func image(_ asset: LibraryAsset) -> PlatformImage?
    {
      images[asset.id]
    }

    /// loads what's on disk and renders the rest
    func prepare(_ assets: [LibraryAsset])
    {
      var toLoad: [(String, String)] = []
      for asset in assets where images[asset.id] == nil
      {
        if let file = asset.thumbnail, FileManager.default.fileExists(atPath: file) { toLoad.append((asset.id, file)) }
        else if FileManager.default.fileExists(atPath: Self.cached(asset).path) { toLoad.append((asset.id, Self.cached(asset).path)) }
        else if !failed.contains(asset.id), !pending.contains(where: { $0.id == asset.id }) { pending.append(asset) }
      }

      load(toLoad)
      renderPending()
    }

    private func load(_ files: [(String, String)])
    {
      guard !files.isEmpty else { return }
      DispatchQueue.global(qos: .utility).async
      {
        let loaded = files.compactMap { id, file in PlatformImage(contentsOfFile: file).map { (id, $0) } }
        nonisolated(unsafe) let images = loaded
        DispatchQueue.main.async
        {
          for (id, image) in images { self.images[id] = image }
          AssetLibrary.shared.changed()
        }
      }
    }

    // MARK: rendering

    /// renders every waiting asset as one frame each of a background render's animation
    private func renderPending()
    {
      #if os(macOS)
        guard !rendering, !pending.isEmpty, let executable = Bundle.main.executableURL else { return }
        rendering = true
        let batch = pending
        pending = []
        let folder = Self.cache
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let stagePath = folder.appendingPathComponent("batch_\(stamp).usda").path
        let output = folder.appendingPathComponent("batch_\(stamp)_####").path

        DispatchQueue.global(qos: .utility).async
        {
          try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          Self.writeBatch(batch, to: stagePath)

          let process = Process()
          process.executableURL = executable
          process.arguments = ["--usd", stagePath, "-b", "-a", "-s", "1", "-e", "\(batch.count)", "-F", "PNG",
                               "-o", output, "--resolution", "\(Self.size)x\(Self.size)", "--camera", "/Thumbs/Camera"]
          process.standardOutput = FileHandle.nullDevice
          process.standardError = FileHandle.nullDevice
          do
          {
            try process.run()
            process.waitUntilExit()
          }
          catch
          {
            Console.warn("couldn't render asset thumbnails, \(error.localizedDescription)")
          }

          var done: [(String, String)] = []
          var missed: [String] = []
          for (i, asset) in batch.enumerated()
          {
            let frame = URL(fileURLWithPath: output.replacingOccurrences(of: "####", with: String(format: "%04d", i + 1)) + ".png")
            let target = Self.cached(asset)
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.moveItem(at: frame, to: target)) != nil { done.append((asset.id, target.path)) }
            else { missed.append(asset.id) }
          }

          try? FileManager.default.removeItem(atPath: stagePath)
          let loaded = done, misses = missed
          DispatchQueue.main.async
          {
            self.rendering = false
            self.failed.formUnion(misses)
            self.load(loaded)
            self.renderPending()
          }
        }
      #endif
    }

    /// a stage with each asset alone in view on its own frame, scaled to fit the one camera
    nonisolated private static func writeBatch(_ batch: [LibraryAsset], to path: String)
    {
      let stage = UsdStage.createNew(path)
      _ = UsdGeom.setUpAxis(for: stage, to: .y)
      _ = UsdGeom.setMetersPerUnit(for: stage, to: 1)
      stage.SetStartTimeCode(1)
      stage.SetEndTimeCode(Double(batch.count))
      let root = Sdf.Path("/Thumbs")
      _ = UsdGeom.Xform.define(stage, path: root)
      let any = Pixar.VtValue()
      let time = Pixar.UsdTimeCode.Default()

      // a three quarter view from a little above, the subject a unit sphere at the origin
      let camera = UsdGeom.Camera.define(stage, path: root.AppendChild(Tf.Token("Camera")))
      camera.CreateFocalLengthAttr(any, false).set(Float(50))
      camera.CreateHorizontalApertureAttr(any, false).set(Float(24))
      camera.CreateVerticalApertureAttr(any, false).set(Float(24))
      _ = camera.CreateClippingRangeAttr(any, false).Set(Pixar.GfVec2f(0.1, 100), time)
      let eye = simd_normalize(SIMD3<Double>(0.9, 0.62, 1.25)) * 4.7
      _ = UsdGeom.Xformable(camera.GetPrim()).addXformOp(type: .transform, precision: .double)
        .Set(SceneEdit.matrix(Layout.array(look(from: eye, at: .zero))), time)

      let sun = UsdLux.DistantLight.define(stage, path: root.AppendChild(Tf.Token("Key")))
      sun.CreateIntensityAttr(any, false).set(Float(1400))
      sun.CreateAngleAttr(any, false).set(Float(4))
      _ = UsdGeom.Xformable(sun.GetPrim()).addXformOp(type: .rotateXYZ, precision: .float)
        .Set(Pixar.GfVec3f(-45, 35, 0), time)
      let dome = UsdLux.DomeLight.define(stage, path: root.AppendChild(Tf.Token("Fill")))
      dome.CreateIntensityAttr(any, false).set(Float(0.35))
      dome.CreateColorAttr(any, false).Set(Pixar.GfVec3f(0.32, 0.33, 0.36), time)

      for (i, asset) in batch.enumerated()
      {
        let path = root.AppendChild(Tf.Token("Asset\(i)"))
        let holder = UsdGeom.Xform.define(stage, path: path).GetPrim()
        let visibility = Pixar.UsdGeomImageable(holder).CreateVisibilityAttr(any, false)
        _ = visibility.Set(Tf.Token.invisible, Pixar.UsdTimeCode(0))
        _ = visibility.Set(Tf.Token.inherited, Pixar.UsdTimeCode(Double(i + 1)))
        _ = visibility.Set(Tf.Token.invisible, Pixar.UsdTimeCode(Double(i + 2)))

        switch asset.kind
        {
          case .model:
            let model = path.AppendChild(Tf.Token("Model"))
            var references = UsdGeom.Xform.define(stage, path: model).GetPrim().getReferences()
            if asset.prim.isEmpty { references.addReference(assetPath: asset.file) }
            else { references.addReference(assetPath: asset.file, primPath: Sdf.Path(asset.prim)) }

            // a kit asset scanned without its payload is measured here, where its geometry is loaded
            var sized = asset
            if sized.bounds.count != 6, let measured = SceneEdit.localBounds(stage, model.string, Pixar.UsdTimeCode.Default().GetValue())
            {
              sized.bounds = measured
            }

            let center = (sized.lo + sized.hi) / 2
            let radius = max(simd_length(sized.hi - sized.lo) / 2, 1e-6)
            var fit = matrix_identity_double4x4
            fit.columns.3 = SIMD4(-center, 1)
            let upright = asset.isZUp ? AssetPlace.rotation(x: -.pi / 2) : matrix_identity_double4x4
            var scale = matrix_identity_double4x4
            scale.columns.0.x = 1 / radius
            scale.columns.1.y = 1 / radius
            scale.columns.2.z = 1 / radius
            let fitted = Pixar.UsdGeomXformable(stage.GetPrimAtPath(model))
            _ = fitted.ClearXformOpOrder()
            _ = fitted.addXformOp(type: .transform, precision: .double).Set(SceneEdit.matrix(Layout.array(scale * upright * fit)), time)
          case .material:
            let materialPath = path.AppendChild(Tf.Token("Material"))
            var references = stage.DefinePrim(materialPath, .material).getReferences()
            references.addReference(assetPath: asset.file, primPath: Sdf.Path(asset.prim))
            let ball = UsdGeom.Mesh.define(stage, path: path.AppendChild(Tf.Token("Ball")))
            if case let .mesh(m)? = PreviewShape.sphere.parts.first
            {
              let points = SceneEdit.vec3fArray(m.points.map { $0 * 0.82 })
              _ = ball.GetPointsAttr().Set(points, time)
              _ = ball.GetFaceVertexCountsAttr().Set(SceneEdit.intArray(m.faces.map { Int32($0.count) }), time)
              _ = ball.GetFaceVertexIndicesAttr().Set(SceneEdit.intArray(m.faces.flatMap { $0.map(Int32.init) }), time)
              let uvs: Pixar.VtVec2fArray = m.uvs.map { Pixar.GfVec2f($0.x, $0.y) }
                .withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
              _ = Pixar.UsdGeomPrimvarsAPI(ball.GetPrim()).CreatePrimvar(.primaryUVSet, .texCoord2fArray, .faceVarying, -1)
                .Set(uvs, time)
              var extent = Pixar.VtVec3fArray()
              if Pixar.UsdGeomPointBased.ComputeExtent(points, &extent) { _ = ball.GetExtentAttr().Set(extent, time) }
            }

            _ = UsdShade.MaterialBindingAPI.apply(ball.GetPrim()).bind(Pixar.UsdShadeMaterial(stage.GetPrimAtPath(materialPath)))
        }
      }

      _ = stage.GetRootLayer().pointee.Save(false)
    }

    /// a camera transform at `eye` looking at `target`, y up
    nonisolated static func look(from eye: SIMD3<Double>, at target: SIMD3<Double>) -> simd_double4x4
    {
      let back = simd_normalize(eye - target)
      let side = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
      let up = simd_cross(back, side)
      return simd_double4x4(columns: (SIMD4(side, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(eye, 1)))
    }
  }
}
