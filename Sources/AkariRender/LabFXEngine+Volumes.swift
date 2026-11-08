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
import Foundation
import HdAkari
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// The stage's `UsdVolVolume`, its density in a 3D texture, ray marched over the resolve.
  struct Volumes
  {
    struct Grid
    {
      var texture: GLuint
      var dims: SIMD3<Int>
      var localFromTexture: simd_double4x4
    }

    struct Hero
    {
      var key: String
      var worldFromTexture: simd_double4x4
      var densityScale: Float
      var albedo: SIMD3<Float>
      var anisotropy: Float
    }

    /// A density field read off the render thread, waiting for its texture.
    struct Voxels: @unchecked Sendable
    {
      var dims: SIMD3<Int>
      var half: [UInt16]
      var localFromTexture: simd_double4x4
    }

    var revision: UInt64 = .max
    var grids: [String: Grid] = [:]
    var loading: Set<String> = []
    let loaded = Loaded()

    final class Loaded: @unchecked Sendable
    {
      let lock = NSLock()
      var voxels: [String: Voxels?] = [:]
    }

    var hero: Hero?
    var passesActive = true
    var shadowThisFrame = true
    var bakedShadow: [Float] = []
  }

  static let volumePasses: [Pass] = [.volumeShadow, .volumeMarch]

  /// Picks up the first visible volume and loads its density field once per file.
  func syncVolumes(_ scene: Pixar.HdAkariScene)
  {
    let revision = scene.VolumeRevision()
    guard revision != volumes.revision else { return }
    volumes.revision = revision

    guard let data = scene.VolumeSnapshot().first, let p = data.transform.GetArray()
    else
    {
      volumes.hero = nil
      return
    }

    let file = String(data.densityFile), name = String(data.densityName)
    let resolution = max(Int(data.maxResolution), 8)
    let key = "\(file)|\(name)|\(resolution)"
    if volumes.grids[key] == nil, !loadsInBackground
    {
      volumes.grids[key] = Self.readVolumeGrid(file: file, name: name, resolution: resolution).map(Self.uploadVolumeGrid)
    }
    else if volumes.grids[key] == nil
    {
      // the viewport reads it off the render thread and draws without it until it's in.
      let loaded = volumes.loaded
      if volumes.loading.insert(key).inserted
      {
        DispatchQueue.global(qos: .userInitiated).async
        {
          let voxels = Self.readVolumeGrid(file: file, name: name, resolution: resolution)
          loaded.lock.withLock { loaded.voxels[key] = .some(voxels) }
        }
      }

      if let voxels = loaded.lock.withLock({ loaded.voxels.removeValue(forKey: key) })
      {
        volumes.loading.remove(key)
        if let voxels { volumes.grids[key] = Self.uploadVolumeGrid(voxels) }
      }
      else
      {
        volumes.revision = .max
      }
    }

    guard let grid = volumes.grids[key]
    else
    {
      volumes.hero = nil
      return
    }

    let world = simd_double4x4(rows: (0 ..< 4).map { r in SIMD4((0 ..< 4).map { p[r * 4 + $0] }) })
    volumes.hero = Volumes.Hero(key: key,
                                worldFromTexture: world.transpose * grid.localFromTexture.transpose,
                                densityScale: max(data.densityScale, 0),
                                albedo: SIMD3(data.albedoR, data.albedoG, data.albedoB),
                                anisotropy: min(max(data.anisotropy, -0.95), 0.95))
  }

  /// Binds the volume for the frame and rebakes its sun shadow when the sun or the volume moved.
  func applyVolumes(sun: SIMD3<Float>)
  {
    let active = volumes.hero != nil
    if active != volumes.passesActive
    {
      setPasses(Self.volumePasses, active: active)
      volumes.passesActive = active
      volumes.shadowThisFrame = active
      volumes.bakedShadow = []
    }

    guard let hero = volumes.hero, let grid = volumes.grids[hero.key]
    else
    {
      setVector(.volumeParams, .zero)
      return
    }

    let m = hero.worldFromTexture
    let toWorld = simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    setMatrix(.volumeWorldFromTexture, Akari.Matrix4(toWorld))
    setMatrix(.volumeTextureFromWorld, Akari.Matrix4(toWorld.inverse))
    var texture = grid.texture
    runtime.setUniform(.volumeDensity, type: GLenum(GL_SAMPLER_3D), data: &texture)
    setVector(.volumeParams, SIMD4(hero.densityScale, hero.anisotropy, 1, Float(max(grid.dims.x, max(grid.dims.y, grid.dims.z)))))
    setVector(.volumeAlbedo, SIMD4(hero.albedo, 0))
    let direction = Akari.Math.normalize(sun)
    setVector(.volumeSun, SIMD4(direction, 0))

    // the shadow is baked in the volume's own space, moving it changes nothing, turning or scaling it does.
    let key = [direction.x, direction.y, direction.z, hero.densityScale]
      + (0 ..< 3).flatMap { c in (0 ..< 3).map { Float(hero.worldFromTexture[c][$0]) } }
    let bake = key != volumes.bakedShadow
    volumes.bakedShadow = key
    if bake != volumes.shadowThisFrame
    {
      runtime.setPassActive(.volumeShadow, active: bake)
      volumes.shadowThisFrame = bake
    }
  }

  private static func readVolumeGrid(file: String, name: String, resolution: Int) -> Volumes.Voxels?
  {
    guard !file.isEmpty, let grid = Pixar.HdAkariLoadVolumeGrid(std.string(file), std.string(name), Int32(resolution))
    else
    {
      print("[akari] volume: could not read '\(name)' from \(file)")
      return nil
    }

    defer { Pixar.HdAkariFreeVolumeGrid(grid) }
    let dims = SIMD3(Int(Pixar.HdAkariVolumeGridWidth(grid)), Int(Pixar.HdAkariVolumeGridHeight(grid)), Int(Pixar.HdAkariVolumeGridDepth(grid)))
    let count = dims.x * dims.y * dims.z
    let voxels = UnsafeBufferPointer(start: Pixar.HdAkariVolumeGridVoxels(grid), count: count)
    let m = (0 ..< 16).map { Pixar.HdAkariVolumeGridMatrix(grid, Int32($0)) }
    print("[akari] volume: \(name) from \((file as NSString).lastPathComponent), \(dims.x)x\(dims.y)x\(dims.z)")
    return Volumes.Voxels(dims: dims, half: voxels.map { Float16($0).bitPattern },
                          localFromTexture: simd_double4x4(rows: (0 ..< 4).map { r in SIMD4((0 ..< 4).map { m[r * 4 + $0] }) }))
  }

  private static func uploadVolumeGrid(_ voxels: Volumes.Voxels) -> Volumes.Grid
  {
    var texture: GLuint = 0
    gl.genTextures(count: 1, textures: &texture)
    gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: texture)
    // trilinear and clamped, a nearest lookup shows every voxel once the camera is inside the cloud.
    for (pname, param) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR),
                           (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE),
                           (GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)]
    {
      gl.texParameter(target: GLenum(GL_TEXTURE_3D), pname: GLenum(pname), param: GLint(param))
    }

    gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: GLint(GL_R16F),
                  width: GLsizei(voxels.dims.x), height: GLsizei(voxels.dims.y), depth: GLsizei(voxels.dims.z), border: 0,
                  format: GLenum(GL_RED), type: GLenum(GL_HALF_FLOAT), pixels: voxels.half)
    return Volumes.Grid(texture: texture, dims: voxels.dims, localFromTexture: voxels.localFromTexture)
  }
}
