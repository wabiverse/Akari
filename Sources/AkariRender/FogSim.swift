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

public extension Akari
{
  /// A smoke simulation on the GPU with velocity and
  /// density on a grid over the bounds authored on a
  /// stage.
  final class FogSim
  {
    /// What a frame of the simulation sees, in world units (meters) and seconds.
    public struct Frame
    {
      public var enable = false
      public var boundsMin = SIMD3<Float>(-14, -12, -0.65)
      public var boundsMax = SIMD3<Float>(14, 12, 2.4)
      public var resolution = 192
      public var startFrame = 1.0
      public var substeps = 2
      public var pressureIterations = 24
      /// Frames simulated toward a frame a little ahead, the rest skipped over.
      public var catchUp = Int.max
      public var vorticity: Float = 2.5
      public var dissipation: Float = 0.15
      public var settle: Float = 0.12
      public var replenish: Float = 0.6
      public var damping: Float = 0.4
      /// The deck layer's base density per meter, floor, falloff, and its noise amount and scale.
      public var density: Float = 0.6
      public var floorHeight: Float = 0
      public var heightFalloff: Float = 0.15
      public var noiseAmount: Float = 0
      public var noiseScale: Float = 1.2
      public var wind = SIMD3<Float>(repeating: 0)
      public var zUp = true

      public init() {}
    }

    /// The simulated density, a 3D texture over `boundsMin`...`boundsMax`, 0 when not running.
    public private(set) var texture: GLuint = 0
    /// The simulated velocity (world units per second), a 3D texture over the same bounds.
    public private(set) var velocityTexture: GLuint = 0
    /// Per velocity cell, the share of the nearby lights that reaches it through the fog.
    public private(set) var visibilityTexture: GLuint = 0
    public private(set) var boundsMin = SIMD3<Float>(repeating: 0)
    public private(set) var boundsMax = SIMD3<Float>(repeating: 0)
    public private(set) var isActive = false
    /// The density grid's cell size in world units.
    public var densityCellSize: Float
    {
      densCell
    }

    private var dims = SIMD3<Int>(0, 0, 0)
    private var cellSize: Float = 0
    /// The density grid, `detail` times finer than the velocity's.
    private var densDims = SIMD3<Int>(0, 0, 0)
    private var densCell: Float = 0
    private var hat: GLuint = 0
    static let detail = 2
    private var vel: [GLuint] = [0, 0]
    private var dens: [GLuint] = [0, 0]
    private var pressure: [GLuint] = [0, 0]
    private var divergence: GLuint = 0
    private var curl: GLuint = 0
    private var current = 0
    private var densCurrent = 0
    private var frame: Double?
    private var layoutKey: [Double] = []
    private enum Kernel: Akari.ComputeKernelName
    {
      case advect, curl, confine, divergence, jacobi, project, reset, resetDensity, export, densityPredict, densityCorrect
      case exportVelocity, visibility

      static let label = "fogsim"

      var threadgroup: SIMD3<Int>
      {
        SIMD3(8, 8, 4)
      }

      var msl: String
      {
        switch self
        {
          case .advect: FogSim.advectMSL
          case .curl: FogSim.curlMSL
          case .confine: FogSim.confineMSL
          case .divergence: FogSim.divergenceMSL
          case .jacobi: FogSim.jacobiMSL
          case .project: FogSim.projectMSL
          case .reset: FogSim.resetMSL
          case .resetDensity: FogSim.resetDensityMSL
          case .export: FogSim.exportMSL
          case .densityPredict: FogSim.densityPredictMSL
          case .densityCorrect: FogSim.densityCorrectMSL
          case .exportVelocity: FogSim.exportVelocityMSL
          case .visibility: FogSim.visibilityMSL
        }
      }
    }

    private var kernels = Akari.ComputeKernels<Kernel>()
    private var failed = false

    public init() {}

    deinit
    {
      release()
    }

    /// Brings the simulation to `target`, from its start frame when it hasn't run there yet or
    /// was asked for an earlier frame, otherwise on from the last frame it reached. `frameAt`
    /// gives the settings at a frame, `disturbersAt` the disturbers at a time over a window.
    public func advance(to target: Double, framesPerSecond: Double,
                        frameAt: (Double) -> Frame,
                        disturbersAt: (_ time: Double, _ window: Double) -> [Float])
    {
      let first = frameAt(target)
      guard first.enable, !failed, prepareKernels()
      else
      {
        isActive = false
        return
      }

      let key = [Double(first.boundsMin.x), Double(first.boundsMin.y), Double(first.boundsMin.z),
                 Double(first.boundsMax.x), Double(first.boundsMax.y), Double(first.boundsMax.z),
                 Double(first.resolution), first.startFrame, Double(first.substeps), first.zUp ? 1 : 0,
                 Double(first.pressureIterations)]
      if key != layoutKey
      {
        guard allocate(first) else { isActive = false; return }
        layoutKey = key
        frame = nil
      }

      let start = first.startFrame.rounded()
      let goal = max(target.rounded(), start)
      if frame == nil || goal < frame!
      {
        reset(frameAt(start), seconds: start / framesPerSecond)
        frame = start
      }

      let substeps = max(first.substeps, 1)
      let dt = Float(1 / (framesPerSecond * Double(substeps)))
      if let at = frame, goal - at > Double(first.catchUp), goal - at <= 48 { frame = goal - Double(first.catchUp) }
      let warmUp = goal - (frame ?? start) > 1
      while let at = frame, at < goal
      {
        let next = at + 1
        let settings = frameAt(next)
        for k in 0 ..< substeps
        {
          let time = at + Double(k + 1) / Double(substeps)
          step(settings, dt: dt, seconds: time / framesPerSecond,
               disturbers: disturbersAt(time, 1 / Double(substeps)))
        }

        frame = next
        // a warm up of hundreds of frames goes to the GPU one frame at a time.
        if warmUp { if Int(next) % 8 == 0 { gl.finish() } else { gl.flush() } }
      }

      export()
      isActive = true
    }

    private func prepareKernels() -> Bool
    {
      if !kernels.isEmpty { return true }
      kernels = .precompile()
      let failed = kernels.wait()
      guard failed.isEmpty
      else
      {
        print("[akari] fog sim: kernels \(failed) failed to compile")
        kernels.release()
        self.failed = true
        return false
      }

      return true
    }

    private func allocate(_ settings: Frame) -> Bool
    {
      releaseBuffers()
      let extent = pointwiseMax(settings.boundsMax - settings.boundsMin, SIMD3(repeating: 0.01))
      let along = settings.zUp ? extent : SIMD3(extent.x, extent.z, extent.y)
      cellSize = along.x / Float(max(settings.resolution, 8))
      dims = SIMD3(max(Int((along.x / cellSize).rounded()), 4),
                   max(Int((along.y / cellSize).rounded()), 4),
                   max(Int((along.z / cellSize).rounded()), 4))
      boundsMin = settings.boundsMin
      boundsMax = settings.boundsMax
      densDims = dims &* Self.detail
      densCell = cellSize / Float(Self.detail)
      let cells = dims.x * dims.y * dims.z
      let densCells = densDims.x * densDims.y * densDims.z
      let usage = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
      vel = (0 ..< 2).map { _ in gl.createBuffer(usage: usage, sizeBytes: GLsizei(cells * 16)) }
      dens = (0 ..< 2).map { _ in gl.createBuffer(usage: usage, sizeBytes: GLsizei(densCells * 4)) }
      hat = gl.createBuffer(usage: usage, sizeBytes: GLsizei(densCells * 4))
      pressure = (0 ..< 2).map { _ in gl.createBuffer(usage: usage, sizeBytes: GLsizei(cells * 4)) }
      divergence = gl.createBuffer(usage: usage, sizeBytes: GLsizei(cells * 4))
      curl = gl.createBuffer(usage: usage, sizeBytes: GLsizei(cells * 16))

      texture = makeVolume(GLint(GL_R16F), GLenum(GL_RED), size: densDims)
      visibilityTexture = makeVolume(GLint(GL_R16F), GLenum(GL_RED), size: dims)
      velocityTexture = makeVolume(GLint(GL_RGBA16F), GL_RGBA, size: dims)
      print("[akari] fog sim: velocity \(dims.x)x\(dims.y)x\(dims.z) of \(cellSize) m, density \(densDims.x)x\(densDims.y)x\(densDims.z)")
      return vel.allSatisfy { $0 != 0 } && texture != 0
    }

    private func grid(_ kernel: Akari.ComputeKernel, zUp: Bool, density: Bool = false)
    {
      let d = density ? densDims : dims
      kernel.set(.grid, SIMD4<Float>(Float(d.x), Float(d.y), Float(d.z), density ? densCell : cellSize))
      kernel.set(.origin, SIMD4<Float>(boundsMin, zUp ? 1 : 0))
    }

    private func makeVolume(_ internalFormat: GLint, _ format: GLenum, size: SIMD3<Int>) -> GLuint
    {
      var texture: GLuint = 0
      gl.genTextures(count: 1, textures: &texture)
      gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: texture)
      for (pname, param) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR),
                             (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE),
                             (GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)]
      {
        gl.texParameter(target: GLenum(GL_TEXTURE_3D), pname: GLenum(pname), param: GLint(param))
      }

      gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: internalFormat,
                    width: GLsizei(size.x), height: GLsizei(size.y), depth: GLsizei(size.z), border: 0,
                    format: format, type: GLenum(GL_HALF_FLOAT), pixels: nil)

      return texture
    }

    private func dispatch(_ kernel: Akari.ComputeKernel, density: Bool = false)
    {
      let d = density ? densDims : dims
      kernel.dispatch((d.x + 7) / 8, (d.y + 7) / 8, (d.z + 3) / 4)
    }

    private func layer(_ s: Frame) -> SIMD4<Float>
    {
      SIMD4(s.floorHeight - (s.zUp ? boundsMin.z : boundsMin.y), s.heightFalloff, s.density, s.replenish)
    }

    private func reset(_ s: Frame, seconds: Double)
    {
      let k = kernels[.reset]
      current = 0
      grid(k, zUp: s.zUp)
      k.set(.step, SIMD4(0, Float(seconds), 0, 0))
      k.set(.wind, SIMD4(s.wind, 0.3))
      k.set(.layer, layer(s))
      k.set(.noise, SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      k.bind(vel[0])
      k.bind(pressure[0], at: 2)
      dispatch(k)
      let kd = kernels[.resetDensity]
      grid(kd, zUp: s.zUp, density: true)
      kd.set(.step, SIMD4(0, Float(seconds), 0, 0))
      kd.set(.wind, SIMD4(s.wind, 0.3))
      kd.set(.layer, layer(s))
      kd.set(.noise, SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      kd.bind(dens[0], at: 1)
      dispatch(kd, density: true)
      densCurrent = 0
    }

    private func step(_ s: Frame, dt: Float, seconds: Double, disturbers: [Float])
    {
      let advect = kernels[.advect], curlK = kernels[.curl], confine = kernels[.confine]
      let div = kernels[.divergence], jacobi = kernels[.jacobi], project = kernels[.project]
      let a = current, b = 1 - current

      grid(advect, zUp: s.zUp)
      let count = min(disturbers.count / 8, Self.maxDisturbers)
      advect.set(.step, SIMD4(dt, Float(seconds), Float(count), 0))
      advect.set(.wind, SIMD4(s.wind, 0.3))
      advect.set(.layer, layer(s))
      advect.set(.noise, SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      advect.set(.sim, SIMD4(s.vorticity, s.dissipation, s.settle, s.damping))
      // uniforms pack in the order they're first set, so the sixteen slots fill `d[16]`.
      for slot in 0 ..< Self.maxDisturbers * 2
      {
        let o = slot * 4
        let value = o + 3 < count * 8
          ? SIMD4(disturbers[o], disturbers[o + 1], disturbers[o + 2], disturbers[o + 3]) : SIMD4<Float>(repeating: 0)
        advect.set(.d, index: slot, value)
      }

      advect.bind(vel[a])
      advect.bind(vel[b], at: 2)
      dispatch(advect)

      grid(curlK, zUp: s.zUp)
      curlK.bind(vel[b], curl)
      dispatch(curlK)

      grid(confine, zUp: s.zUp)
      confine.set(.step, SIMD4(dt, s.vorticity, 0, 0))
      confine.bind(curl, vel[b])
      dispatch(confine)

      grid(div, zUp: s.zUp)
      div.bind(vel[b], divergence)
      dispatch(div)

      grid(jacobi, zUp: s.zUp)
      for i in 0 ..< s.pressureIterations
      {
        jacobi.bind(pressure[i % 2], divergence, pressure[1 - i % 2])
        dispatch(jacobi)
      }

      grid(project, zUp: s.zUp)
      project.bind(pressure[s.pressureIterations % 2], vel[b])
      dispatch(project)
      current = b

      let predict = kernels[.densityPredict], correct = kernels[.densityCorrect]
      let vgrid = SIMD4<Float>(Float(dims.x), Float(dims.y), Float(dims.z), cellSize)
      let da = densCurrent, db = 1 - densCurrent
      grid(predict, zUp: s.zUp, density: true)
      predict.set(.vgrid, vgrid)
      predict.set(.step, SIMD4(dt, Float(seconds), 0, 0))
      predict.set(.sim, SIMD4(s.vorticity, s.dissipation, s.settle, s.damping))
      predict.bind(vel[b], dens[da], hat)
      dispatch(predict, density: true)

      grid(correct, zUp: s.zUp, density: true)
      correct.set(.vgrid, vgrid)
      correct.set(.step, SIMD4(dt, Float(seconds), 0, 0))
      correct.set(.sim, SIMD4(s.vorticity, s.dissipation, s.settle, s.damping))
      correct.set(.wind, SIMD4(s.wind, 0.3))
      correct.set(.layer, layer(s))
      correct.set(.noise, SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      correct.bind(vel[b], dens[da], hat, dens[db])
      dispatch(correct, density: true)
      densCurrent = db
    }

    private func export()
    {
      let k = kernels[.export]
      grid(k, zUp: true, density: true)
      k.bind(dens[densCurrent])
      k.image(texture, at: 0, format: GLenum(GL_R16F))
      dispatch(k, density: true)
      let kv = kernels[.exportVelocity]
      grid(kv, zUp: layoutKey.last == 1)
      kv.bind(vel[current])
      kv.image(velocityTexture, at: 0, format: GLenum(GL_RGBA16F))
      dispatch(kv)
    }

    /// The fog's shadowing of up to four `lights` at their positions this frame.
    public func computeVisibility(lights: [Akari.Lux.PointLight])
    {
      guard isActive, visibilityTexture != 0 else { return }
      let k = kernels[.visibility]
      grid(k, zUp: layoutKey.last == 1)
      k.set(.dgrid, SIMD4(Float(densDims.x), Float(densDims.y), Float(densDims.z), densCell))
      for slot in 0 ..< 4
      {
        let light = slot < lights.count ? lights[slot] : nil
        k.set(.l, index: slot * 2, SIMD4(light?.position ?? .zero, light.map { $0.intensity * $0.color.max() } ?? 0))
        k.set(.l, index: slot * 2 + 1, SIMD4(light?.color ?? .zero, light?.radius ?? 1))
      }

      k.set(.count, SIMD4(Float(min(lights.count, 4)), 0, 0, 0))
      k.bind(dens[densCurrent])
      k.image(visibilityTexture, at: 0, format: GLenum(GL_R16F))
      dispatch(k)
    }

    private func releaseBuffers()
    {
      for buffer in vel + dens + pressure + [divergence, curl, hat] where buffer != 0
      {
        gl.deleteBuffer(buffer)
      }

      vel = [0, 0]; dens = [0, 0]; pressure = [0, 0]; divergence = 0; curl = 0; hat = 0
      if texture != 0 { gl.deleteTextures(count: 1, textures: &texture); texture = 0 }
      if velocityTexture != 0 { gl.deleteTextures(count: 1, textures: &velocityTexture); velocityTexture = 0 }
      if visibilityTexture != 0 { gl.deleteTextures(count: 1, textures: &visibilityTexture); visibilityTexture = 0 }
    }

    public func release()
    {
      releaseBuffers()
      kernels.release()
      layoutKey = []
      frame = nil
      isActive = false
    }
  }
}
