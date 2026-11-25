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

// the deferred graph's buffers, each enum case one texture in attachment order.

extension Akari.RenderGraph
{
  enum GBuffer: String, RenderBuffer
  {
    case diffuse, position, normal, material, velocity, specular, ptexA, ptexB

    static let name = "gbuffer"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format
    {
      switch self
      {
        case .diffuse, .normal, .material: .f16x4
        case .position: .f32x4
        case .velocity: .f16x2
        // what the surface reflects facing the eye while it is not a metal, eight bits a channel
        case .specular: .u8x4
        case .ptexA, .ptexB: .i32x1
      }
    }
  }

  enum EnvCubeBuffer: String, RenderBuffer
  {
    case envCube

    static let name = "envCube"
    static var options: BufferOptions { .init(depth: nil, mips: true, textureDepth: false, size: [256, 256], cube: true, mipLevels: 9) }
  }

  enum DomeBuffer: String, RenderBuffer
  {
    case dome

    static let name = "dome"
    static var options: BufferOptions { .init(depth: nil, mips: false, textureDepth: false, size: [1024, 512]) }
  }

  enum ColorBuffer: String, RenderBuffer
  {
    case `final`

    static let name = "color"
  }

  /// the nearest surface facing away at each pixel, giving reflections the far side of what the camera sees
  enum BackGBuffer: String, RenderBuffer
  {
    case backDiffuse, backPosition, backNormal, backMaterial

    static let name = "backGbuffer"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format { self == .backPosition ? .f32x4 : .f16x4 }
  }

  /// the closest depth under each texel of half resolution depth, five levels side by side, so reflection rays skip whole cells
  enum HizBuffer: String, RenderBuffer
  {
    case hiz

    static let name = "hiz"

    var format: Format { .f32x1 }

    var scale: Double? { 0.5 }
  }

  enum SsgiPrepBuffer: String, RenderBuffer
  {
    case ssgiDepth, ssgiNormal, ssgiRadiance

    static let name = "ssgiPrep"

    var format: Format
    {
      switch self
      {
        case .ssgiDepth: .f32x1
        case .ssgiNormal, .ssgiRadiance: .f16x4
      }
    }

    var scale: Double? { 0.5 }
  }

  enum SsgiPyramidBuffer: String, RenderBuffer
  {
    case ssgiPyramidDepth, ssgiPyramidNormal, ssgiPyramidRadiance

    static let name = "ssgiPyramid"

    var format: Format
    {
      switch self
      {
        case .ssgiPyramidDepth: .f32x1
        case .ssgiPyramidNormal, .ssgiPyramidRadiance: .f16x4
      }
    }

    var scale: Double? { 0.5 }
  }

  enum SsgiBuffer: String, RenderBuffer
  {
    case ssgiRaw, ssgiSpecRaw, ssgiBentRaw

    static let name = "ssgi"

    var scale: Double? { 0.5 }
  }

  enum SsgiAccumBuffer: String, RenderBuffer
  {
    case ssgiAccum, ssgiSpecAccum, ssgiBentAccum

    static let name = "ssgiAccum"

    var scale: Double? { 0.5 }
  }

  enum SsgiHistoryBuffer: String, RenderBuffer
  {
    case ssgiHistory, ssgiSpecHistory, ssgiBentHistory

    static let name = "ssgiHistory"
    static var options: BufferOptions { .init(latency: .ring(2)) }

    var scale: Double? { 0.5 }
  }

  enum PointShadowRawBuffer: String, RenderBuffer
  {
    case pointShadowRaw0, pointShadowRaw1, pointShadowRaw2, pointShadowRaw3, pointShadowGuide

    static let name = "pointShadowRaw"

    var scale: Double? { 0.5 }
  }

  enum PointShadowBlurBuffer: String, RenderBuffer
  {
    case pointShadowBlur0, pointShadowBlur1, pointShadowBlur2, pointShadowBlur3

    static let name = "pointShadowBlur"

    var scale: Double? { 0.5 }
  }

  enum PointShadowBuffer: String, RenderBuffer
  {
    case pointShadow0, pointShadow1, pointShadow2, pointShadow3

    static let name = "pointShadow"

    var scale: Double? { 0.5 }
  }

  enum VolumeScatterBuffer: String, RenderBuffer
  {
    case volumeScatter

    static let name = "volumeScatter"

    var scale: Double? { 0.5 }
  }

  enum VolumeIntegratedBuffer: String, RenderBuffer
  {
    case volumeIntegrated

    static let name = "volumeIntegrated"

    var scale: Double? { 0.5 }
  }

  enum SsrBuffer: String, RenderBuffer
  {
    case ssrRadiance, ssrGuide, ssrMotion, ssrRay

    static let name = "ssr"

    var scale: Double? { 0.5 }

    // motion holds where the reflected image was last frame and how far the reflected surface moved on its own, ray each ray's direction and odds
    var format: Format { .f16x4 }
  }

  /// each pixel's reflection rebuilt from its own and its neighbours' rays
  enum SsrResolveBuffer: String, RenderBuffer
  {
    case ssrResolved

    static let name = "ssrResolve"

    var scale: Double? { 0.5 }
  }

  enum SsrAccumBuffer: String, RenderBuffer
  {
    case ssrAccum, ssrMotionMemory

    static let name = "ssrAccum"

    var scale: Double? { 0.5 }

    // the memory fades how much the reflection moved here lately, so a trail left behind clears as fast as it formed
    var format: Format { self == .ssrMotionMemory ? .f16x1 : .f16x4 }
  }

  enum SsrHistoryBuffer: String, RenderBuffer
  {
    case ssrHistory, ssrGuideHistory, ssrMotionHistory

    static let name = "ssrHistory"
    static var options: BufferOptions { .init(latency: .ring(2)) }

    var format: Format { self == .ssrMotionHistory ? .f16x1 : .f16x4 }

    var scale: Double? { 0.5 }
  }

  enum SunShadowRawBuffer: String, RenderBuffer
  {
    case sunShadowRaw

    static let name = "sunShadowRaw"

    var format: Format { .f16x2 }
  }

  enum SunShadowAccumBuffer: String, RenderBuffer
  {
    case sunShadowAccum

    static let name = "sunShadowAccum"
  }

  enum SunShadowHistoryBuffer: String, RenderBuffer
  {
    case sunShadowHistory

    static let name = "sunShadowHistory"
    static var options: BufferOptions { .init(latency: .ring(2)) }
  }

  enum SunShadowBlurBuffer: String, RenderBuffer
  {
    case sunShadowBlurH

    static let name = "sunShadowBlur"

    var format: Format { .f16x2 }
  }

  enum SunShadowSoftBuffer: String, RenderBuffer
  {
    case sunShadowSoft

    static let name = "sunShadowSoft"

    var format: Format { .f16x1 }
  }

  /// the nearest glass each glass light sees, its position, distance and normal in the light's atlas tile
  enum GlassNearBuffer: String, RenderBuffer
  {
    case glassNear, glassNearNormal

    static let name = "glassNear"
    static var options: BufferOptions { .init(depth: true, size: [GlassAtlas.width, GlassAtlas.height]) }

    var format: Format { self == .glassNear ? .f32x4 : .f16x4 }
    var scale: Double? { nil }
  }

  /// the farthest glass each glass light sees, its distance from the light and its normal, where light leaves the glass.
  enum GlassFarBuffer: String, RenderBuffer
  {
    case glassFar, glassFarNormal

    static let name = "glassFar"
    static var options: BufferOptions { .init(depth: true, size: [GlassAtlas.width, GlassAtlas.height]) }

    var format: Format { self == .glassFar ? .f32x1 : .f16x4 }
    var scale: Double? { nil }
  }

  /// the optical depth of all the glass between each texel and its light, in color.
  enum GlassTransmitBuffer: String, RenderBuffer
  {
    case glassTransmit

    static let name = "glassTransmit"
    static var options: BufferOptions { .init(depth: true, size: [GlassAtlas.width, GlassAtlas.height]) }

    var format: Format { .f16x4 }
    var scale: Double? { nil }
  }

  /// the sun light glass refracts onto the gbuffer's surfaces, as a share of the sun since the shading colors it
  enum GlassSunCausticBuffer: String, RenderBuffer
  {
    case glassSunCaustic

    static let name = "glassSunCaustic"
  }

  /// the irradiance every local light refracts through glass onto the g-buffer's surfaces, added up.
  enum GlassLocalCausticBuffer: String, RenderBuffer
  {
    case glassLocalCaustic

    static let name = "glassLocalCaustic"
  }

  /// the caustics blended over the last frames for the viewport, with depth in a
  enum GlassCausticAccumBuffer: String, RenderBuffer
  {
    case glassSunCausticAccum, glassLocalCausticAccum

    static let name = "glassCausticAccum"
  }

  /// last frame's blended caustics
  enum GlassCausticHistoryBuffer: String, RenderBuffer
  {
    case glassSunCausticHistory, glassLocalCausticHistory

    static let name = "glassCausticHistory"
    static var options: BufferOptions { .init(latency: .ring(2)) }
  }

  enum TaaBuffer: String, RenderBuffer
  {
    case `final`

    static let name = "taa"
  }

  enum UpscaleInputBuffer: String, RenderBuffer
  {
    case upscaleColor, upscaleVelocity

    static let name = "upscaleInput"

    var format: Format
    {
      switch self
      {
        case .upscaleColor: .f16x4
        case .upscaleVelocity: .f16x2
      }
    }
  }

  enum SupersampleBuffer: String, RenderBuffer
  {
    case supersample

    static let name = "supersample"
  }

  enum HistoryBuffer: String, RenderBuffer
  {
    case history

    static let name = "history"
    static var options: BufferOptions { .init(latency: .ring(2)) }
  }

  enum TonemapBuffer: String, RenderBuffer
  {
    case tonemap

    static let name = "tonemap"
  }

  enum OutlineMaskBuffer: String, RenderBuffer
  {
    case outlineMask

    static let name = "outlineMask"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format { .f32x2 }
  }

  enum OutlineEdgeBuffer: String, RenderBuffer
  {
    case outlineEdge

    static let name = "outlineEdge"

    var format: Format { .f32x2 }
  }

  enum OutlineSpanBuffer: String, RenderBuffer
  {
    case outlineSpan

    static let name = "outlineSpan"

    var format: Format { .f32x2 }
  }

  enum OutlineBuffer: String, RenderBuffer
  {
    case outline

    static let name = "outline"
  }

  enum AovBuffer: String, RenderBuffer
  {
    case aovPrimId, aovInstanceId, aovDepth

    static let name = "aov"

    var format: Format
    {
      switch self
      {
        case .aovPrimId, .aovInstanceId: .i32x1
        case .aovDepth: .f32x1
      }
    }
  }

  enum VolumeShadowBuffer: String, RenderBuffer
  {
    case volumeShadow

    static let name = "volumeShadow"
    static var options: BufferOptions { .init(size: [2048, 1024]) }

    var scale: Double? { nil }
  }

  enum MotionTiles8Buffer: String, RenderBuffer
  {
    case motionTile8

    static let name = "motionTiles8"
  }

  enum MotionTilesBuffer: String, RenderBuffer
  {
    case motionTileMax

    static let name = "motionTiles"
  }

  enum MotionNeighborsBuffer: String, RenderBuffer
  {
    case motionNeighborMax

    static let name = "motionNeighbors"
  }

  enum MotionBlurBuffer: String, RenderBuffer
  {
    case motionBlurred

    static let name = "motionBlur"
  }

  enum BloomDown0Buffer: String, RenderBuffer
  {
    case bloomDown0

    static let name = "bloomDown0"

    var scale: Double? { 0.5 }
  }

  enum BloomDown1Buffer: String, RenderBuffer
  {
    case bloomDown1

    static let name = "bloomDown1"

    var scale: Double? { 0.25 }
  }

  enum BloomDown2Buffer: String, RenderBuffer
  {
    case bloomDown2

    static let name = "bloomDown2"

    var scale: Double? { 0.125 }
  }

  enum BloomDown3Buffer: String, RenderBuffer
  {
    case bloomDown3

    static let name = "bloomDown3"

    var scale: Double? { 0.0625 }
  }

  enum BloomDown4Buffer: String, RenderBuffer
  {
    case bloomDown4

    static let name = "bloomDown4"

    var scale: Double? { 0.03125 }
  }

  enum BloomDown5Buffer: String, RenderBuffer
  {
    case bloomDown5

    static let name = "bloomDown5"

    var scale: Double? { 0.015625 }
  }

  enum BloomUp0Buffer: String, RenderBuffer
  {
    case bloomUp0

    static let name = "bloomUp0"

    var scale: Double? { 0.5 }
  }

  enum BloomUp1Buffer: String, RenderBuffer
  {
    case bloomUp1

    static let name = "bloomUp1"

    var scale: Double? { 0.25 }
  }

  enum BloomUp2Buffer: String, RenderBuffer
  {
    case bloomUp2

    static let name = "bloomUp2"

    var scale: Double? { 0.125 }
  }

  enum BloomUp3Buffer: String, RenderBuffer
  {
    case bloomUp3

    static let name = "bloomUp3"

    var scale: Double? { 0.0625 }
  }

  enum BloomUp4Buffer: String, RenderBuffer
  {
    case bloomUp4

    static let name = "bloomUp4"

    var scale: Double? { 0.03125 }
  }

  enum LensStreakBuffer: String, RenderBuffer
  {
    case lensStreakA, lensStreakB

    static let name = "lensStreak"

    var scale: Double? { 0.25 }
  }

  enum LensStreakWideBuffer: String, RenderBuffer
  {
    case lensStreakWide

    static let name = "lensStreakWide"

    var scale: Double? { 0.25 }
  }

  enum LensGhostsBuffer: String, RenderBuffer
  {
    case lensGhosts

    static let name = "lensGhosts"

    var scale: Double? { 0.25 }
  }

  enum FogSimHalfBuffer: String, RenderBuffer
  {
    case fogSimHalf

    static let name = "fogSimHalf"

    var scale: Double? { 0.5 }
  }

  enum DofBuffer: String, RenderBuffer
  {
    case dofColor

    static let name = "dof"
  }

  enum DofDepthBuffer: String, RenderBuffer
  {
    case dofDepth

    static let name = "dofDepth"

    var format: Format { .f32x1 }
  }

  enum DofTiles8Buffer: String, RenderBuffer
  {
    case dofTile8

    static let name = "dofTiles8"
  }

  enum DofTilesBuffer: String, RenderBuffer
  {
    case dofTileMax

    static let name = "dofTiles"
  }

  enum DofNeighborsBuffer: String, RenderBuffer
  {
    case dofNeighborMax

    static let name = "dofNeighbors"
  }

  enum DofHalfSourceBuffer: String, RenderBuffer
  {
    case dofHalfSource

    static let name = "dofHalfSource"

    var scale: Double? { 0.5 }
  }

  enum DofHalfBuffer: String, RenderBuffer
  {
    case dofHalfColor

    static let name = "dofHalf"

    var scale: Double? { 0.5 }
  }

  enum TransparentAccumBuffer: String, RenderBuffer
  {
    case tColor, tReflect, tTransmit, tOffset, tDepth, tVelocity

    static let name = "transparentAccum"
    static var options: BufferOptions { .init(depth: true) }
  }

  /// the glass nearest the camera at each pixel, its eye position with w one past its prim id where there is glass, and its normal
  enum GlassFrontBuffer: String, RenderBuffer
  {
    case glassFront, glassFrontNormal

    static let name = "glassFront"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format { self == .glassFront ? .f32x4 : .f16x4 }
  }

  /// the glass farthest from the camera at each pixel, where a view ray leaves it.
  enum GlassBackBuffer: String, RenderBuffer
  {
    case glassBack, glassBackNormal

    static let name = "glassBack"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format { self == .glassBack ? .f32x4 : .f16x4 }
  }

  /// the next glass behind the nearest at each pixel, laid out like the nearest
  enum GlassBehindFrontBuffer: String, RenderBuffer
  {
    case glassBehindFront, glassBehindFrontNormal

    static let name = "glassBehindFront"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format { self == .glassBehindFront ? .f32x4 : .f16x4 }
  }

  /// the far side of the next glass behind the nearest
  enum GlassBehindBackBuffer: String, RenderBuffer
  {
    case glassBehindBack, glassBehindBackNormal

    static let name = "glassBehindBack"
    static var options: BufferOptions { .init(depth: true) }

    var format: Format { self == .glassBehindBack ? .f32x4 : .f16x4 }
  }

  /// the transparent surfaces behind the nearest glass, summed the same way as the whole accumulation
  enum TransparentBehindBuffer: String, RenderBuffer
  {
    case bColor, bReflect, bTransmit

    static let name = "transparentBehind"
    static var options: BufferOptions { .init(depth: true) }
  }

  /// everything behind the nearest glass already composited, which the nearest glass then bends
  enum TransparentBehindResolvedBuffer: String, RenderBuffer
  {
    case tBehind

    static let name = "transparentBehindResolved"
  }

  enum TransparentResolvedBuffer: String, RenderBuffer
  {
    case tResolved, tSurface

    static let name = "transparentResolved"
  }

  enum AtmosTransmittanceBuffer: String, RenderBuffer
  {
    case atmosTransmittance

    static let name = "atmosTransmittance"
    static var options: BufferOptions { .init(size: [256, 64]) }

    var scale: Double? { nil }
  }

  enum AtmosMultiScatterBuffer: String, RenderBuffer
  {
    case atmosMultiScatter, atmosIrradiance

    static let name = "atmosMultiScatter"
    static var options: BufferOptions { .init(size: [32, 32]) }

    var scale: Double? { nil }
  }

  enum AtmosSkyViewBuffer: String, RenderBuffer
  {
    case atmosSkyView

    static let name = "atmosSkyView"
    static var options: BufferOptions { .init(size: [192, 108]) }

    var scale: Double? { nil }
  }

  enum PlanetCloudMapBuffer: String, RenderBuffer
  {
    case planetCloudMap

    static let name = "planetCloudMap"
    static var options: BufferOptions { .init(size: [4096, 2048]) }

    var format: Format { .f16x1 }

    var scale: Double? { nil }
  }

  enum AtmosAerialBuffer: String, RenderBuffer
  {
    case atmosAerial

    static let name = "atmosAerial"
    static var options: BufferOptions { .init(size: [256, 128]) }

    var scale: Double? { nil }
  }

  // image based lighting textures labfx adds on its own, declared for pass inputs but never written out.

  enum DfgBuffer: String, RenderBuffer
  {
    case dfg

    static let name = "dfg"
  }

  enum IrradianceBuffer: String, RenderBuffer
  {
    case irradiance

    static let name = "irradiance"
  }

  enum PrefilteredBuffer: String, RenderBuffer
  {
    case prefiltered

    static let name = "prefiltered"
  }

  /// the bloom chain's levels, finest first.
  static let bloomDown: [TextureRef] = [
    BloomDown0Buffer.bloomDown0.ref, BloomDown1Buffer.bloomDown1.ref, BloomDown2Buffer.bloomDown2.ref,
    BloomDown3Buffer.bloomDown3.ref, BloomDown4Buffer.bloomDown4.ref, BloomDown5Buffer.bloomDown5.ref,
  ]

  static let bloomUp: [TextureRef] = [
    BloomUp0Buffer.bloomUp0.ref, BloomUp1Buffer.bloomUp1.ref, BloomUp2Buffer.bloomUp2.ref,
    BloomUp3Buffer.bloomUp3.ref, BloomUp4Buffer.bloomUp4.ref,
  ]
}
