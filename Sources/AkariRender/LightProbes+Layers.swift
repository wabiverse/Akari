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
import LabGL
import simd

extension Akari.LightProbes
{
  /// the sun's bounce light baked for one direction.
  struct SunBake
  {
    var direction: SIMD3<Float>
    /// zero for a white sun colored at combine time, otherwise a key for the sky color it was baked with.
    var tint: Int
    var texture: GLuint
    var used: UInt64
    /// the sphere probes' base level lit by this sun, while it holds one of the few the probes keep
    var spheres: GLuint = 0
  }

  /// sun directions whose sphere probe layer stays baked, each a whole atlas, so only the most recently used keep one
  static let maxSunSphereLayers = 8

  /// what the sky layer was baked with.
  struct SkyKey: Equatable
  {
    var environment: UInt64
    var zUp: Bool
    var iblEnabled: Bool
    var sunHeight: Float
  }

  /// what the probes were last combined from.
  struct CombineKey: Equatable
  {
    var sunA: GLuint
    var sunB: GLuint
    var blend: Float
    var sunScale: SIMD3<Float>
    var skyTint: SIMD3<Float>
    var layerBakes: Int
  }

  /// how this frame's sun is baked and colored.
  struct SunLook
  {
    var direction: SIMD3<Float>
    /// authored suns bake white and get colored when combined, procedural suns keep their sky color.
    var isWhite: Bool
    var tint: Int
    var scale: SIMD3<Float>
    var isLit: Bool

    init(_ lighting: Lighting)
    {
      direction = Akari.Math.normalize(lighting.sunDirection)
      isWhite = lighting.sunColor.w > 1.5
      scale = isWhite ? SIMD3(lighting.sunColor.x, lighting.sunColor.y, lighting.sunColor.z) : SIMD3(repeating: 1)
      isLit = isWhite ? scale.max() > 0 : lighting.sunColor.w > 0
      tint = 0
      if !isWhite
      {
        var hasher = Hasher()
        hasher.combine(lighting.environment)
        hasher.combine(lighting.sunColor.w)
        hasher.combine(lighting.sunHeight)
        hasher.combine(lighting.skyTint.x)
        hasher.combine(lighting.skyTint.y)
        hasher.combine(lighting.skyTint.z)
        tint = hasher.finalize() | 1
      }
    }
  }

  /// sun bakes closer than this blend into each other.
  static let sunSpacingDegrees = 2.0
  static let maxSunBakes = 192

  private static var sunSpacingCos: Float
  {
    Float(cos(sunSpacingDegrees * .pi / 180))
  }

  /// bakes sky, sun and point lights separately and sums them, so color changes never rebake.
  func updateLayers(_ captures: [OpaquePointer],
                    sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                    materials: (material: GLuint, color: GLuint, emissive: GLuint, constants: GLuint),
                    environment: GLuint,
                    lighting: Lighting,
                    bounces: Int) -> Bool
  {
    layerFrame += 1
    let sun = SunLook(lighting)
    var baked = bakeSkyIfNeeded(lighting, environment: environment, bounces: bounces)
    baked = bakeLocalIfNeeded(lighting, environment: environment, bounces: bounces) || baked

    let bakeSunLayer = { (direction: SIMD3<Float>, white: Bool, tint: Int, spheres: Bool) in
      self.bakeSun(captures, direction: direction, sceneBounds: sceneBounds, materials: materials,
                   environment: environment, lighting: lighting, white: white, tint: tint, bounces: bounces, spheres: spheres)
    }

    if sun.isLit, !hasSunBake(near: sun.direction, tint: sun.tint)
    {
      bakeSunLayer(sun.direction, sun.isWhite, sun.tint, true)
      baked = true
    }

    // bake one planned sun direction every eight frames while nothing else is baking.
    if !baked, sun.isWhite, bakesAhead, layerFrame % 8 == 0, let planned = nextPlannedSunDirection()
    {
      // a direction baked ahead takes no sphere layer until it is one the sun is near
      bakeSunLayer(planned, true, 0, false)
    }

    if restoreSunSpheres(near: sun.direction, tint: sun.tint, captures: captures, sceneBounds: sceneBounds,
                         materials: materials, environment: environment, lighting: lighting)
    {
      combineKey = nil
    }

    combine(sun, lighting: lighting)
    isReady = true
    return true
  }

  private func bakeSkyIfNeeded(_ lighting: Lighting, environment: GLuint, bounces: Int) -> Bool
  {
    let key = SkyKey(environment: lighting.environment, zUp: lighting.zUp, iblEnabled: lighting.iblEnabled,
                     sunHeight: lighting.sunColor.w < 1.5 ? lighting.sunHeight : 0)
    guard key != skyKey else { return false }

    var untinted = lighting
    untinted.skyTint = SIMD3(repeating: 1)
    bakeLayer(untinted, lights: .sky, environment: environment, bounces: bounces, into: skyLayer)
    bakeSpheres(untinted, lights: .sky, environment: environment, sh: skyLayer, into: skySpheres)
    skyKey = key
    layerBakes += 1
    return true
  }

  private func bakeLocalIfNeeded(_ lighting: Lighting, environment: GLuint, bounces: Int) -> Bool
  {
    guard lighting.lights != localKey else { return false }
    bakeLayer(lighting, lights: .local, environment: environment, bounces: bounces, into: localLayer)
    bakeSpheres(lighting, lights: .local, environment: environment, sh: localLayer, into: localSpheres)
    localKey = lighting.lights
    layerBakes += 1
    return true
  }

  private func hasSunBake(near direction: SIMD3<Float>, tint: Int) -> Bool
  {
    nearestSunBakes(direction, tint: tint).first.map { simd_dot($0.direction, direction) >= Self.sunSpacingCos } ?? false
  }

  /// pops planned directions until one has no bake near it yet.
  private func nextPlannedSunDirection() -> SIMD3<Float>?
  {
    while !plannedSunDirections.isEmpty
    {
      let planned = Akari.Math.normalize(plannedSunDirections.removeFirst())
      if !hasSunBake(near: planned, tint: 0) { return planned }
    }

    return nil
  }

  /// sums the layers into the probes, blending the sun between its two nearest bakes.
  private func combine(_ sun: SunLook, lighting: Lighting)
  {
    let skyTint = lighting.skyTint
    let nearest = sun.isLit ? nearestSunBakes(sun.direction, tint: sun.tint) : []
    var key = CombineKey(sunA: skyLayer, sunB: skyLayer, blend: 0, sunScale: .zero, skyTint: skyTint, layerBakes: layerBakes)
    if let a = nearest.first
    {
      key.sunA = a.texture
      key.sunB = a.texture
      key.sunScale = sun.scale

      // only blend toward a second bake on the far side of the current direction.
      if nearest.count > 1
      {
        let b = nearest[1]
        let toA = angle(a.direction, sun.direction)
        let toB = angle(b.direction, sun.direction)
        let spacing = Float(Self.sunSpacingDegrees * .pi / 180)
        if simd_dot(b.direction, a.direction) < 1, toB < 2 * spacing,
           simd_dot(b.direction - a.direction, sun.direction - a.direction) > 0
        {
          key.sunB = b.texture
          key.blend = toA / max(toA + toB, 1e-6)
        }
      }
    }

    guard key != combineKey else { return }
    combineLayers(sunA: key.sunA, sunB: key.sunB, blend: key.blend, sunScale: key.sunScale, skyTint: key.skyTint, into: sh[0])
    shIndex = 0
    combineKey = key

    // the sphere probes sum the same layers, every level of them at once
    if !layout.spheres.isEmpty
    {
      let sphereOf = { (texture: GLuint) in self.sunBakes.first { $0.texture == texture }?.spheres ?? 0 }
      let sunA = key.sunA == skyLayer ? skySpheres : sphereOf(key.sunA)
      let sunB = key.sunB == skyLayer ? skySpheres : sphereOf(key.sunB)
      guard sunA != 0, sunB != 0 else { return }
      combineLayers(sunA: sunA, sunB: sunB, blend: key.blend, sunScale: key.sunScale, skyTint: key.skyTint, into: sphereAtlas,
                    sky: skySpheres, local: localSpheres,
                    size: SIMD2(Self.octTile.x * Self.octTilesPerRow, Self.octTile.y * Self.maxSphereProbes / Self.octTilesPerRow))
    }
  }

  private func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float
  {
    acos(min(max(simd_dot(a, b), -1), 1))
  }

  /// the two bakes nearest `direction` for this tint, marked as used.
  private func nearestSunBakes(_ direction: SIMD3<Float>, tint: Int) -> [SunBake]
  {
    let order = sunBakes.indices
      .filter { sunBakes[$0].tint == tint }
      .sorted { simd_dot(sunBakes[$0].direction, direction) > simd_dot(sunBakes[$1].direction, direction) }
      .prefix(2)
    for i in order { sunBakes[i].used = layerFrame }
    return order.map { sunBakes[$0] }
  }

  private func bakeSun(_ captures: [OpaquePointer],
                       direction: SIMD3<Float>,
                       sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                       materials: (material: GLuint, color: GLuint, emissive: GLuint, constants: GLuint),
                       environment: GLuint,
                       lighting: Lighting,
                       white: Bool,
                       tint: Int,
                       bounces: Int,
                       spheres withSpheres: Bool)
  {
    var texture: GLuint
    var spheres: GLuint = 0
    if sunBakes.count >= Self.maxSunBakes, let oldest = sunBakes.indices.min(by: { sunBakes[$0].used < sunBakes[$1].used })
    {
      let evicted = sunBakes.remove(at: oldest)
      texture = evicted.texture
      spheres = evicted.spheres
    }
    else
    {
      texture = makeSHTexture()
      guard texture != 0 else { return }
    }

    drawSunMap(captures, sceneBounds: sceneBounds, direction: direction, materials: materials)
    var sunlit = lighting
    sunlit.sunDirection = direction
    if white { sunlit.sunColor = SIMD4(1, 1, 1, 2) }
    bakeLayer(sunlit, lights: .sun, environment: environment, bounces: bounces, into: texture)

    // the sun map is still this direction's, so its sphere layer is shaded now
    if withSpheres, !layout.spheres.isEmpty
    {
      if spheres == 0 { spheres = takeSunSphereLayer() }
      bakeSpheres(sunlit, lights: .sun, environment: environment, sh: texture, into: spheres)
    }
    else if spheres != 0
    {
      // an evicted bake's sphere layer holds another direction's light
      gl.deleteTextures(count: 1, textures: &spheres)
      spheres = 0
    }

    sunBakes.append(SunBake(direction: direction, tint: tint, texture: texture, used: layerFrame, spheres: spheres))
  }

  /// a sphere atlas for another sun direction, a fresh one while fewer than the most are kept, else the least recently used one's
  private func takeSunSphereLayer() -> GLuint
  {
    let holders = sunBakes.indices.filter { sunBakes[$0].spheres != 0 }
    guard holders.count >= Self.maxSunSphereLayers, let oldest = holders.min(by: { sunBakes[$0].used < sunBakes[$1].used })
    else { return makeSphereAtlas() }

    let atlas = sunBakes[oldest].spheres
    sunBakes[oldest].spheres = 0
    return atlas
  }

  /// gives the two sun bakes nearest `direction` their sphere layer back and draws their sun map again, true when one was shaded
  private func restoreSunSpheres(near direction: SIMD3<Float>, tint: Int, captures: [OpaquePointer],
                                 sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                                 materials: (material: GLuint, color: GLuint, emissive: GLuint, constants: GLuint),
                                 environment: GLuint, lighting: Lighting) -> Bool
  {
    guard !layout.spheres.isEmpty else { return false }
    var shaded = false
    for bake in nearestSunBakes(direction, tint: tint) where bake.spheres == 0
    {
      guard let index = sunBakes.firstIndex(where: { $0.texture == bake.texture }) else { continue }
      let atlas = takeSunSphereLayer()
      drawSunMap(captures, sceneBounds: sceneBounds, direction: bake.direction, materials: materials)
      var sunlit = lighting
      sunlit.sunDirection = bake.direction
      if bake.tint == 0 { sunlit.sunColor = SIMD4(1, 1, 1, 2) }
      bakeSpheres(sunlit, lights: .sun, environment: environment, sh: bake.texture, into: atlas)
      sunBakes[index].spheres = atlas
      shaded = true
    }

    return shaded
  }

  /// drops every bake after the scene they were made from changes.
  func resetLayers()
  {
    for var texture in sunBakes.flatMap({ [$0.texture, $0.spheres] }) where texture != 0
    {
      gl.deleteTextures(count: 1, textures: &texture)
    }

    sunBakes = []
    skyKey = nil
    localKey = nil
    combineKey = nil
  }
}
