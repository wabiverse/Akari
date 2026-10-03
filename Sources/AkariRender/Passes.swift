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
  /// Virtual shadow maps for the sun and point lights.
  struct ShadowPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .shadow
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.shadowMaps)
    }

    public func execute(_: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      ctx.labfx.markShadowPageUsage(camera: ctx.camera, settings: ctx.settings)
      ctx.labfx.renderShadows(renderParam: ctx.renderParam,
                              camera: ctx.camera,
                              settings: ctx.settings,
                              frameIndex: ctx.frameIndex)
      // TODO: punctual and area lights, once they arrive as Sprims, take
      // their own tiles out of the same atlas.
    }
  }

  /// Volume + sphere light probes for indirect diffuse and reflections.
  struct LightProbePass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .lightProbes
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.lightProbes)
    }

    public func execute(_: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      ctx.labfx.updateLightProbes(renderParam: ctx.renderParam, settings: ctx.settings)
    }
  }

  /// Opaque geometry into a compact G-buffer (deferred) or forward+ shaded.
  struct GeometryPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .geometry
    public init() {}
    public func execute(_: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      // geometry stage: open the frame, rerecord the synced meshes
      // into the capture buffers (the selected ones into the outline's),
      // and set the per frame view matrix.
      ctx.labfx.beginFrame(width: ctx.target.width,
                           height: ctx.target.height,
                           hgi: ctx.gpu.hgi)
      ctx.labfx.recordGeometry(renderParam: ctx.renderParam,
                               view: ctx.camera.view,
                               projection: ctx.camera.projection,
                               unjitteredProjection: ctx.unjitteredCamera.projection,
                               selection: ctx.selection)
      ctx.labfx.cullStaticGeometry(viewProjection: ctx.camera.projection * ctx.camera.view)

      ctx.labfx.renderGbufferEarly()
    }
  }

  /// Direct + image based lighting.
  struct LightingPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .lighting
    public init() {}
    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      state.declare(.sceneColorHDR,
                    Akari.GPU.RenderTargetDesc(width: ctx.target.width,
                                               height: ctx.target.height,
                                               format: .rgba16f))
      // lighting stage: the deferred resolve shades the G-buffer
      // with split sum IBL into the scene HDR color.
      ctx.labfx.setLighting(
        iblEnabled: ctx.settings.features.contains(.imageBasedLighting),
        projection: ctx.camera.projection,
        light: ctx.settings.light,
        shadowsEnabled: ctx.settings.features.contains(.shadowMaps)
      )
    }
  }

  /// Screen space global illumination (indirect diffuse bounce).
  struct ScreenSpaceGIPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .screenSpaceGI
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.screenSpaceGI)
    }

    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      state.declare(.screenSpaceGI,
                    Akari.GPU.RenderTargetDesc(width: ctx.target.width,
                                               height: ctx.target.height,
                                               format: .rgba16f, scale: 0.5))
      ctx.labfx.setScreenSpaceGI(maxRoughness: ctx.settings.reflection.maxRoughness)
    }
  }

  /// Screen space reflections with hardware RT as the off screen fallback.
  struct ReflectionsPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .reflections
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.screenSpaceReflections) || s.features.contains(.hardwareRayTracing)
    }

    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      state.declare(.reflections,
                    Akari.GPU.RenderTargetDesc(width: ctx.target.width,
                                               height: ctx.target.height,
                                               format: .rgba16f, scale: 0.5))
      if ctx.settings.features.contains(.screenSpaceReflections)
      {
        ctx.labfx.setScreenSpaceReflections(maxRoughness: ctx.settings.reflection.maxRoughness)
      }
      // TODO: hardware RT fill on miss.
    }
  }

  /// Sorted forward transparency over the resolved opaque HDR color.
  struct TransparencyPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .transparency
    public init() {}
    public func execute(_: inout Akari.GPU.FrameState, _: Akari.GPU.FrameContext) {}
    // TODO: back to front (or OIT) forward shade transparent prims.
  }

  /// Froxel volumetrics (fog, light shafts).
  struct VolumetricsPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .volumetrics
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.volumetrics)
    }

    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      let froxelAtlas = Akari.GPU.RenderTargetDesc(width: ctx.target.width,
                                                   height: ctx.target.height,
                                                   format: .rgba16f, scale: 0.5)
      state.declare(.volumeScatter, froxelAtlas)
      state.declare(.volumeIntegrated, froxelAtlas)
      ctx.labfx.setVolumetrics(camera: ctx.camera, volume: ctx.settings.volume)
    }
  }

  /// Temporal anti aliasing / reprojection, also stabilizes the SS effects.
  struct TemporalResolvePass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .temporalResolve
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.temporalAA)
    }

    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      state.declare(.history,
                    Akari.GPU.RenderTargetDesc(width: ctx.target.width,
                                               height: ctx.target.height,
                                               format: .rgba16f))
      ctx.labfx.setTemporal(camera: ctx.unjitteredCamera,
                            samples: ctx.settings.samples,
                            moving: ctx.cameraMoved)
    }
  }

  /// Physically based bloom.
  struct BloomPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .bloom
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.bloom)
    }

    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      state.declare(.bloomChain,
                    Akari.GPU.RenderTargetDesc(width: ctx.target.width / 2,
                                               height: ctx.target.height / 2,
                                               format: .rgba16f))
      // TODO: Karis averaged downsample pyramid, tent upsample, add.
    }
  }

  /// Apply view transformation (AgX by default).
  struct TonemapPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .tonemap
    public init() {}
    public func execute(_: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      // tonemap stage: exposure, view transform, gamma, dither seed.
      ctx.labfx.setTonemap(exposure: ctx.settings.color.exposure,
                           gamma: ctx.settings.color.gamma,
                           viewTransform: ctx.settings.color.viewTransform,
                           frameIndex: ctx.frameIndex)
    }
  }

  /// Depth of field (bokeh) over the resolved HDR color.
  struct DepthOfFieldPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .depthOfField
    public init() {}
    public func isEnabled(for s: RenderSettings) -> Bool
    {
      s.features.contains(.depthOfField)
    }

    public func execute(_: inout Akari.GPU.FrameState, _: Akari.GPU.FrameContext) {}
    // TODO: CoC from depth, tiled gather bokeh, composite.
  }

  /// Hand the final image to the bound color AOV (Hydra composites / presents).
  struct PresentPass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .present
    public init() {}
    public func execute(_: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      // present stage: execute the deferred graph, outline the
      // selection, present, and wrap the final color and the id
      // + depth textures into the AOVs.
      ctx.labfx.present(target: ctx.target,
                        projection: ctx.unjitteredCamera.projection,
                        hgi: ctx.gpu.hgi,
                        fireflies: ctx.settings.features.contains(.fireflies),
                        lightProbes: ctx.settings.features.contains(.lightProbes))
    }
  }

  /// Depth-only prepass (Hi-Z seed, overdraw kill, SS-effect input).
  struct DepthPrepass: Akari.GPU.RenderPassNode
  {
    public let id: RenderPassID = .depthPrepass
    public init() {}
    public func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
    {
      state.declare(.depth, Akari.GPU.RenderTargetDesc(width: ctx.target.width,
                                                       height: ctx.target.height,
                                                       format: .depth32f))
    }
  }
}
