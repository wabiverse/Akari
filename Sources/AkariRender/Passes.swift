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
import HdAkari

public extension Akari
{
  /// Cascaded shadow maps for the sun + spot/area shadow maps.
  struct ShadowPass: RenderPassNode
  {
    public let id: RenderPassID = .shadow
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.shadowMaps)
    }

    public func execute(_ state: inout FrameState, _: FrameContext)
    {
      state.declare(.shadowAtlas, RenderTargetDesc(width: 4096, height: 4096, format: .depth32f))
      // TODO: fit N cascades to the view frustum, snap to texels,
      // render depth only per cascade + per punctual/area light
      // into the atlas.
    }
  }

  /// Opaque geometry into a compact G-buffer (deferred) or forward+ shaded.
  struct GeometryPass: RenderPassNode
  {
    public let id: RenderPassID = .geometry
    public init() {}
    public func execute(_: inout FrameState, _ ctx: FrameContext)
    {
      // geometry stage: open the frame, rerecord the synced meshes
      // into the capture buffer, and set the per frame view matrix.
      LabFXEngine.shared.beginFrame(width: ctx.target.width,
                                    height: ctx.target.height)
      LabFXEngine.shared.recordGeometry(renderParam: ctx.renderParam,
                                        view: ctx.camera.view,
                                        projection: ctx.camera.projection)
    }
  }

  /// Ground truth ambient occlusion (GTAO).
  struct AmbientOcclusionPass: RenderPassNode
  {
    public let id: RenderPassID = .ambientOcclusion
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.ambientOcclusion)
    }

    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.ambientOcclusion,
                    RenderTargetDesc(width: ctx.target.width, height: ctx.target.height,
                                     format: .r16f, scale: 0.5))
      // TODO: GTAO from depth + normals, multi bounce term, bilateral blur.
    }
  }

  /// Direct + image based lighting.
  struct LightingPass: RenderPassNode
  {
    public let id: RenderPassID = .lighting
    public init() {}
    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.sceneColorHDR,
                    RenderTargetDesc(width: ctx.target.width, height: ctx.target.height,
                                     format: .rgba16f))
      // lighting stage: the deferred resolve shades the G-buffer
      // with split sum IBL into the scene HDR color.
      LabFXEngine.shared.setLighting(
        iblEnabled: ctx.settings.features.contains(.imageBasedLighting),
        projection: ctx.camera.projection
      )
    }
  }

  /// Screen space global illumination (indirect diffuse bounce).
  struct ScreenSpaceGIPass: RenderPassNode
  {
    public let id: RenderPassID = .screenSpaceGI
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.screenSpaceGI)
    }

    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.screenSpaceGI,
                    RenderTargetDesc(width: ctx.target.width, height: ctx.target.height,
                                     format: .rgba16f, scale: 0.5))
      // TODO: horizon scan gather from scene color + depth, denoise,
      // reproject against history, composite into sceneColorHDR.
    }
  }

  /// Screen space reflections with hardware RT as the off screen fallback.
  struct ReflectionsPass: RenderPassNode
  {
    public let id: RenderPassID = .reflections
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.screenSpaceReflections) || s.features.contains(.hardwareRayTracing)
    }

    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.reflections,
                    RenderTargetDesc(width: ctx.target.width, height: ctx.target.height,
                                     format: .rgba16f))
      // TODO: SSR march in HDR color, RT fill on miss when enabled,
      // resolve against roughness, composite into sceneColorHDR.
    }
  }

  /// Sorted forward transparency over the resolved opaque HDR color.
  struct TransparencyPass: RenderPassNode
  {
    public let id: RenderPassID = .transparency
    public init() {}
    public func execute(_: inout FrameState, _: FrameContext) {}
    // TODO: back to front (or OIT) forward shade transparent prims.
  }

  /// Froxel volumetrics (fog, light shafts).
  struct VolumetricsPass: RenderPassNode
  {
    public let id: RenderPassID = .volumetrics
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.volumetrics)
    }

    public func execute(_: inout FrameState, _: FrameContext) {}
    // TODO: froxel scatter / extinction integration, composite.
  }

  /// Temporal anti aliasing / reprojection, also stabilizes the SS effects.
  struct TemporalResolvePass: RenderPassNode
  {
    public let id: RenderPassID = .temporalResolve
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.temporalAA)
    }

    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.history,
                    RenderTargetDesc(width: ctx.target.width, height: ctx.target.height,
                                     format: .rgba16f))
      // TODO: temporal accumulation, blend 1/samples of the jittered current
      // frame into a persistent history buffer, then hand the resolved frame
      // to the tonemap.
    }
  }

  /// Physically based bloom.
  struct BloomPass: RenderPassNode
  {
    public let id: RenderPassID = .bloom
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.bloom)
    }

    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.bloomChain,
                    RenderTargetDesc(width: ctx.target.width / 2, height: ctx.target.height / 2,
                                     format: .rgba16f))
      // TODO: Karis averaged downsample pyramid, tent upsample, add.
    }
  }

  /// Apply view transformation (AgX by default).
  struct TonemapPass: RenderPassNode
  {
    public let id: RenderPassID = .tonemap
    public init() {}
    public func execute(_: inout FrameState, _ ctx: FrameContext)
    {
      // tonemap stage: exposure, view transform, gamma, dither seed.
      LabFXEngine.shared.setTonemap(exposure: ctx.settings.color.exposure,
                                    gamma: ctx.settings.color.gamma,
                                    viewTransform: ctx.settings.color.viewTransform,
                                    frameIndex: ctx.frameIndex)
    }
  }

  /// Depth of field (bokeh) over the resolved HDR color.
  struct DepthOfFieldPass: RenderPassNode
  {
    public let id: RenderPassID = .depthOfField
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.depthOfField)
    }

    public func execute(_: inout FrameState, _: FrameContext) {}
    // TODO: CoC from depth, tiled gather bokeh, composite.
  }

  /// Hand the final image to the bound color AOV (Hydra composites / presents).
  struct PresentPass: RenderPassNode
  {
    public let id: RenderPassID = .present
    public init() {}
    public func execute(_: inout FrameState, _ ctx: FrameContext)
    {
      // present stage: execute the deferred graph, present,
      // and wrap the tonemapped texture into the color AOV.
      LabFXEngine.shared.present(color: ctx.target.color,
                                 hgi: ctx.gpu.hgi)
    }
  }

  /// Depth-only prepass (Hi-Z seed, overdraw kill, SS-effect input).
  struct DepthPrepass: RenderPassNode
  {
    public let id: RenderPassID = .depthPrepass
    public init() {}
    public func execute(_ state: inout FrameState, _ ctx: FrameContext)
    {
      state.declare(.depth, RenderTargetDesc(width: ctx.target.width, height: ctx.target.height,
                                             format: .depth32f))
    }
  }
}
