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
import simd

extension Akari.ShadowAtlas
{
  /// One cube face's view/projection for a point light.
  struct PunctualFace
  {
    var view: Akari.Matrix4
    var projection: Akari.Matrix4
    var viewProjection: Akari.Matrix4
    var faceIndex: Int32
    /// The face's clip planes, for the lookup's linear depth.
    var near: Float
    var far: Float
  }

  static let punctualFaceRotations: [Akari.Matrix4] = [
    Akari.Matrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
    Akari.Matrix4([0, 0, -1, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1]),
    Akari.Matrix4([0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1]),
    Akari.Matrix4([1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1]),
    Akari.Matrix4([-1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1]),
    Akari.Matrix4([1, 0, 0, 0, 0, -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1]),
  ]

  static func fitPunctual(lightPosition: SIMD3<Float>, near: Float, far: Float) -> [PunctualFace]
  {
    guard
      near > 1e-6,
      far > near
    else { return [] }

    let objectMat = Akari.Matrix4.translation(lightPosition)
    let inverseObjectMat = objectMat.inverse()
    let projectionMatrix = Akari.Matrix4.perspective(left: -near,
                                                     right: near,
                                                     bottom: -near,
                                                     top: near,
                                                     near: near,
                                                     far: far)

    return (0 ..< 6).map
    { face in
      let view = Self.punctualFaceRotations[face] * inverseObjectMat
      let viewProjection = projectionMatrix * view
      return PunctualFace(view: view,
                          projection: projectionMatrix,
                          viewProjection: viewProjection,
                          faceIndex: Int32(face),
                          near: near,
                          far: far)
    }
  }

  /// One cascade or clipmap level's light transform.
  struct Cascade
  {
    var view: Akari.Matrix4
    var projection: Akari.Matrix4
    var viewProjection: Akari.Matrix4
    var splitFar: Float
    var key: UInt64
    var absoluteLevel: Int32 = 0
    /// This slice's absolute integer tile grid position.
    var gridOffsetX: Int32 = 0
    var gridOffsetY: Int32 = 0

    var tileOffset: SIMD2<Float> = .zero
    var depthOffset: Float = 0
    var zScale: Float = 0
    var zBias: Float = 0
  }

  struct DirectionalFit
  {
    var cascades: [Cascade]
    var rotation: Akari.Matrix4
    var eyeToLightRotation: Akari.Matrix4 = .identity
    var refOffset: SIMD3<Float> = .zero
    var isClipmap: Bool
  }

  /// Coverage of a whole tilemap at `level`, in world units.
  static func coverageGet(_ level: Int) -> Float
  {
    exp2(Float(level))
  }

  static func resolveTechnique(camera: Akari.Camera) -> ShadowSettings.Technique
  {
    let a = camera.projection[2, 2]
    let isPerspective = abs(a - 1) > 1e-6 && abs(a + 1) > 1e-6
    return isPerspective ? .clipmap : .cascaded
  }

  static func fitCascades(camera: Akari.Camera,
                          lightDirection: SIMD3<Float>,
                          sceneCorners: [SIMD3<Float>],
                          settings: ShadowSettings) -> DirectionalFit
  {
    let projection = camera.projection
    let a = projection[2, 2]
    let b = projection[3, 2]
    let isPerspective = abs(a - 1) > 1e-6 && abs(a + 1) > 1e-6
    let clipNear: Float = isPerspective ? abs(b / (a - 1)) : 1e-3
    let clipFar: Float = min(isPerspective ? abs(b / (a + 1)) : 100, camera.world(meters: settings.maxDistance))

    let inverseView = camera.view.inverse()
    let cameraWorldPos = inverseView.transform(.zero)
    let cameraForward = Akari.Matrix.normalize(inverseView.transform(SIMD3(0, 0, -1)) - cameraWorldPos)

    let travel = Akari.Matrix.normalize(-lightDirection)
    let up = abs(travel.y) > 0.99 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
    let rotation = Akari.Matrix4.lookAt(eye: .zero, target: travel, up: up)

    let farPoint = rotation.transform(cameraWorldPos - cameraForward * clipFar)
    let nearPoint = rotation.transform(cameraWorldPos - cameraForward * clipNear)

    let maxTilemapPerShadows: Float = 16
    let dx = farPoint.x - nearPoint.x, dy = farPoint.y - nearPoint.y
    let depthRangeInShadowSpace = (dx * dx + dy * dy).squareRoot()
    guard
      depthRangeInShadowSpace.isFinite
    else { return DirectionalFit(cascades: [], rotation: rotation, isClipmap: false) }
    let minDepthTilemapSize = 2 * (depthRangeInShadowSpace / maxTilemapPerShadows)

    let px = projection[0, 0], py = projection[1, 1]
    let halfWidthNear = abs(px) > 1e-6 ? clipNear / px : clipNear
    let halfHeightNear = abs(py) > 1e-6 ? clipNear / py : clipNear
    let divisor: Float = isPerspective ? clipNear : 1
    var minDiagonalTilemapSize = 2 * (halfWidthNear * halfWidthNear
      + halfHeightNear * halfHeightNear).squareRoot() / max(divisor, 1e-6)
    if isPerspective { minDiagonalTilemapSize *= clipFar / clipNear }
    minDiagonalTilemapSize = max(minDiagonalTilemapSize, 0.5)

    let level = Int((log2(max(minDepthTilemapSize, minDiagonalTilemapSize)) + 0.5).rounded(.up))
    let perTilemapCoverage = Self.coverageGet(level) * 0.5
    guard
      perTilemapCoverage > 1e-6
    else { return DirectionalFit(cascades: [], rotation: rotation, isClipmap: false) }

    var tilemapLen = Int((0.5 + depthRangeInShadowSpace / perTilemapCoverage).rounded(.up))
    tilemapLen = max(1, min(tilemapLen, Self.maxDirectionalTilemaps))

    let halfSize = Self.coverageGet(level) / 2
    let tileSize = Self.coverageGet(level) / Float(Self.tilemapRes)

    let dirLen = (dx * dx + dy * dy).squareRoot()
    let localDirX = dirLen > 1e-6 ? dx / dirLen : 1
    let localDirY = dirLen > 1e-6 ? dy / dirLen : 0
    let farthestCenterX = localDirX * halfSize * Float(tilemapLen - 1)
    let farthestCenterY = localDirY * halfSize * Float(tilemapLen - 1)

    let originOffsetX = (nearPoint.x / tileSize).rounded()
    let originOffsetY = (nearPoint.y / tileSize).rounded()
    let offsetVectorX = (farthestCenterX / tileSize).rounded()
    let offsetVectorY = (farthestCenterY / tileSize).rounded()
    let denom = Float(max(tilemapLen - 1, 1))

    var sceneNear = Float.greatestFiniteMagnitude
    var sceneFar = -Float.greatestFiniteMagnitude
    for p in sceneCorners
    {
      let z = rotation.transform(p).z
      sceneNear = min(sceneNear, z)
      sceneFar = max(sceneFar, z)
    }

    guard
      sceneFar > sceneNear
    else { return DirectionalFit(cascades: [], rotation: rotation, isClipmap: false) }
    let margin = max((sceneFar - sceneNear) * 0.01, 1)
    let eyeDepth = sceneFar + margin
    let depthFar = sceneFar - sceneNear + 2 * margin

    var cascades: [Cascade] = []
    cascades.reserveCapacity(tilemapLen)
    for i in 0 ..< tilemapLen
    {
      let levelOffsetX = originOffsetX + (offsetVectorX * Float(i) / denom).rounded()
      let levelOffsetY = originOffsetY + (offsetVectorY * Float(i) / denom).rounded()
      let centerX = levelOffsetX * tileSize
      let centerY = levelOffsetY * tileSize

      let view = Akari.Matrix4.translation(SIMD3(-centerX, -centerY, -eyeDepth)) * rotation
      let projectionMatrix = Akari.Matrix4.ortho(left: -halfSize,
                                                 right: halfSize,
                                                 bottom: -halfSize,
                                                 top: halfSize,
                                                 near: margin,
                                                 far: depthFar)
      let viewProjection = projectionMatrix * view

      cascades.append(Cascade(view: view,
                              projection: projectionMatrix,
                              viewProjection: viewProjection,
                              splitFar: halfSize,
                              key: Self.fingerprint(viewProjection),
                              absoluteLevel: Int32(level + i),
                              gridOffsetX: Self.gridCoordinate(levelOffsetX),
                              gridOffsetY: Self.gridCoordinate(levelOffsetY)))
    }
    return DirectionalFit(cascades: cascades,
                          rotation: rotation,
                          eyeToLightRotation: rotation * inverseView,
                          refOffset: rotation.transform(-cameraForward * clipNear),
                          isClipmap: false)
  }

  static func quantize(_ direction: SIMD3<Float>) -> SIMD3<Float>
  {
    let quantStep: Float = 1.0 / 65536.0
    return SIMD3((direction.x / quantStep).rounded() * quantStep,
                 (direction.y / quantStep).rounded() * quantStep,
                 (direction.z / quantStep).rounded() * quantStep)
  }

  static func fitLevels(camera: Akari.Camera,
                        lightDirection: SIMD3<Float>,
                        sceneCorners: [SIMD3<Float>],
                        settings: ShadowSettings) -> DirectionalFit
  {
    let quantizedDirection = quantize(lightDirection)

    let travel = Akari.Matrix.normalize(-quantizedDirection)
    let up = abs(travel.y) > 0.99 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
    let rotation = Akari.Matrix4.lookAt(eye: .zero, target: travel, up: up)
    guard
      !sceneCorners.isEmpty
    else
    {
      return DirectionalFit(cascades: [], rotation: rotation, isClipmap: true)
    }

    var sceneNear = Float.greatestFiniteMagnitude
    var sceneFar = -Float.greatestFiniteMagnitude
    for p in sceneCorners
    {
      let lp = rotation.transform(p)
      sceneNear = min(sceneNear, lp.z)
      sceneFar = max(sceneFar, lp.z)
    }
    guard
      sceneFar > sceneNear
    else
    {
      return DirectionalFit(cascades: [], rotation: rotation, isClipmap: true)
    }

    let depthStep = exp2(ceil(log2(max(sceneFar - sceneNear, 1)))) / 8
    sceneNear = (sceneNear / depthStep).rounded(.down) * depthStep
    sceneFar = (sceneFar / depthStep).rounded(.up) * depthStep

    let margin = max((sceneFar - sceneNear) * 0.01, 1)
    let eyeDepth = sceneFar + margin
    let depthFar = sceneFar - sceneNear + 2 * margin

    let inverseView = camera.view.inverse()

    var boundsMin = sceneCorners[0], boundsMax = sceneCorners[0]
    for p in sceneCorners
    {
      boundsMin = pointwiseMin(boundsMin, p)
      boundsMax = pointwiseMax(boundsMax, p)
    }
    let clip = camera.clipRange(within: (boundsMin, boundsMax))
    let nearClip = camera.isPerspective ? clip.near : 1e-3
    let farClip = camera.isPerspective ? clip.far : 100

    let px = camera.projection[0, 0]
    let py = camera.projection[1, 1]
    let halfWidthNear = abs(px) > 1e-6 ? nearClip / px : nearClip
    let halfHeightNear = abs(py) > 1e-6 ? nearClip / py : nearClip
    let farScale = nearClip > 1e-6 ? farClip / nearClip : 1
    let corners = [
      SIMD3<Float>(-halfWidthNear, -halfHeightNear, -nearClip),
      SIMD3<Float>(halfWidthNear, -halfHeightNear, -nearClip),
      SIMD3<Float>(halfWidthNear, halfHeightNear, -nearClip),
      SIMD3<Float>(-halfWidthNear, halfHeightNear, -nearClip),
      SIMD3<Float>(-halfWidthNear * farScale, -halfHeightNear * farScale, -farClip),
      SIMD3<Float>(halfWidthNear * farScale, -halfHeightNear * farScale, -farClip),
      SIMD3<Float>(halfWidthNear * farScale, halfHeightNear * farScale, -farClip),
      SIMD3<Float>(-halfWidthNear * farScale, halfHeightNear * farScale, -farClip),
    ]
    var frustumCenter = SIMD3<Float>(repeating: 0)
    for c in corners
    {
      frustumCenter += c
    }
    frustumCenter /= 8
    var frustumRadius: Float = 0
    for c in corners
    {
      frustumRadius = max(frustumRadius, sqrt(Akari.Matrix.dot(c - frustumCenter, c - frustumCenter)))
    }
    let frustumCenterWorld = inverseView.transform(frustumCenter)

    let v = camera.view.simd
    let c0 = SIMD3(v.columns.0.x, v.columns.0.y, v.columns.0.z)
    let c1 = SIMD3(v.columns.1.x, v.columns.1.y, v.columns.1.z)
    let c2 = SIMD3(v.columns.2.x, v.columns.2.y, v.columns.2.z)
    let t = SIMD3(v.columns.3.x, v.columns.3.y, v.columns.3.z)
    let cameraWorldPos = SIMD3(
      -(Akari.Matrix.dot(c0, t)),
      -(Akari.Matrix.dot(c1, t)),
      -(Akari.Matrix.dot(c2, t))
    )
    let toFrustumCenter = frustumCenterWorld - cameraWorldPos
    let distanceToFrustumCenter = sqrt(Akari.Matrix.dot(toFrustumCenter, toFrustumCenter))

    let bias = Int(settings.levelLodBias.rounded())
    // finest a 1m level, however big the world unit.
    let metricLevel = Int(floor(log2(camera.world(meters: 1))))
    let minLevel = max(metricLevel, Int(floor(log2(max(nearClip, 1e-3))))) + bias
    var maxLevel = Int(ceil(log2(max(frustumRadius + distanceToFrustumCenter, 1)))) + bias
    maxLevel = max(minLevel, maxLevel) + 1

    let count = settings.resolvedLevelCount
    let usedMinLevel = max(minLevel, maxLevel - count + 1)

    let windowCenterLightPos = rotation.transform(cameraWorldPos)
    let depthOffset = windowCenterLightPos.z - eyeDepth
    let zScale = -2 / (depthFar - margin)
    let zBias = -(depthFar + margin) / (depthFar - margin)

    var levels: [Cascade] = []
    levels.reserveCapacity(count)

    for level in usedMinLevel ... maxLevel
    {
      let radius = exp2(Float(level)) / 2

      let tileSize = 2 * radius / Float(Self.tilemapRes)
      var center = windowCenterLightPos
      let gridX = (center.x / tileSize).rounded()
      let gridY = (center.y / tileSize).rounded()
      center.x = gridX * tileSize
      center.y = gridY * tileSize

      let tileOffset = SIMD2<Float>(windowCenterLightPos.x - center.x,
                                    windowCenterLightPos.y - center.y)

      let view = Akari.Matrix4.translation(SIMD3(-center.x, -center.y, -eyeDepth)) * rotation
      let projectionMatrix = Akari.Matrix4.ortho(left: -radius, right: radius,
                                                 bottom: -radius, top: radius,
                                                 near: margin, far: depthFar)
      let viewProjection = projectionMatrix * view

      levels.append(Cascade(view: view,
                            projection: projectionMatrix,
                            viewProjection: viewProjection,
                            splitFar: radius,
                            key: Self.fingerprint(viewProjection),
                            absoluteLevel: Int32(level),
                            gridOffsetX: Self.gridCoordinate(gridX),
                            gridOffsetY: Self.gridCoordinate(gridY),
                            tileOffset: tileOffset,
                            depthOffset: depthOffset,
                            zScale: zScale,
                            zBias: zBias))
    }

    return DirectionalFit(cascades: levels, rotation: rotation,
                          eyeToLightRotation: rotation * inverseView,
                          refOffset: .zero, isClipmap: true)
  }

  static func sceneCorners(_ bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> [SIMD3<Float>]
  {
    (0 ..< 8).map
    { i in
      SIMD3(i & 1 == 0 ? bounds.min.x : bounds.max.x,
            i & 2 == 0 ? bounds.min.y : bounds.max.y,
            i & 4 == 0 ? bounds.min.z : bounds.max.z)
    }
  }

  /// A tile grid coordinate as Int32, clamped inside what Float can represent.
  static func gridCoordinate(_ value: Float) -> Int32
  {
    guard value.isFinite else { return 0 }
    let bound = Float(1 << 30)
    return Int32(min(max(value, -bound), bound))
  }

  static func fingerprint(_ matrix: Akari.Matrix4) -> UInt64
  {
    var hasher = Hasher()
    withUnsafeBytes(of: matrix.simd) { hasher.combine(bytes: $0) }
    return UInt64(bitPattern: Int64(hasher.finalize()))
  }

  /// Fingerprints only a view matrix's rotation part.
  static func rotationOnlyFingerprint(_ matrix: Akari.Matrix4) -> UInt64
  {
    var rotationOnly = matrix.simd
    rotationOnly.columns.3 = SIMD4(0, 0, 0, rotationOnly.columns.3.w)
    return fingerprint(Akari.Matrix4(rotationOnly))
  }
}
