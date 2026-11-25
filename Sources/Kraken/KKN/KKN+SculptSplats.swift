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
import simd

extension Kraken
{
  /// the painterly strokes laid over a sculpt as gaussian splats, light baked in so any splat renderer shows the painting
  struct SculptSplats: Sendable
  {
    var positions: [SIMD3<Float>] = []
    var orientations: [simd_quatf] = []
    var scales: [SIMD3<Float>] = []
    var opacities: [Float] = []
    var colors: [SIMD3<Float>] = []

    /// the light and brush the strokes are painted with
    struct Look: Sendable
    {
      var light: SIMD3<Float>
      var warmth: Float
      var ambient: Float
      var rim: Float
      var size: Float
      var length: Float
      var density: Float
      var bands: Float
    }

    /// a cheap repeatable random number from a point
    @inline(__always)
    static func hash(_ p: SIMD3<Int32>) -> Float
    {
      var h = UInt32(bitPattern: p.x) &* 0x8DA6_B343 ^ UInt32(bitPattern: p.y) &* 0xD816_3841 ^ UInt32(bitPattern: p.z) &* 0xCB1A_B31F
      h ^= h >> 13
      h = h &* 0x5BD1_E995
      h ^= h >> 15
      return Float(h & 0xFFFF) / 65535
    }

    /// lights a color the way the painterly viewport does, value grouped into bands with a warm key and a cool fill
    static func shade(_ albedo: SIMD3<Float>, _ normal: SIMD3<Float>, look: Look, view: SIMD3<Float> = SIMD3(0, 0, 1)) -> SIMD3<Float>
    {
      let key = SIMD3<Float>(1, 0.93, 0.84) * (1 + look.warmth * 0.25)
      let fill = SIMD3<Float>(0.55, 0.65, 0.85)
      var lambert = max(simd_dot(normal, look.light) * 0.5 + 0.5, 0)
      lambert = lambert * lambert
      if look.bands > 1 { lambert = (lambert * look.bands).rounded(.down) / look.bands + 0.5 / look.bands }

      let rim = pow(1 - max(simd_dot(normal, view), 0), 3) * look.rim
      let sky = max(normal.y * 0.5 + 0.5, 0)
      return albedo * (key * lambert + fill * look.ambient * sky) + fill * rim * 0.35
    }

    /// strokes over a surface, spaced by the stroke size and turned to follow the form
    static func make(points: [SIMD3<Float>], normals: [SIMD3<Float>], colors: [SIMD4<UInt8>], voxel: Float, look: Look) -> SculptSplats
    {
      var out = SculptSplats()
      let size = max(look.size, voxel)
      let cell = size / max(look.density, 0.05)
      var taken: Set<SIMD3<Int32>> = []
      let up = SIMD3<Float>(0, 1, 0)

      for (i, p) in points.enumerated()
      {
        let key = SIMD3<Int32>(floor(p / cell))
        guard taken.insert(key).inserted else { continue }

        let n = simd_length(normals[i]) > 1e-6 ? simd_normalize(normals[i]) : up
        let jitter = (hash(key) - 0.5) * 1.2

        // strokes run around the form, across the up direction, with a little wander
        var tangent = simd_cross(n, up)
        if simd_length_squared(tangent) < 1e-4 { tangent = simd_cross(n, SIMD3(1, 0, 0)) }
        tangent = simd_normalize(tangent)
        tangent = simd_act(simd_quatf(angle: jitter, axis: n), tangent)
        let bitangent = simd_cross(n, tangent)
        let frame = simd_float3x3(columns: (tangent, bitangent, n))

        let byte = colors[i]
        let albedo = SculptUSD.linear(SIMD3(Float(byte.x) / 255, Float(byte.y) / 255, Float(byte.z) / 255))
        let variation = 0.92 + 0.16 * hash(key &+ 7)

        out.positions.append(p + n * voxel * 0.3)
        out.orientations.append(simd_quatf(frame))
        out.scales.append(SIMD3(size * look.length, size, size * 0.12) * (0.8 + 0.4 * hash(key &+ 3)))
        out.opacities.append(0.9)
        out.colors.append(simd_clamp(shade(albedo, n, look: look) * variation, .zero, SIMD3(repeating: 1)))
      }

      return out
    }
  }
}

extension Kraken.Sculpt
{
  /// the light direction from the angle and height sliders, in the sculpt's y up space
  var lightDirection: SIMD3<Float>
  {
    let a = Float(lightAngle) * .pi / 180, h = Float(lightHeight) * .pi / 180
    return simd_normalize(SIMD3(sin(a) * cos(h), sin(h), cos(a) * cos(h)))
  }

  /// the look the written splats are baked with
  var splatLook: Kraken.SculptSplats.Look
  {
    Kraken.SculptSplats.Look(light: lightDirection, warmth: Float(warmth), ambient: Float(ambient), rim: Float(rim),
                             size: volume.voxel * Float(strokeSize) * 0.35, length: Float(strokeLength),
                             density: Float(strokeDensity), bands: Float(bands))
  }
}
