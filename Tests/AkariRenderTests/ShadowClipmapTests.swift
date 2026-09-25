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

import Foundation
import Testing
@testable import AkariCore
@testable import AkariRender

@Suite("ShadowAtlas clipmap")
struct ShadowClipmapTests
{
  private static func corners(_ bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> [SIMD3<Float>]
  {
    (0 ..< 8).map
    { i in
      SIMD3(i & 1 == 0 ? bounds.min.x : bounds.max.x,
            i & 2 == 0 ? bounds.min.y : bounds.max.y,
            i & 4 == 0 ? bounds.min.z : bounds.max.z)
    }
  }

  private static func camera(at position: SIMD3<Float>) -> Akari.Camera
  {
    Akari.Camera(view: Akari.Matrix4.translation(-position), projection: Akari.Matrix4.identity)
  }

  private static func camera(eye: SIMD3<Float>, target: SIMD3<Float>) -> Akari.Camera
  {
    Akari.Camera(view: Akari.Matrix4.lookAt(eye: eye, target: target, up: SIMD3(0, 1, 0)),
                 projection: Akari.Matrix4.identity)
  }

  private static func perspective(near: Float, far: Float, halfWidth: Float, halfHeight: Float) -> Akari.Matrix4
  {
    Akari.Matrix4([
      near / halfWidth, 0, 0, 0,
      0, near / halfHeight, 0, 0,
      0, 0, -(far + near) / (far - near), -1,
      0, 0, -2 * far * near / (far - near), 0,
    ])
  }

  private static func perspectiveCamera(at position: SIMD3<Float>, near: Float, far: Float) -> Akari.Camera
  {
    Akari.Camera(view: Akari.Matrix4.translation(-position),
                 projection: perspective(near: near, far: far, halfWidth: 1, halfHeight: 1))
  }

  private static let straightDown = SIMD3<Float>(0, -1, 0)

  @Test("consecutive active levels' coverage differs by exactly a factor of 2")
  func coverageIsAbsolutePowerOfTwo()
  {
    var settings = ShadowSettings()
    settings.levelCount = ShadowSettings.maxLevels
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let fit = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: SIMD3<Float>(0, 0, 2000)),
                                          lightDirection: Self.straightDown,
                                          sceneCorners: Self.corners(bounds),
                                          settings: settings)
    let levels = fit.cascades
    #expect(levels.count > 1)

    for i in 1 ..< levels.count
    {
      #expect(abs(levels[i].splitFar / levels[i - 1].splitFar - 2) < 1e-3)
    }
    for level in levels
    {
      let l = log2(level.splitFar)
      #expect(abs(l - l.rounded(.toNearestOrAwayFromZero)) < 1e-3 || abs(l * 2 - (l * 2).rounded()) < 1e-3)
    }
  }

  @Test("the coarsest active level always reaches the camera's own far clip, growing automatically as far clip grows")
  func coarsestLevelAlwaysReachesTheCamerasOwnFarClip() throws
  {
    var settings = ShadowSettings()
    settings.levelCount = ShadowSettings.maxLevels
    let bounds = (min: SIMD3<Float>(-50, -50, -50), max: SIMD3<Float>(50, 50, 50))

    var previousRadius: Float = 0
    for far: Float in [50, 500, 5000]
    {
      let camera = Self.perspectiveCamera(at: SIMD3<Float>(0, 0, 200), near: 1, far: far)
      let fit = Akari.ShadowAtlas.fitLevels(camera: camera,
                                            lightDirection: Self.straightDown,
                                            sceneCorners: Self.corners(bounds),
                                            settings: settings)
      let levels = fit.cascades
      #expect(!levels.isEmpty)
      let coarsestRadius = try #require(levels.last?.splitFar)
      #expect(coarsestRadius >= far * 0.5)
      #expect(coarsestRadius > previousRadius)
      previousRadius = coarsestRadius
    }
  }

  @Test("reach does not depend on how far the camera sits from the scene, only on the camera's own frustum")
  func reachIsIndependentOfCameraToSceneDistance() throws
  {
    var settings = ShadowSettings()
    settings.levelCount = ShadowSettings.maxLevels
    let bounds = (min: SIMD3<Float>(-50, -50, -50), max: SIMD3<Float>(50, 50, 50))

    let near = Self.perspectiveCamera(at: SIMD3<Float>(0, 0, 200), near: 1, far: 500)
    let far = Self.perspectiveCamera(at: SIMD3<Float>(0, 0, 50000), near: 1, far: 500)
    let levelsNear = Akari.ShadowAtlas.fitLevels(camera: near, lightDirection: Self.straightDown,
                                                 sceneCorners: Self.corners(bounds), settings: settings).cascades
    let levelsFar = Akari.ShadowAtlas.fitLevels(camera: far, lightDirection: Self.straightDown,
                                                sceneCorners: Self.corners(bounds), settings: settings).cascades
    #expect(!levelsNear.isEmpty && !levelsFar.isEmpty)
    #expect(try abs(#require(levelsNear.last?.splitFar) - levelsFar.last!.splitFar) < 1e-2)
    #expect(levelsNear.count == levelsFar.count)
  }

  @Test("centring follows the camera's own position, not view direction - rotating in place doesn't move it")
  func centringFollowsPositionOnlyNotViewDirection()
  {
    var settings = ShadowSettings()
    settings.levelCount = ShadowSettings.maxLevels
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let position = SIMD3<Float>(1400, 300, 1400)

    let targets: [SIMD3<Float>] = [
      SIMD3(0, 0, 0), SIMD3(500, 500, 500), SIMD3(-2000, 1000, 300), SIMD3(1400, 300, 0),
    ]
    var allLevels: [[Akari.ShadowAtlas.Cascade]] = []
    for target in targets where target != position
    {
      allLevels.append(Akari.ShadowAtlas.fitLevels(camera: Self.camera(eye: position, target: target),
                                                   lightDirection: Self.straightDown,
                                                   sceneCorners: Self.corners(bounds), settings: settings).cascades)
    }

    for levels in allLevels
    {
      #expect(levels.count == allLevels[0].count)
      for i in 0 ..< min(levels.count, allLevels[0].count)
      {
        #expect(levels[i].view.m == allLevels[0][i].view.m)
      }
    }
  }

  @Test("levelLodBias shifts the whole active range coarser or finer by that many integer levels")
  func lodBiasShiftsTheActiveRange()
  {
    var settings = ShadowSettings()
    settings.levelCount = ShadowSettings.maxLevels
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let camera = Self.camera(at: SIMD3<Float>(0, 0, 2000))

    let base = Akari.ShadowAtlas.fitLevels(camera: camera, lightDirection: Self.straightDown,
                                           sceneCorners: Self.corners(bounds), settings: settings).cascades
    settings.levelLodBias = 2
    let biased = Akari.ShadowAtlas.fitLevels(camera: camera, lightDirection: Self.straightDown,
                                             sceneCorners: Self.corners(bounds), settings: settings).cascades

    #expect(!base.isEmpty && !biased.isEmpty)
    #expect(abs(biased[0].splitFar / base[0].splitFar - 4) < 1e-2)
  }

  @Test("the directional LOD0 flat-index block is exactly tilemapRes x tilemapRes and matches the shaders' tile.y * tilemapRes + tile.x")
  func directionalLod0FlatIndexBlockCoverage()
  {
    let res = Akari.ShadowAtlas.tilemapRes
    #expect(res == 32)

    var seen = Set<Int>()
    for y in 0 ..< res
    {
      for x in 0 ..< res
      {
        let flat = Akari.ShadowAtlas.flatIndex(tileX: x, tileY: y, lod: 0)
        #expect(flat == y * res + x)
        seen.insert(flat)
      }
    }
    #expect(seen == Set(0 ..< (res * res)))
    #expect(Akari.ShadowAtlas.tilesPerTilemap >= res * res)

    for flat in 0 ..< Akari.ShadowAtlas.tilesPerTilemap
    {
      let (lod, x, y) = Akari.ShadowAtlas.decodeFlatIndex(flat)
      #expect(Akari.ShadowAtlas.flatIndex(tileX: x, tileY: y, lod: lod) == flat)
      #expect(lod == 0 ? flat < res * res : flat >= res * res)
    }
  }

  @Test("identical inputs, camera included, always produce bit-identical levels")
  func deterministic()
  {
    var settings = ShadowSettings()
    settings.levelCount = 4
    let bounds = (min: SIMD3<Float>(-50, -50, -50), max: SIMD3<Float>(50, 50, 50))
    let light = SIMD3<Float>(0.3, -0.8, 0.2)
    let camera = Self.camera(at: SIMD3<Float>(120, 30, -70))

    let a = Akari.ShadowAtlas.fitLevels(camera: camera, lightDirection: light,
                                        sceneCorners: Self.corners(bounds), settings: settings).cascades
    let b = Akari.ShadowAtlas.fitLevels(camera: camera, lightDirection: light,
                                        sceneCorners: Self.corners(bounds), settings: settings).cascades

    #expect(a.count == b.count)
    for i in 0 ..< a.count
    {
      #expect(a[i].key == b[i].key)
      #expect(a[i].view.m == b[i].view.m)
      #expect(a[i].viewProjection.m == b[i].viewProjection.m)
    }
  }

  @Test("a level's snapped center is stable under small camera movement, and moves under a large one")
  func pageSnapStability()
  {
    var settings = ShadowSettings()
    settings.levelCount = 4
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let base = SIMD3<Float>(10000, 5, 10000)

    let levelsBase = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: base), lightDirection: Self.straightDown,
                                                 sceneCorners: Self.corners(bounds), settings: settings).cascades
    #expect(!levelsBase.isEmpty)

    let radius = levelsBase[0].splitFar
    let pageStep = 2 * radius / 32

    let nudged = base + SIMD3<Float>(pageStep * 0.01, 0, 0)
    let levelsNudged = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: nudged), lightDirection: Self.straightDown,
                                                   sceneCorners: Self.corners(bounds), settings: settings).cascades
    #expect(levelsBase[0].view.m == levelsNudged[0].view.m)

    let moved = base + SIMD3<Float>(pageStep * 3, 0, 0)
    let levelsMoved = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: moved), lightDirection: Self.straightDown,
                                                  sceneCorners: Self.corners(bounds), settings: settings).cascades
    #expect(levelsBase[0].view.m != levelsMoved[0].view.m)
  }

  @Test("a recenter shifts the view's translation by whole pages but keeps its rotation; relighting changes the rotation")
  func recenterShiftsTranslationOnlyRelightChangesRotation()
  {
    var settings = ShadowSettings()
    settings.levelCount = 4
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let base = SIMD3<Float>(10000, 5, 10000)

    func rotationPart(_ m: Akari.Matrix4) -> [Float]
    {
      (0 ..< 3).flatMap { c in (0 ..< 3).map { r in m[c, r] } }
    }

    let levelsBase = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: base), lightDirection: Self.straightDown,
                                                 sceneCorners: Self.corners(bounds), settings: settings).cascades
    let radius = levelsBase[0].splitFar
    let pageStep = 2 * radius / 32

    let moved = base + SIMD3<Float>(pageStep, 0, 0)
    let levelsMoved = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: moved), lightDirection: Self.straightDown,
                                                  sceneCorners: Self.corners(bounds), settings: settings).cascades
    #expect(levelsMoved[0].key != levelsBase[0].key)
    #expect(rotationPart(levelsMoved[0].view) == rotationPart(levelsBase[0].view))

    let levelsRelit = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: base),
                                                  lightDirection: SIMD3<Float>(0.3, -0.9, 0.1),
                                                  sceneCorners: Self.corners(bounds), settings: settings).cascades
    #expect(rotationPart(levelsRelit[0].view) != rotationPart(levelsBase[0].view))
  }

  @Test("every light-space distance resolves to a level whose map contains it - the fit and the pick/shade agree on the tiling")
  func pickedLevelMapAlwaysContainsItsDistance() throws
  {
    var settings = ShadowSettings()
    settings.levelCount = 4
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let fit = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: SIMD3<Float>(1400, 300, 1400)),
                                          lightDirection: Self.straightDown,
                                          sceneCorners: Self.corners(bounds), settings: settings)
    let levels = fit.cascades
    guard let lodMin = levels.first?.absoluteLevel, let lodMax = levels.last?.absoluteLevel
    else { return }
    #expect(lodMax >= lodMin)
    let narrowing: Float = 32.0 / (32.0 - 1.0001)

    var dist = try max(#require(levels.first?.splitFar) * 0.25, 0.01)
    while dist <= levels.last!.splitFar
    {
      let raw = log2(dist * narrowing * 2.0)
      let pick = max(lodMin, min(lodMax, Int32(ceil(raw))))
      let index = Int(pick) - Int(lodMin)
      if index >= 0, index < levels.count
      {
        let radius = levels[index].splitFar
        #expect(dist <= radius * 1.0002,
                "distance \(dist) resolves to level \(pick) whose half-width \(radius) does not contain it")
      }
      dist *= 1.5
    }
  }

  /// Each level snaps the *same* light-space window center to its own grid.
  @Test("consecutive levels are snaps of ONE shared window center - their centers differ by whole fine tiles")
  func adjacentLevelGridsDifferByWholeFineTiles()
  {
    var settings = ShadowSettings()
    settings.levelCount = 4
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let fit = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: SIMD3<Float>(1400, 300, 1400)),
                                          lightDirection: Self.straightDown,
                                          sceneCorners: Self.corners(bounds), settings: settings)
    let levels = fit.cascades
    #expect(levels.count > 1)

    for i in 1 ..< levels.count
    {
      let fine = levels[i - 1]
      let fineTile = 2 * fine.splitFar / 32
      let dx = levels[i].view.m[12] - fine.view.m[12]
      let dy = levels[i].view.m[13] - fine.view.m[13]
      #expect(abs((dx / fineTile).rounded() - dx / fineTile) < 1e-3,
              "level \(levels[i].absoluteLevel) center differs from level \(fine.absoluteLevel) by \(dx) (not whole \(fineTile)s)")
      #expect(abs((dy / fineTile).rounded() - dy / fineTile) < 1e-3,
              "level \(levels[i].absoluteLevel) center differs from level \(fine.absoluteLevel) by \(dy) (not whole \(fineTile)s)")
    }
  }

  /// Cascade.gridOffset is what `dispatchTilemapShift` consumes to decide which pages move
  /// where.
  @Test("gridOffset encodes exactly the snap baked into the view translation - the shift/dispatch path agrees with the fit")
  func gridOffsetMatchesViewTranslation()
  {
    var settings = ShadowSettings()
    settings.levelCount = 4
    let bounds = (min: SIMD3<Float>(-500, -500, -500), max: SIMD3<Float>(500, 500, 500))
    let fit = Akari.ShadowAtlas.fitLevels(camera: Self.camera(at: SIMD3<Float>(1400, 300, 1400)),
                                          lightDirection: Self.straightDown,
                                          sceneCorners: Self.corners(bounds), settings: settings)
    let levels = fit.cascades
    #expect(!levels.isEmpty)

    for level in levels
    {
      let tileSize = 2 * level.splitFar / 32
      #expect(abs(Float(level.gridOffsetX) * tileSize + level.view.m[12]) < tileSize * 1e-4,
              "gridOffsetX \(level.gridOffsetX) does not match view translation \(level.view.m[12]) at \(tileSize)-sized tiles")
      #expect(abs(Float(level.gridOffsetY) * tileSize + level.view.m[13]) < tileSize * 1e-4,
              "gridOffsetY \(level.gridOffsetY) does not match view translation \(level.view.m[13]) at \(tileSize)-sized tiles")
    }
  }
}
