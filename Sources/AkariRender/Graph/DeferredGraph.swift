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

extension Akari.RenderGraph
{
  /// the deferred graph the engine renders every frame, its passes in the order they run.
  static var deferred: Graph
  {
    Graph("Akari LabGL", version: "1.0")
    {
      Buffers(
        GBuffer.self, BackGBuffer.self, HizBuffer.self, EnvCubeBuffer.self, DomeBuffer.self, ColorBuffer.self,
        SsgiPrepBuffer.self, SsgiPyramidBuffer.self, SsgiBuffer.self, SsgiAccumBuffer.self,
        SsgiHistoryBuffer.self, PointShadowRawBuffer.self, PointShadowBlurBuffer.self, PointShadowBuffer.self,
        VolumeScatterBuffer.self, VolumeIntegratedBuffer.self, SsrBuffer.self, SsrResolveBuffer.self, SsrAccumBuffer.self,
        SsrHistoryBuffer.self, SunShadowRawBuffer.self, SunShadowAccumBuffer.self, SunShadowHistoryBuffer.self,
        SunShadowBlurBuffer.self, SunShadowSoftBuffer.self, TaaBuffer.self, UpscaleInputBuffer.self,
        SupersampleBuffer.self, HistoryBuffer.self, TonemapBuffer.self, OutlineMaskBuffer.self,
        OutlineEdgeBuffer.self, OutlineSpanBuffer.self, OutlineBuffer.self, AovBuffer.self,
        VolumeShadowBuffer.self, MotionTiles8Buffer.self, MotionTilesBuffer.self, MotionNeighborsBuffer.self,
        MotionBlurBuffer.self, BloomDown0Buffer.self, BloomDown1Buffer.self, BloomDown2Buffer.self,
        BloomDown3Buffer.self, BloomDown4Buffer.self, BloomDown5Buffer.self, BloomUp0Buffer.self,
        BloomUp1Buffer.self, BloomUp2Buffer.self, BloomUp3Buffer.self, BloomUp4Buffer.self,
        LensStreakBuffer.self, LensStreakWideBuffer.self, LensGhostsBuffer.self, FogSimHalfBuffer.self,
        DofBuffer.self, DofDepthBuffer.self, DofTiles8Buffer.self, DofTilesBuffer.self,
        DofNeighborsBuffer.self, DofHalfSourceBuffer.self, DofHalfBuffer.self, TransparentAccumBuffer.self,
        TransparentResolvedBuffer.self, AtmosTransmittanceBuffer.self, AtmosMultiScatterBuffer.self, AtmosSkyViewBuffer.self,
        PlanetCloudMapBuffer.self, AtmosAerialBuffer.self,
        GlassNearBuffer.self, GlassFarBuffer.self, GlassTransmitBuffer.self, GlassFrontBuffer.self, GlassBackBuffer.self,
        GlassBehindFrontBuffer.self, GlassBehindBackBuffer.self, TransparentBehindBuffer.self, TransparentBehindResolvedBuffer.self,
        GlassSunCausticBuffer.self, GlassLocalCausticBuffer.self, GlassCausticAccumBuffer.self, GlassCausticHistoryBuffer.self
      )

      Pass(.clearGbuffer)
      {
        Draw(.none)
        ClearDepth()
        ClearOutputs()
        Output(GBuffer.self)
      }

      Pass(.atmosphereTransmittance)
      {
        Quad()
        Shader(AtmosphereTransmittanceShader())
        Output(AtmosTransmittanceBuffer.atmosTransmittance)
      }

      Pass(.atmosphereMultiscatter)
      {
        Quad()
        Shader(AtmosphereMultiscatterShader())
        Inputs(AtmosTransmittanceBuffer.atmosTransmittance)
        Output(AtmosMultiScatterBuffer.self)
      }

      Pass(.atmosphereSkyView)
      {
        Quad()
        Shader(AtmosphereSkyViewShader())
        Inputs(AtmosTransmittanceBuffer.atmosTransmittance, AtmosMultiScatterBuffer.atmosMultiScatter)
        Output(AtmosSkyViewBuffer.atmosSkyView)
      }

      Pass(.atmosphereAerial)
      {
        Quad()
        Shader(AtmosphereAerialShader())
        Inputs(AtmosTransmittanceBuffer.atmosTransmittance, AtmosMultiScatterBuffer.atmosMultiScatter)
        Output(AtmosAerialBuffer.atmosAerial)
      }

      Pass(.dome)
      {
        Shader(DomeSkyShader())
        Dispatch([16, 16, 6], threadgroup: [16, 16, 1])
        EveryMip()
        Inputs(DomeBuffer.dome)
        Output(EnvCubeBuffer.envCube)
      }

      Pass(.planetCloudMap)
      {
        Quad()
        Shader(PlanetCloudMapShader())
        Output(PlanetCloudMapBuffer.planetCloudMap)
      }

      Pass(.atmosphereEnv)
      {
        Shader(AtmosphereEnvShader())
        Dispatch([16, 16, 6], threadgroup: [16, 16, 1])
        EveryMip()
        Inputs(DomeBuffer.dome, AtmosTransmittanceBuffer.atmosTransmittance, AtmosMultiScatterBuffer.atmosMultiScatter, AtmosMultiScatterBuffer.atmosIrradiance, AtmosSkyViewBuffer.atmosSkyView, PlanetCloudMapBuffer.planetCloudMap)
        Output(EnvCubeBuffer.envCube)
      }

      Pass(.sky)
      {
        Shader(HosekWilkieShader())
        Dispatch([64, 64, 6], threadgroup: [16, 16, 1])
        EveryMip()
        Output(EnvCubeBuffer.envCube)
      }

      Pass(.geometry)
      {
        Draw(.opaqueGeometry)
        ClearDepth(false)
        DepthTest(.greater)
        WriteDepth()
        Shader(MeshStaticShader())
        Output(GBuffer.self)
      }

      Pass(.geometryInstanced)
      {
        Callback(.drawStaticInstancedGeometry)
        ClearDepth(false)
        DepthTest(.greater)
        WriteDepth()
        Shader(MeshStaticShader())
        Output(GBuffer.self)
      }

      Pass(.geometryDynamic)
      {
        Callback(.drawDynamicGeometry)
        ClearDepth(false)
        DepthTest(.greater)
        WriteDepth()
        Shader(MeshShader())
        Output(GBuffer.self)
      }

      Pass(.ssgiPrep)
      {
        Quad()
        Shader(SsgiPrepShader())
        Inputs(GBuffer.position, GBuffer.normal, GBuffer.material, HistoryBuffer.history)
        Output(SsgiPrepBuffer.self)
      }

      Pass(.ssgiPyramid)
      {
        Quad()
        Shader(SsgiPyramidShader())
        Inputs(SsgiPrepBuffer.ssgiDepth, SsgiPrepBuffer.ssgiNormal, SsgiPrepBuffer.ssgiRadiance)
        Output(SsgiPyramidBuffer.self)
      }

      Pass(.ssgi)
      {
        Quad()
        Shader(SsgiShader())
        Inputs(SsgiPrepBuffer.ssgiDepth, SsgiPrepBuffer.ssgiNormal, SsgiPrepBuffer.ssgiRadiance, SsgiPyramidBuffer.ssgiPyramidDepth, SsgiPyramidBuffer.ssgiPyramidNormal, SsgiPyramidBuffer.ssgiPyramidRadiance)
        Output(SsgiBuffer.self)
      }

      Pass(.ssgiTemporal)
      {
        Quad()
        Shader(SsgiTemporalShader())
        Inputs(SsgiBuffer.ssgiRaw, SsgiBuffer.ssgiSpecRaw, SsgiBuffer.ssgiBentRaw, SsgiHistoryBuffer.ssgiHistory, SsgiHistoryBuffer.ssgiSpecHistory, SsgiHistoryBuffer.ssgiBentHistory, SsgiPrepBuffer.ssgiDepth, SsgiPrepBuffer.ssgiNormal)
        Output(SsgiAccumBuffer.self)
      }

      Pass(.ssgiHistory)
      {
        Quad()
        Shader(SsgiCopyShader())
        Inputs(SsgiAccumBuffer.ssgiAccum, SsgiAccumBuffer.ssgiSpecAccum, SsgiAccumBuffer.ssgiBentAccum)
        Output(SsgiHistoryBuffer.self)
      }

      Pass(.volumeScatter)
      {
        Quad()
        Shader(VolumeScatterShader())
        Inputs(EnvCubeBuffer.envCube, IrradianceBuffer.irradiance)
        Output(VolumeScatterBuffer.volumeScatter)
      }

      Pass(.volumeIntegrate)
      {
        Callback(.volumeIntegrate)
      }

      // the nearest faces facing away, so reflections know what's behind the surfaces they pass, cleared by the first pass that draws
      Pass(.geometryBack)
      {
        Callback(.drawStaticGeometryBack)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Shader(MeshStaticShader(layer: .back))
        Output(BackGBuffer.self)
      }

      Pass(.geometryInstancedBack)
      {
        Callback(.drawStaticInstancedGeometryBack)
        ClearDepth(false)
        DepthTest(.greater)
        WriteDepth()
        Shader(MeshStaticShader(layer: .back))
        Output(BackGBuffer.self)
      }

      Pass(.geometryDynamicBack)
      {
        Callback(.drawDynamicGeometryBack)
        ClearDepth(false)
        DepthTest(.greater)
        WriteDepth()
        Shader(MeshShader(layer: .back))
        Output(BackGBuffer.self)
      }

      // the closest depth over every level of the hiz atlas, which the reflection trace walks instead of stepping evenly
      Pass(.hiz)
      {
        Quad()
        Shader(HizShader())
        Inputs(SsgiPrepBuffer.ssgiDepth)
        Output(HizBuffer.hiz)
      }

      Pass(.ssr)
      {
        Quad()
        Shader(SsrShader())
        Inputs(GBuffer.position, GBuffer.normal, GBuffer.material, GBuffer.velocity, HistoryBuffer.history, SsgiPrepBuffer.ssgiDepth,
               BackGBuffer.backPosition, BackGBuffer.backNormal, BackGBuffer.backDiffuse, BackGBuffer.backMaterial, IrradianceBuffer.irradiance,
               HizBuffer.hiz)
        Output(SsrBuffer.self)
      }

      Pass(.ssrResolve)
      {
        Quad()
        Shader(SsrResolveShader())
        Inputs(SsrBuffer.ssrRadiance, SsrBuffer.ssrGuide, SsrBuffer.ssrRay, GBuffer.position, GBuffer.material)
        Output(SsrResolveBuffer.ssrResolved)
      }

      Pass(.ssrTemporal)
      {
        Quad()
        Shader(SsrTemporalShader())
        Inputs(SsrResolveBuffer.ssrResolved, SsrBuffer.ssrGuide, SsrBuffer.ssrMotion, SsrHistoryBuffer.ssrHistory, SsrHistoryBuffer.ssrGuideHistory,
               SsrHistoryBuffer.ssrMotionHistory, GBuffer.position, GBuffer.material, GBuffer.velocity)
        Output(SsrAccumBuffer.self)
      }

      Pass(.ssrHistory)
      {
        Quad()
        Shader(SsrCopyShader())
        Inputs(SsrAccumBuffer.ssrAccum, SsrAccumBuffer.ssrMotionMemory, SsrBuffer.ssrGuide)
        Output(SsrHistoryBuffer.self)
      }

      // every glass light draws the glass's surfaces and the light it lets through into its atlas tile, in one amplified draw
      Pass(.glassNear)
      {
        Callback(.drawGlassNear)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Output(GlassNearBuffer.glassNear, GlassNearBuffer.glassNearNormal)
      }

      Pass(.glassFar)
      {
        Callback(.drawGlassFar)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Output(GlassFarBuffer.glassFar, GlassFarBuffer.glassFarNormal)
      }

      Pass(.glassTransmit)
      {
        Callback(.drawGlassTransmit)
        ClearDepth()
        ClearOutputs()
        DepthTest(.always)
        WriteDepth(false)
        Blend(.additive)
        Output(GlassTransmitBuffer.glassTransmit)
      }

      Pass(.pointShadows)
      {
        Quad()
        Shader(PointShadowShader())
        Inputs(GBuffer.position, GBuffer.normal, GlassNearBuffer.glassNear, GlassNearBuffer.glassNearNormal)
        Output(PointShadowRawBuffer.self)
      }

      Pass(.pointShadowBlurH)
      {
        Quad()
        Shader(PointShadowBlurShader(axis: .horizontal))
        Inputs(PointShadowRawBuffer.pointShadowRaw0, PointShadowRawBuffer.pointShadowRaw1, PointShadowRawBuffer.pointShadowRaw2, PointShadowRawBuffer.pointShadowRaw3, PointShadowRawBuffer.pointShadowGuide)
        Output(PointShadowBlurBuffer.self)
      }

      Pass(.pointShadowBlurV)
      {
        Quad()
        Shader(PointShadowBlurShader(axis: .vertical))
        Inputs(PointShadowBlurBuffer.pointShadowBlur0, PointShadowBlurBuffer.pointShadowBlur1, PointShadowBlurBuffer.pointShadowBlur2, PointShadowBlurBuffer.pointShadowBlur3, PointShadowRawBuffer.pointShadowGuide)
        Output(PointShadowBuffer.self)
      }

      Pass(.sunShadow)
      {
        Quad()
        Shader(SunShadowShader())
        Inputs(GBuffer.position, GBuffer.normal, GlassNearBuffer.glassNear, GlassNearBuffer.glassNearNormal)
        Output(SunShadowRawBuffer.sunShadowRaw)
      }

      Pass(.sunShadowTemporal)
      {
        Quad()
        Shader(SunShadowTemporalShader())
        Inputs(SunShadowRawBuffer.sunShadowRaw, SunShadowHistoryBuffer.sunShadowHistory, GBuffer.position, GBuffer.normal, GBuffer.velocity)
        Output(SunShadowAccumBuffer.sunShadowAccum)
      }

      Pass(.sunShadowHistory)
      {
        Quad()
        Shader(SunShadowCopyShader())
        Inputs(SunShadowAccumBuffer.sunShadowAccum)
        Output(SunShadowHistoryBuffer.sunShadowHistory)
      }

      Pass(.sunShadowBlurH)
      {
        Quad()
        Shader(SunShadowBlurShader(axis: .horizontal))
        Inputs(SunShadowAccumBuffer.sunShadowAccum, GBuffer.position, GBuffer.normal)
        Output(SunShadowBlurBuffer.sunShadowBlurH)
      }

      Pass(.sunShadowBlurV)
      {
        Quad()
        Shader(SunShadowBlurShader(axis: .vertical))
        Inputs(SunShadowBlurBuffer.sunShadowBlurH, GBuffer.position, GBuffer.normal)
        Output(SunShadowSoftBuffer.sunShadowSoft)
      }

      // each glass light's rays trace through the glass and splat as caustics, the sun's apart since the shading colors it
      Pass(.glassSunTrace)
      {
        Callback(.traceGlassSun)
      }

      Pass(.glassSunCaustics)
      {
        Callback(.splatGlassSun)
        ClearOutputs()
        Blend(.additive)
        Output(GlassSunCausticBuffer.glassSunCaustic)
      }

      Pass(.glassLocalTrace)
      {
        Callback(.traceGlassLocal)
      }

      Pass(.glassLocalCaustics)
      {
        Callback(.splatGlassLocal)
        ClearOutputs()
        Blend(.additive)
        Output(GlassLocalCausticBuffer.glassLocalCaustic)
      }

      Pass(.glassCausticTemporal)
      {
        Quad()
        Shader(GlassCausticTemporalShader())
        Inputs(GlassSunCausticBuffer.glassSunCaustic, GlassLocalCausticBuffer.glassLocalCaustic,
               GlassCausticHistoryBuffer.glassSunCausticHistory, GlassCausticHistoryBuffer.glassLocalCausticHistory,
               GBuffer.position, GBuffer.normal, GBuffer.velocity)
        Output(GlassCausticAccumBuffer.self)
      }

      Pass(.glassCausticHistory)
      {
        Quad()
        Shader(GlassCausticCopyShader())
        Inputs(GlassCausticAccumBuffer.glassSunCausticAccum, GlassCausticAccumBuffer.glassLocalCausticAccum)
        Output(GlassCausticHistoryBuffer.self)
      }

      Pass(.resolve)
      {
        Quad()
        Shader(DeferredShadeShader())
        Inputs(GBuffer.diffuse, GBuffer.position, GBuffer.normal, GBuffer.material, GBuffer.specular, EnvCubeBuffer.envCube, PrefilteredBuffer.prefiltered, IrradianceBuffer.irradiance, DfgBuffer.dfg, SsgiAccumBuffer.ssgiAccum, SsgiAccumBuffer.ssgiSpecAccum, SsgiAccumBuffer.ssgiBentAccum, SsgiPrepBuffer.ssgiDepth, SsgiPrepBuffer.ssgiNormal, VolumeIntegratedBuffer.volumeIntegrated, PointShadowBuffer.pointShadow0, PointShadowBuffer.pointShadow1, PointShadowBuffer.pointShadow2, PointShadowBuffer.pointShadow3, PointShadowRawBuffer.pointShadowGuide, SsrAccumBuffer.ssrAccum, SsrBuffer.ssrGuide, SunShadowSoftBuffer.sunShadowSoft, AtmosTransmittanceBuffer.atmosTransmittance, AtmosAerialBuffer.atmosAerial, PlanetCloudMapBuffer.planetCloudMap,
               GlassCausticAccumBuffer.glassSunCausticAccum, GlassCausticAccumBuffer.glassLocalCausticAccum)
        Output(ColorBuffer.`final`)
      }

      Pass(.atmosphereBackground)
      {
        Quad()
        Blend(.alpha)
        Shader(AtmosphereBackgroundShader())
        Inputs(GBuffer.normal, AtmosTransmittanceBuffer.atmosTransmittance, AtmosMultiScatterBuffer.atmosMultiScatter, AtmosMultiScatterBuffer.atmosIrradiance, AtmosSkyViewBuffer.atmosSkyView, VolumeIntegratedBuffer.volumeIntegrated, PlanetCloudMapBuffer.planetCloudMap)
        Output(ColorBuffer.`final`)
      }

      Pass(.volumeShadow)
      {
        Quad()
        Shader(VolumeShadowShader())
        Output(VolumeShadowBuffer.volumeShadow)
      }

      Pass(.volumeMarch)
      {
        Quad()
        Blend(.alpha)
        Shader(VolumeMarchShader())
        Inputs(GBuffer.position, GBuffer.normal, VolumeShadowBuffer.volumeShadow, IrradianceBuffer.irradiance, AtmosAerialBuffer.atmosAerial)
        Output(ColorBuffer.`final`)
      }

      Pass(.fogSimMarch)
      {
        Quad()
        ClearDepth(false)
        ClearOutputs()
        Shader(FogSimMarchShader())
        Inputs(GBuffer.position, GBuffer.normal, VolumeScatterBuffer.volumeScatter)
        Output(FogSimHalfBuffer.fogSimHalf)
      }

      Pass(.fogSimComposite)
      {
        Quad()
        Blend(.alpha)
        Shader(FogSimCompositeShader())
        Inputs(GBuffer.position, GBuffer.normal, FogSimHalfBuffer.fogSimHalf)
        Output(ColorBuffer.`final`)
      }

      Pass(.transparentClear)
      {
        Draw(.none)
        ClearDepth()
        ClearOutputs()
        Output(TransparentAccumBuffer.self)
      }

      Pass(.transparent)
      {
        Callback(.drawDynamicGeometry)
        DepthTest(.always)
        WriteDepth(false)
        Blend(.additive)
        Shader(MeshTransparentShader())
        Inputs(GBuffer.position, GBuffer.normal, PrefilteredBuffer.prefiltered, IrradianceBuffer.irradiance, EnvCubeBuffer.envCube)
        Output(TransparentAccumBuffer.self)
      }

      // the glass nearest the camera and the farthest, which the composite traces each view ray in and out through.
      Pass(.glassFrontView)
      {
        Callback(.drawDynamicGeometry)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Shader(GlassViewShader(side: .front))
        Inputs(GBuffer.position, GBuffer.normal)
        Output(GlassFrontBuffer.glassFront, GlassFrontBuffer.glassFrontNormal)
      }

      Pass(.glassBackView)
      {
        Callback(.drawDynamicGeometry)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Shader(GlassViewShader(side: .back))
        Inputs(GBuffer.position, GBuffer.normal, GlassFrontBuffer.glassFront)
        Output(GlassBackBuffer.glassBack, GlassBackBuffer.glassBackNormal)
      }

      // the next glass behind the nearest and everything else behind it, composited first so glass seen through glass bends too
      Pass(.glassBehindFrontView)
      {
        Callback(.drawDynamicGeometry)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Shader(GlassViewShader(side: .behindFront))
        Inputs(GBuffer.position, GBuffer.normal, GlassFrontBuffer.glassFront)
        Output(GlassBehindFrontBuffer.glassBehindFront, GlassBehindFrontBuffer.glassBehindFrontNormal)
      }

      Pass(.glassBehindBackView)
      {
        Callback(.drawDynamicGeometry)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Shader(GlassViewShader(side: .behindBack))
        Inputs(GBuffer.position, GBuffer.normal, GlassBehindFrontBuffer.glassBehindFront)
        Output(GlassBehindBackBuffer.glassBehindBack, GlassBehindBackBuffer.glassBehindBackNormal)
      }

      Pass(.transparentBehind)
      {
        Callback(.drawDynamicGeometry)
        ClearDepth()
        ClearOutputs()
        DepthTest(.always)
        WriteDepth(false)
        Blend(.additive)
        Shader(MeshTransparentShader(layer: .behind))
        Inputs(GBuffer.position, GBuffer.normal, PrefilteredBuffer.prefiltered, IrradianceBuffer.irradiance, EnvCubeBuffer.envCube, GlassFrontBuffer.glassFront)
        Output(TransparentBehindBuffer.self)
      }

      Pass(.transparentBehindComposite)
      {
        Quad()
        Shader(TransparentBehindCompositeShader())
        Inputs(ColorBuffer.`final`, TransparentBehindBuffer.bColor, TransparentBehindBuffer.bReflect, TransparentBehindBuffer.bTransmit, GBuffer.position, GBuffer.normal,
               PrefilteredBuffer.prefiltered,
               GlassFrontBuffer.glassFront, GlassBehindFrontBuffer.glassBehindFront, GlassBehindFrontBuffer.glassBehindFrontNormal,
               GlassBehindBackBuffer.glassBehindBack, GlassBehindBackBuffer.glassBehindBackNormal)
        Output(TransparentBehindResolvedBuffer.self)
      }

      Pass(.transparentComposite)
      {
        Quad()
        Shader(TransparentCompositeShader())
        Inputs(ColorBuffer.`final`, TransparentAccumBuffer.tColor, TransparentAccumBuffer.tReflect, TransparentAccumBuffer.tTransmit, TransparentAccumBuffer.tOffset, TransparentAccumBuffer.tDepth, GBuffer.position, GBuffer.normal, PrefilteredBuffer.prefiltered,
               GlassFrontBuffer.glassFront, GlassFrontBuffer.glassFrontNormal, GlassBackBuffer.glassBack, GlassBackBuffer.glassBackNormal,
               TransparentBehindBuffer.bColor, TransparentBehindBuffer.bReflect, TransparentBehindBuffer.bTransmit, TransparentBehindResolvedBuffer.tBehind)
        Output(TransparentResolvedBuffer.self)
      }

      Pass(.transparentApply)
      {
        Quad()
        Shader(TaaCopyShader(source: .transparent))
        Inputs(TransparentResolvedBuffer.tResolved)
        Output(ColorBuffer.`final`)
      }

      Pass(.upscaleSanitize)
      {
        Quad()
        Shader(UpscaleSanitizeShader())
        Inputs(ColorBuffer.`final`, GBuffer.position, GBuffer.normal, GBuffer.velocity)
        Output(UpscaleInputBuffer.self)
      }

      Pass(.motionTilesPre8)
      {
        Quad()
        Shader(MotionTile8Shader())
        Inputs(GBuffer.velocity, GBuffer.normal, TransparentAccumBuffer.tVelocity)
        Output(MotionTiles8Buffer.motionTile8)
      }

      Pass(.motionTilesPre)
      {
        Quad()
        Shader(MotionTileMaxShader())
        Inputs(MotionTiles8Buffer.motionTile8)
        Output(MotionTilesBuffer.motionTileMax)
      }

      Pass(.motionNeighborsPre)
      {
        Quad()
        Shader(MotionNeighborMaxShader())
        Inputs(MotionTilesBuffer.motionTileMax)
        Output(MotionNeighborsBuffer.motionNeighborMax)
      }

      Pass(.motionBlurPre)
      {
        Quad()
        Shader(MotionBlurShader())
        Inputs(ColorBuffer.`final`, GBuffer.velocity, GBuffer.normal, GBuffer.position, MotionNeighborsBuffer.motionNeighborMax, TransparentAccumBuffer.tVelocity)
        Output(MotionBlurBuffer.motionBlurred)
      }

      Pass(.motionBlurPreApply)
      {
        Quad()
        Shader(TaaCopyShader(source: .blurred))
        Inputs(MotionBlurBuffer.motionBlurred)
        Output(ColorBuffer.`final`)
      }

      Pass(.taa)
      {
        Quad()
        Shader(TaaShader())
        Inputs(ColorBuffer.`final`, HistoryBuffer.history, GBuffer.position, GBuffer.normal, GBuffer.velocity)
        Output(TaaBuffer.`final`)
      }

      Pass(.upscale)
      {
        Callback(.metalfxUpscale)
        DepthTest(.never)
        WriteDepth(false)
        Output(TaaBuffer.`final`)
      }

      Pass(.upscaleSupersample)
      {
        Callback(.metalfxUpscale)
        DepthTest(.never)
        WriteDepth(false)
        Output(SupersampleBuffer.supersample)
      }

      Pass(.downsample)
      {
        Quad()
        Shader(SupersampleDownsampleShader())
        Inputs(SupersampleBuffer.supersample)
        Output(TaaBuffer.`final`)
      }

      Pass(.taaHistory)
      {
        Quad()
        Shader(TaaCopyShader(source: .taa))
        Inputs(TaaBuffer.`final`)
        Output(HistoryBuffer.history)
      }

      Pass(.depthOfFieldDepth)
      {
        Quad()
        Shader(DofDepthShader())
        Inputs(TaaBuffer.`final`, GBuffer.position, GBuffer.normal, TransparentResolvedBuffer.tSurface)
        Output(DofDepthBuffer.dofDepth)
      }

      Pass(.depthOfFieldTiles8)
      {
        Quad()
        Shader(DofTileCocShader())
        Inputs(DofDepthBuffer.dofDepth)
        Output(DofTiles8Buffer.dofTile8)
      }

      Pass(.depthOfFieldTiles)
      {
        Quad()
        Shader(DofTileMaxShader())
        Inputs(DofTiles8Buffer.dofTile8)
        Output(DofTilesBuffer.dofTileMax)
      }

      Pass(.depthOfFieldNeighbors)
      {
        Quad()
        Shader(DofNeighborMaxShader())
        Inputs(DofTilesBuffer.dofTileMax)
        Output(DofNeighborsBuffer.dofNeighborMax)
      }

      Pass(.depthOfFieldDownsample)
      {
        Quad()
        Shader(DofDownsampleShader())
        Inputs(TaaBuffer.`final`, DofDepthBuffer.dofDepth)
        Output(DofHalfSourceBuffer.dofHalfSource)
      }

      Pass(.depthOfFieldHalf)
      {
        Quad()
        Shader(DofGatherHalfShader())
        Inputs(DofHalfSourceBuffer.dofHalfSource, DofNeighborsBuffer.dofNeighborMax)
        Output(DofHalfBuffer.dofHalfColor)
      }

      Pass(.depthOfField)
      {
        Quad()
        Shader(DofGatherShader())
        Inputs(TaaBuffer.`final`, DofDepthBuffer.dofDepth, DofNeighborsBuffer.dofNeighborMax, DofHalfBuffer.dofHalfColor, DofHalfSourceBuffer.dofHalfSource)
        Output(DofBuffer.dofColor)
      }

      Pass(.depthOfFieldApply)
      {
        Quad()
        Shader(TaaCopyShader(source: .dof))
        Inputs(DofBuffer.dofColor)
        Output(TaaBuffer.`final`)
      }

      Pass(.motionTiles8)
      {
        Quad()
        Shader(MotionTile8Shader())
        Inputs(GBuffer.velocity, GBuffer.normal, TransparentAccumBuffer.tVelocity)
        Output(MotionTiles8Buffer.motionTile8)
      }

      Pass(.motionTiles)
      {
        Quad()
        Shader(MotionTileMaxShader())
        Inputs(MotionTiles8Buffer.motionTile8)
        Output(MotionTilesBuffer.motionTileMax)
      }

      Pass(.motionNeighbors)
      {
        Quad()
        Shader(MotionNeighborMaxShader())
        Inputs(MotionTilesBuffer.motionTileMax)
        Output(MotionNeighborsBuffer.motionNeighborMax)
      }

      Pass(.motionBlur)
      {
        Quad()
        Shader(MotionBlurShader())
        Inputs(TaaBuffer.`final`, GBuffer.velocity, GBuffer.normal, GBuffer.position, MotionNeighborsBuffer.motionNeighborMax, TransparentAccumBuffer.tVelocity)
        Output(MotionBlurBuffer.motionBlurred)
      }

      Pass(.motionBlurApply)
      {
        Quad()
        Shader(TaaCopyShader(source: .blurred))
        Inputs(MotionBlurBuffer.motionBlurred)
        Output(TaaBuffer.`final`)
      }

      for level in bloomDown.indices
      {
        let shader = BloomDownShader(level: level)
        Pass("bloom down \(level)")
        {
          Quad()
          Shader(shader)
          Inputs(shader.source)
          Output(bloomDown[level])
        }
      }

      for level in bloomUp.indices.reversed()
      {
        let shader = BloomUpShader(level: level)
        Pass("bloom up \(level)")
        {
          Quad()
          Shader(shader)
          Inputs(shader.sources)
          Output(bloomUp[level])
        }
      }

      Pass(.lensStreak)
      {
        Quad()
        Shader(LensStreakShader())
        Inputs(BloomDown1Buffer.bloomDown1)
        Output(LensStreakBuffer.lensStreakA)
      }

      Pass(.lensStreakWide)
      {
        Quad()
        Shader(LensStreakWideShader())
        Inputs(LensStreakBuffer.lensStreakA)
        Output(LensStreakWideBuffer.lensStreakWide)
      }

      Pass(.lensStreakLong)
      {
        Quad()
        Shader(LensStreakLongShader())
        Inputs(LensStreakWideBuffer.lensStreakWide)
        Output(LensStreakBuffer.lensStreakB)
      }

      Pass(.lensGhosts)
      {
        Quad()
        Shader(LensGhostsShader())
        Inputs(BloomDown1Buffer.bloomDown1)
        Output(LensGhostsBuffer.lensGhosts)
      }

      Pass(.bloomComposite)
      {
        Quad()
        Blend(.additive)
        Shader(BloomCompositeShader())
        Inputs(BloomUp0Buffer.bloomUp0, LensStreakBuffer.lensStreakB, LensGhostsBuffer.lensGhosts)
        Output(TaaBuffer.`final`)
      }

      Pass(.tonemap)
      {
        Quad()
        Shader(.agx)
        Inputs(TaaBuffer.`final`)
        Output(TonemapBuffer.tonemap)
      }

      Pass(.gridOverlay)
      {
        Quad()
        Blend(.alpha)
        Shader(GridOverlayShader())
        Inputs(GBuffer.position, GBuffer.normal, TransparentResolvedBuffer.tSurface)
        Output(TonemapBuffer.tonemap)
      }

      Pass(.probeBakeOverlay)
      {
        Callback(.drawProbeBake)
        Blend(.alpha)
        Output(TonemapBuffer.tonemap)
      }

      Pass(.outlineMask)
      {
        Callback(.drawOutlineMask)
        ClearDepth()
        ClearOutputs()
        DepthTest(.greater)
        WriteDepth()
        Shader(OutlineMaskShader())
        Inputs(GBuffer.position, GBuffer.normal)
        Output(OutlineMaskBuffer.outlineMask)
      }

      Pass(.outlineEdge)
      {
        Quad()
        Shader(OutlineEdgeShader())
        Inputs(OutlineMaskBuffer.outlineMask)
        Output(OutlineEdgeBuffer.outlineEdge)
      }

      Pass(.outlineSpan)
      {
        Quad()
        Shader(OutlineSpanShader())
        Inputs(OutlineEdgeBuffer.outlineEdge)
        Output(OutlineSpanBuffer.outlineSpan)
      }

      Pass(.outline)
      {
        Quad()
        Shader(OutlineCompositeShader())
        Inputs(TonemapBuffer.tonemap, OutlineSpanBuffer.outlineSpan, OutlineMaskBuffer.outlineMask, GBuffer.position, GBuffer.normal)
        Output(OutlineBuffer.outline)
      }

      Pass(.aov)
      {
        Quad()
        Shader(AovShader())
        Inputs(GBuffer.position, GBuffer.normal)
        Output(AovBuffer.self)
      }

      Pass(.blit)
      {
        Draw(.blit)
        Inputs(TonemapBuffer.tonemap)
        Output.visible
      }
    }
  }
}
