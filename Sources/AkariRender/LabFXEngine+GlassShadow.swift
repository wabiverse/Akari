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
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// where one glass light's maps sit this frame, used by its maps, caustic trace and splat
  struct GlassFrame
  {
    /// the light's tile in the glass atlases, see `GlassAtlas`
    var tile: Int
    var matrix: Akari.Matrix4

    /// the direction toward the sun with w 0, or the local light's position with w 1
    var light: SIMD4<Float>

    /// the tangent of the sun's angular radius or the local light's radius, which blurs its caustics
    var size: Float

    /// how far a light bundle travels past the glass looking for somewhere to land
    var reach: Float

    /// a local light's color and intensity in rgb and its squared reach in w, 0 for the sun
    var strength: SIMD4<Float> = .zero

    /// a local light's emitting shape that its caustics sample a point of each frame
    var shape: (x: SIMD4<Float>, y: SIMD4<Float>) = (.zero, .zero)
  }

  /// the glass atlases and gbuffer textures the caustic trace reads, looked up before the graph runs
  struct GlassTextures
  {
    var near: (surface: GLuint, normal: GLuint) = (0, 0)
    var far: (surface: GLuint, normal: GLuint) = (0, 0)
    var transmit: GLuint = 0
    var gbuffer: (position: GLuint, normal: GLuint) = (0, 0)
  }

  /// fits glass maps around transparent meshes for the sun and each shadowed light that reaches them, a tile each
  func applyGlassShadow(sun: SIMD3<Float>, sunAngle: Float, castsShadows: Bool)
  {
    typealias Atlas = Akari.RenderGraph.GlassAtlas

    let glass = castsShadows ? geometry.deformer.glassBounds : []
    var frames: [GlassFrame] = []
    var slots: UInt32 = 0
    if !glass.isEmpty
    {
      let reach = Self.glassReach(glass)
      if let matrix = Self.sunGlassMatrix(glass, toSun: sun)
      {
        frames.append(GlassFrame(tile: Atlas.sunTile, matrix: matrix, light: SIMD4(simd_normalize(sun), 0),
                                 size: tan(sunAngle), reach: reach))
      }

      // shadowed lights come first in slot order and only they shadow the glass besides the sun
      for (slot, light) in pointLights.shadowed.prefix(Atlas.localLights).enumerated()
      {
        let lightReach = Self.shadingReach(light)
        guard
          lightReach > 0, Self.distanceSquared(glass, to: light.position) < lightReach,
          let matrix = Self.localGlassMatrix(glass, from: light.position)
        else { continue }

        let strength = light.color * light.intensity * .pi * light.radius * light.radius
        frames.append(GlassFrame(tile: Atlas.localTile(slot: slot), matrix: matrix, light: SIMD4(light.position, 1),
                                 size: Self.extent(light), reach: reach, strength: SIMD4(strength, lightReach),
                                 shape: Self.shape(light)))
        slots |= 1 << UInt32(slot)
      }
    }

    let hasSun = frames.contains { $0.tile == Atlas.sunTile }

    // the view through the glass is traced whenever there is glass, lit or not
    let lens = geometry.deformer.hasGlass && !geometry.dynamicBatch.isEmpty

    // a still shot keeps the maps, views and caustics it has while the glass, lights, view and scene stay put
    let key = causticKey(frames)
    let moving = key != transparency.causticKey

    // a frame is only kept once it was drawn in full, so a still shot never holds a reduced one
    let held = transparency.causticsTraced && !moving && transparency.causticsFull
    if !held { transparency.causticsFull = !moving }
    transparency.causticKey = key
    transparency.causticsTraced = transparency.causticsTraced || !frames.isEmpty

    setGlassPasses([.glassFrontView, .glassBackView, .glassBehindFrontView, .glassBehindBackView], active: lens && !held)

    // what lies behind the glass changes with the frame even when the glass holds still
    setGlassPasses([.transparentBehind, .transparentBehindComposite], active: lens)
    setGlassPasses([.glassNear, .glassFar, .glassTransmit], active: !frames.isEmpty && !held)
    setGlassPasses([.glassSunTrace, .glassSunCaustics], active: hasSun && !held)
    setGlassPasses([.glassLocalTrace, .glassLocalCaustics], active: slots != 0 && !held)

    // the blend over frames runs while there are caustics, held ones too, so a still view settles on them
    setGlassPasses([.glassCausticTemporal, .glassCausticHistory], active: hasSun || slots != 0)
    setVector(.glass, SIMD4(hasSun ? 1 : 0, slots != 0 ? 1 : 0, lens ? 1 : 0, 0))

    uploadGlassLights(frames)

    if !frames.isEmpty
    {
      transparency.glassTextures = GlassTextures(
        near: (texture(Akari.RenderGraph.GlassNearBuffer.glassNear.ref), texture(Akari.RenderGraph.GlassNearBuffer.glassNearNormal.ref)),
        far: (texture(Akari.RenderGraph.GlassFarBuffer.glassFar.ref), texture(Akari.RenderGraph.GlassFarBuffer.glassFarNormal.ref)),
        transmit: texture(Akari.RenderGraph.GlassTransmitBuffer.glassTransmit.ref),
        gbuffer: (texture(Akari.RenderGraph.GBuffer.position.ref), texture(Akari.RenderGraph.GBuffer.normal.ref)))
    }

    transparency.glass = frames
    glassMaps.upload(frames)
    glassCaustics.advance()

    // every other light shadows the glass through the shadow maps
    shadowAtlas.glassSun = hasSun
    shadowAtlas.glassSlots = slots
  }

  /// forgets the glass views and caustics so the next frame draws them again after the buffers are rebuilt
  func forgetGlassViews()
  {
    transparency.causticKey = 0
    transparency.causticsFull = false
  }

  private func causticKey(_ frames: [GlassFrame]) -> UInt64
  {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ value: UInt64)
    {
      hash = (hash ^ value) &* 0x100_0000_01b3
    }

    func mix(_ value: Float) { mix(UInt64(value.bitPattern)) }
    func mix(_ value: SIMD4<Float>) { for lane in 0 ..< 4 { mix(value[lane]) } }
    func mix(_ value: Akari.Matrix4) { value.withUnsafeFloats { for float in $0 { mix(float) } } }

    mix(lastGeometryRevision)
    mix(UInt64(frames.count))
    for frame in frames
    {
      mix(UInt64(frame.tile))
      mix(frame.matrix)
      mix(frame.light)
      mix(frame.size)
      mix(frame.reach)
      mix(frame.strength)
      mix(frame.shape.x)
      mix(frame.shape.y)
    }

    mix(transparency.view)
    mix(transparency.projection.simd[0][0])
    mix(transparency.projection.simd[1][1])
    mix(UInt64(sizes.half.width))
    mix(UInt64(sizes.half.height))

    return hash
  }

  private func setGlassPasses(_ passes: [Pass], active: Bool)
  {
    for pass in passes where transparency.glassPassesActive[pass] != active
    {
      runtime.setPassActive(pass, active: active)
      transparency.glassPassesActive[pass] = active
    }
  }

  /// each glass light's map matrix, whether it ran, its size and its light, one row per tile for the lighting pass
  private func uploadGlassLights(_ frames: [GlassFrame])
  {
    typealias Atlas = Akari.RenderGraph.GlassAtlas

    if transparency.glassLights == 0
    {
      gl.genTextures(count: 1, textures: &transparency.glassLights)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: transparency.glassLights)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F,
                    width: GLsizei(Atlas.dataWidth), height: GLsizei(Atlas.tiles), border: 0,
                    format: GL_RGBA, type: GL_FLOAT, pixels: nil)
    }

    guard transparency.glassLights != 0 else { return }

    let stride = Atlas.dataWidth * 4
    var texels = [Float](repeating: 0, count: Atlas.tiles * stride)
    for frame in frames
    {
      let row = frame.tile * stride
      frame.matrix.withUnsafeFloats { floats in for i in 0 ..< 16 { texels[row + i] = floats[i] } }
      texels[row + 16] = 1
      texels[row + 17] = frame.size
      for i in 0 ..< 4 { texels[row + 20 + i] = frame.light[i] }
    }

    gl.bindTexture(target: GL_TEXTURE_2D, texture: transparency.glassLights)
    gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: 0, yOffset: 0,
                     width: GLsizei(Atlas.dataWidth), height: GLsizei(Atlas.tiles),
                     format: GL_RGBA, type: GL_FLOAT, pixels: texels)
    setSampler(.glassLights, transparency.glassLights)
  }

  /// the squared distance a point light reaches before the lighting pass stops shading it
  private static func shadingReach(_ light: Akari.Lux.PointLight) -> Float
  {
    guard light.intensity > 0, light.color.max() > 0 else { return 0 }
    return light.radius * light.radius * light.intensity * light.color.max() * 1000
  }

  /// how far a light reaches from its center, it softens glass shadows and caustics like light size softens opaque shadows
  private static func extent(_ light: Akari.Lux.PointLight) -> Float
  {
    let tube = simd_length(light.halfAxis) + light.tubeRadius
    let rect = simd_length(light.halfWidth + light.halfHeight)
    return max(light.radius, tube, rect)
  }

  /// a light's emitting shape for its caustics, see `GlassFrame.shape`
  private static func shape(_ light: Akari.Lux.PointLight) -> (x: SIMD4<Float>, y: SIMD4<Float>)
  {
    if light.halfWidth != .zero { return (SIMD4(light.halfWidth, 0), SIMD4(light.halfHeight, 0)) }
    if light.halfAxis != .zero { return (SIMD4(light.halfAxis, light.tubeRadius), .zero) }
    return (SIMD4(0, 0, 0, light.radius), .zero)
  }

  /// the squared distance from `point` to the nearest of `bounds`
  private static func distanceSquared(_ bounds: [(min: SIMD3<Float>, max: SIMD3<Float>)], to point: SIMD3<Float>) -> Float
  {
    bounds.map { simd_distance_squared(point, simd_clamp(point, $0.min, $0.max)) }.min() ?? .greatestFiniteMagnitude
  }

  /// how far past the glass light bundles look for a surface, a few times the size of the glass
  private static func glassReach(_ glass: [(min: SIMD3<Float>, max: SIMD3<Float>)]) -> Float
  {
    let lo = glass.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { pointwiseMin($0, $1.min) }
    let hi = glass.reduce(-SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { pointwiseMax($0, $1.max) }
    return simd_length(hi - lo) * 4
  }

  /// every corner of `bounds`
  private static func corners(_ bounds: [(min: SIMD3<Float>, max: SIMD3<Float>)]) -> [SIMD3<Float>]
  {
    bounds.flatMap
    { box in
      (0 ..< 8).map
      { corner in
        SIMD3(corner & 1 == 0 ? box.min.x : box.max.x,
              corner & 2 == 0 ? box.min.y : box.max.y,
              corner & 4 == 0 ? box.min.z : box.max.z)
      }
    }
  }

  /// a basis whose z is `forward` with x and y across it
  private static func basis(facing forward: SIMD3<Float>) -> (right: SIMD3<Float>, up: SIMD3<Float>)
  {
    let helper: SIMD3<Float> = abs(forward.y) < 0.99 ? [0, 1, 0] : [1, 0, 0]
    let right = simd_normalize(simd_cross(helper, forward))
    return (right, simd_cross(forward, right))
  }

  /// an orthographic box around the glass facing the sun, nearest glass at depth 1 for the reversed depth test
  static func sunGlassMatrix(_ glass: [(min: SIMD3<Float>, max: SIMD3<Float>)], toSun sun: SIMD3<Float>) -> Akari.Matrix4?
  {
    guard simd_length_squared(sun) > 0 else { return nil }

    let toSun = simd_normalize(sun)
    let (right, up) = basis(facing: toSun)

    // x and y across the light, z is the distance along it away from the sun
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    for corner in corners(glass)
    {
      let local = SIMD3(simd_dot(corner, right), simd_dot(corner, up), -simd_dot(corner, toSun))
      lo = pointwiseMin(lo, local)
      hi = pointwiseMax(hi, local)
    }

    let pad = (hi - lo) * 0.02 + 1e-3
    lo -= pad
    hi += pad
    let extent = hi - lo
    guard extent.x.isFinite, extent.y.isFinite, extent.z.isFinite else { return nil }

    let scale = SIMD3(2 / extent.x, 2 / extent.y, 1 / extent.z)
    return Akari.Matrix4(simd_float4x4(rows: [
      SIMD4(right * scale.x, -lo.x * scale.x - 1),
      SIMD4(up * scale.y, -lo.y * scale.y - 1),
      SIMD4(toSun * scale.z, 1 + lo.z * scale.z),
      SIMD4<Float>(0, 0, 0, 1),
    ]))
  }

  /// a square frustum from `position` just wide enough for the glass with reversed depth, nil when the glass is beside or behind the light
  static func localGlassMatrix(_ glass: [(min: SIMD3<Float>, max: SIMD3<Float>)], from position: SIMD3<Float>) -> Akari.Matrix4?
  {
    let points = corners(glass)
    let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
    guard simd_distance_squared(center, position) > 1e-8 else { return nil }

    let forward = simd_normalize(center - position)
    let (right, up) = basis(facing: forward)

    var near = Float.greatestFiniteMagnitude
    var spread: Float = 0
    for point in points
    {
      let offset = point - position
      let depth = simd_dot(offset, forward)
      guard depth > 1e-4 else { return nil }
      near = min(near, depth)
      spread = max(spread, max(abs(simd_dot(offset, right)), abs(simd_dot(offset, up))) / depth)
    }

    // past about 75 degrees off axis the map would stretch the glass too thin to be worth drawing
    guard spread < 4 else { return nil }

    let tanHalf = spread * 1.05 + 1e-3
    near *= 0.9

    let view = simd_float4x4(rows: [
      SIMD4(right, -simd_dot(right, position)),
      SIMD4(up, -simd_dot(up, position)),
      SIMD4(-forward, simd_dot(forward, position)),
      SIMD4<Float>(0, 0, 0, 1),
    ])
    let projection = simd_float4x4(rows: [
      SIMD4<Float>(1 / tanHalf, 0, 0, 0),
      SIMD4<Float>(0, 1 / tanHalf, 0, 0),
      SIMD4<Float>(0, 0, 0, near),
      SIMD4<Float>(0, 0, -1, 0),
    ])

    return Akari.Matrix4(projection * view)
  }
}
