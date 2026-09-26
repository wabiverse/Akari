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
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  struct Volumetrics
  {
    var thisFrame = false
    var passesActive = true
    /// This frame's froxel grid, for the shadow pass volume usage tagging.
    var froxels: Akari.ShadowAtlas.VolumeFroxels?
    /// The `u_volume` / `u_volumeRange` this frame wants, and what the graph last received.
    var pending = SIMD4<Float>(repeating: 0)
    var pendingRange = SIMD4<Float>(repeating: 0)
    var uploaded = SIMD4<Float>(repeating: .nan)
    var uploadedRange = SIMD4<Float>(repeating: .nan)
    var pendingSunLevelBias: Float = 0
    var uploadedSunLevelBias: Float = .nan
    var boundFroxelDepth: GLuint = 0
    /// Read by the `volume-integrate` callback.
    var grid = SIMD2<Int>(0, 0)
    var scatterTexture: GLuint = 0
    var integratedTexture: GLuint = 0
  }

  private static let volumePassNames = [
    "volume scatter",
    "volume integrate"
  ]

  /// The froxel grid is 8x8 depth slices packed into the half resolution volume atlas.
  private static let volumeSliceColumns = 8
  private static let volumeAtlasScale = 2

  /// Turns on froxel volumetrics for this frame.
  ///
  /// - Parameters:
  ///   - camera: the (jittered) camera the resolve's `u_invProj` inverts.
  ///   - volume: density, phase anisotropy, reach and self shadowing of the fog.
  public func setVolumetrics(camera: Akari.Camera, volume: VolumeSettings)
  {
    guard camera.projection[2, 3] < -0.5 else { return }
    let a = camera.projection[2, 2]
    let b = camera.projection[3, 2]

    let clipNear = abs(b / (a - 1))
    let clipFar = abs(a + 1) > 1e-7 ? abs(b / (a + 1)) : .infinity
    let far = clipFar.isFinite ? min(clipFar, volume.maxDistance) : volume.maxDistance
    guard clipNear.isFinite, far.isFinite, far > clipNear else { return }

    let tileDivisor = Self.volumeAtlasScale * Self.volumeSliceColumns
    let grid = SIMD2<Float>(Float(max(lastWidth / tileDivisor, 1)),
                            Float(max(lastHeight / tileDivisor, 1)))

    let density = max(volume.density, 0)
    guard density > 0 else { return }

    let gridSize = SIMD2<Int>(Int(grid.x), Int(grid.y))
    let gbufferPosition = runtime.texture("gbuffer", named: "position")
    guard froxelVolume.reduceDepth(gbufferPosition: gbufferPosition,
                                   gridWidth: gridSize.x,
                                   gridHeight: gridSize.y,
                                   screenWidth: lastWidth,
                                   screenHeight: lastHeight)
    else { return }
    if froxelVolume.depthTexture != volumetrics.boundFroxelDepth
    {
      volumetrics.boundFroxelDepth = froxelVolume.depthTexture
      setSampler("u_froxelDepth", volumetrics.boundFroxelDepth)
    }
    
    let sunLevelBias = max(volume.sunShadowLevelBias, 0)

    volumetrics.pending = SIMD4(density,
                                min(max(volume.anisotropy, -0.95), 0.95),
                                1,
                                volume.shadows ? 1 : 0)
    volumetrics.pendingRange = SIMD4(clipNear, far, grid.x, grid.y)
    volumetrics.pendingSunLevelBias = Float(sunLevelBias)
    volumetrics.grid = gridSize
    volumetrics.thisFrame = true
    volumetrics.froxels = Akari.ShadowAtlas.VolumeFroxels(gridWidth: gridSize.x,
                                                          gridHeight: gridSize.y,
                                                          near: clipNear,
                                                          far: far,
                                                          inverseProjection: camera.projection.inverse(),
                                                          depthTexture: froxelVolume.depthTexture,
                                                          sunLevelBias: sunLevelBias)
  }

  func attachVolumetrics()
  {
    runtime.setPassCallback("volume-integrate", callback: akariVolumeIntegrateCallback,
                            userdata: Unmanaged.passUnretained(self).toOpaque())
  }

  /// Pushes this frame's volume state into the graph before it renders.
  func syncVolumetrics()
  {
    let thisFrame = volumetrics.thisFrame
    if thisFrame != volumetrics.passesActive
    {
      setPasses(Self.volumePassNames, active: thisFrame)
      volumetrics.passesActive = thisFrame
    }
    let volume = thisFrame ? volumetrics.pending : .zero
    if volume != volumetrics.uploaded
    {
      setVector("u_volume", volume)
      volumetrics.uploaded = volume
    }
    if thisFrame
    {
      if volumetrics.pendingRange != volumetrics.uploadedRange
      {
        setVector("u_volumeRange", volumetrics.pendingRange)
        volumetrics.uploadedRange = volumetrics.pendingRange
      }
      if volumetrics.pendingSunLevelBias != volumetrics.uploadedSunLevelBias
      {
        setFloat("u_volumeSunLevelBias", volumetrics.pendingSunLevelBias)
        volumetrics.uploadedSunLevelBias = volumetrics.pendingSunLevelBias
      }
      volumetrics.scatterTexture = runtime.texture("volumeScatter", named: "volumeScatter")
      volumetrics.integratedTexture = runtime.texture("volumeIntegrated", named: "volumeIntegrated")
    }
  }

  fileprivate func integrateVolume()
  {
    froxelVolume.integrate(scatter: volumetrics.scatterTexture,
                           integrated: volumetrics.integratedTexture,
                           gridWidth: volumetrics.grid.x,
                           gridHeight: volumetrics.grid.y)
  }
}

private func akariVolumeIntegrateCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().integrateVolume()
}
