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
    private var kernels: [String: GLuint] = [:]
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
      let sources = ["advect": Self.advectMSL, "curl": Self.curlMSL, "confine": Self.confineMSL,
                     "divergence": Self.divergenceMSL, "jacobi": Self.jacobiMSL, "project": Self.projectMSL,
                     "reset": Self.resetMSL, "resetDensity": Self.resetDensityMSL, "export": Self.exportMSL,
                     "densityPredict": Self.densityPredictMSL, "densityCorrect": Self.densityCorrectMSL,
                     "exportVelocity": Self.exportVelocityMSL, "visibility": Self.visibilityMSL]
      var built: [String: GLuint] = [:]
      for (name, msl) in sources
      {
        let kernel = gl.precompileComputeShader(name: "akari-fogsim-\(name)", glsl: "", msl: msl)
        gl.setComputeShaderThreadgroupSize(kernel, x: 8, y: 8, z: 4)
        built[name] = kernel
      }
      for (name, kernel) in built where kernel == 0 || gl.waitComputeShader(kernel) == 0
      {
        print("[akari] fog sim: kernel \(name) failed to compile")
        built.values.filter { $0 != 0 }.forEach { gl.deleteComputeShader($0) }
        failed = true
        return false
      }
      kernels = built
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

      gl.genTextures(count: 1, textures: &texture)
      gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: texture)
      for (pname, param) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR),
                             (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE),
                             (GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)]
      {
        gl.texParameter(target: GLenum(GL_TEXTURE_3D), pname: GLenum(pname), param: GLint(param))
      }
      gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: GLint(GL_R16F),
                    width: GLsizei(densDims.x), height: GLsizei(densDims.y), depth: GLsizei(densDims.z), border: 0,
                    format: GLenum(GL_RED), type: GLenum(GL_HALF_FLOAT), pixels: nil)
      gl.genTextures(count: 1, textures: &visibilityTexture)
      gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: visibilityTexture)
      for (pname, param) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR),
                             (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE),
                             (GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)]
      {
        gl.texParameter(target: GLenum(GL_TEXTURE_3D), pname: GLenum(pname), param: GLint(param))
      }
      gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: GLint(GL_R16F),
                    width: GLsizei(dims.x), height: GLsizei(dims.y), depth: GLsizei(dims.z), border: 0,
                    format: GLenum(GL_RED), type: GLenum(GL_HALF_FLOAT), pixels: nil)
      gl.genTextures(count: 1, textures: &velocityTexture)
      gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: velocityTexture)
      for (pname, param) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR),
                             (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE),
                             (GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)]
      {
        gl.texParameter(target: GLenum(GL_TEXTURE_3D), pname: GLenum(pname), param: GLint(param))
      }
      gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: GLint(GL_RGBA16F),
                    width: GLsizei(dims.x), height: GLsizei(dims.y), depth: GLsizei(dims.z), border: 0,
                    format: GL_RGBA, type: GLenum(GL_HALF_FLOAT), pixels: nil)
      print("[akari] fog sim: velocity \(dims.x)x\(dims.y)x\(dims.z) of \(cellSize) m, density \(densDims.x)x\(densDims.y)x\(densDims.z)")
      return vel.allSatisfy { $0 != 0 } && texture != 0
    }

    private func grid(_ kernel: GLuint, zUp: Bool, density: Bool = false)
    {
      let d = density ? densDims : dims
      var g = SIMD4<Float>(Float(d.x), Float(d.y), Float(d.z), density ? densCell : cellSize)
      var o = SIMD4<Float>(boundsMin, zUp ? 1 : 0)
      gl.setComputeShaderUniform(kernel, name: "grid", type: GL_FLOAT_VEC4, data: &g)
      gl.setComputeShaderUniform(kernel, name: "origin", type: GL_FLOAT_VEC4, data: &o)
    }

    private func vector(_ kernel: GLuint, _ name: String, _ value: SIMD4<Float>)
    {
      var v = value
      gl.setComputeShaderUniform(kernel, name: name, type: GL_FLOAT_VEC4, data: &v)
    }

    private func dispatch(_ kernel: GLuint, density: Bool = false)
    {
      let d = density ? densDims : dims
      gl.dispatchCompute(kernel, groupsX: GLuint((d.x + 7) / 8), groupsY: GLuint((d.y + 7) / 8),
                         groupsZ: GLuint((d.z + 3) / 4))
    }

    private func layer(_ s: Frame) -> SIMD4<Float>
    {
      SIMD4(s.floorHeight - (s.zUp ? boundsMin.z : boundsMin.y), s.heightFalloff, s.density, s.replenish)
    }

    private func reset(_ s: Frame, seconds: Double)
    {
      guard let k = kernels["reset"] else { return }
      current = 0
      grid(k, zUp: s.zUp)
      vector(k, "step", SIMD4(0, Float(seconds), 0, 0))
      vector(k, "wind", SIMD4(s.wind, 0.3))
      vector(k, "layer", layer(s))
      vector(k, "noise", SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      gl.setComputeShaderBuffer(k, binding: 0, buffer: vel[0])
      gl.setComputeShaderBuffer(k, binding: 2, buffer: pressure[0])
      dispatch(k)
      guard let kd = kernels["resetDensity"] else { return }
      grid(kd, zUp: s.zUp, density: true)
      vector(kd, "step", SIMD4(0, Float(seconds), 0, 0))
      vector(kd, "wind", SIMD4(s.wind, 0.3))
      vector(kd, "layer", layer(s))
      vector(kd, "noise", SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      gl.setComputeShaderBuffer(kd, binding: 1, buffer: dens[0])
      dispatch(kd, density: true)
      densCurrent = 0
    }

    private func step(_ s: Frame, dt: Float, seconds: Double, disturbers: [Float])
    {
      guard let advect = kernels["advect"], let curlK = kernels["curl"], let confine = kernels["confine"],
            let div = kernels["divergence"], let jacobi = kernels["jacobi"], let project = kernels["project"]
      else { return }
      let a = current, b = 1 - current

      grid(advect, zUp: s.zUp)
      let count = min(disturbers.count / 8, Self.maxDisturbers)
      vector(advect, "step", SIMD4(dt, Float(seconds), Float(count), 0))
      vector(advect, "wind", SIMD4(s.wind, 0.3))
      vector(advect, "layer", layer(s))
      vector(advect, "noise", SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      vector(advect, "sim", SIMD4(s.vorticity, s.dissipation, s.settle, s.damping))
      // uniforms pack in the order they're first set, so the sixteen slots fill `d[16]`.
      for slot in 0 ..< Self.maxDisturbers * 2
      {
        let o = slot * 4
        let value = o + 3 < count * 8
          ? SIMD4(disturbers[o], disturbers[o + 1], disturbers[o + 2], disturbers[o + 3]) : SIMD4<Float>(repeating: 0)
        vector(advect, "d\(slot)", value)
      }
      gl.setComputeShaderBuffer(advect, binding: 0, buffer: vel[a])
      gl.setComputeShaderBuffer(advect, binding: 2, buffer: vel[b])
      dispatch(advect)

      grid(curlK, zUp: s.zUp)
      gl.setComputeShaderBuffer(curlK, binding: 0, buffer: vel[b])
      gl.setComputeShaderBuffer(curlK, binding: 1, buffer: curl)
      dispatch(curlK)

      grid(confine, zUp: s.zUp)
      vector(confine, "step", SIMD4(dt, s.vorticity, 0, 0))
      gl.setComputeShaderBuffer(confine, binding: 0, buffer: curl)
      gl.setComputeShaderBuffer(confine, binding: 1, buffer: vel[b])
      dispatch(confine)

      grid(div, zUp: s.zUp)
      gl.setComputeShaderBuffer(div, binding: 0, buffer: vel[b])
      gl.setComputeShaderBuffer(div, binding: 1, buffer: divergence)
      dispatch(div)

      grid(jacobi, zUp: s.zUp)
      for i in 0 ..< s.pressureIterations
      {
        gl.setComputeShaderBuffer(jacobi, binding: 0, buffer: pressure[i % 2])
        gl.setComputeShaderBuffer(jacobi, binding: 1, buffer: divergence)
        gl.setComputeShaderBuffer(jacobi, binding: 2, buffer: pressure[1 - i % 2])
        dispatch(jacobi)
      }

      grid(project, zUp: s.zUp)
      gl.setComputeShaderBuffer(project, binding: 0, buffer: pressure[s.pressureIterations % 2])
      gl.setComputeShaderBuffer(project, binding: 1, buffer: vel[b])
      dispatch(project)
      current = b

      guard let predict = kernels["densityPredict"], let correct = kernels["densityCorrect"] else { return }
      let vgrid = SIMD4<Float>(Float(dims.x), Float(dims.y), Float(dims.z), cellSize)
      let da = densCurrent, db = 1 - densCurrent
      grid(predict, zUp: s.zUp, density: true)
      vector(predict, "vgrid", vgrid)
      vector(predict, "step", SIMD4(dt, Float(seconds), 0, 0))
      vector(predict, "sim", SIMD4(s.vorticity, s.dissipation, s.settle, s.damping))
      gl.setComputeShaderBuffer(predict, binding: 0, buffer: vel[b])
      gl.setComputeShaderBuffer(predict, binding: 1, buffer: dens[da])
      gl.setComputeShaderBuffer(predict, binding: 2, buffer: hat)
      dispatch(predict, density: true)

      grid(correct, zUp: s.zUp, density: true)
      vector(correct, "vgrid", vgrid)
      vector(correct, "step", SIMD4(dt, Float(seconds), 0, 0))
      vector(correct, "sim", SIMD4(s.vorticity, s.dissipation, s.settle, s.damping))
      vector(correct, "wind", SIMD4(s.wind, 0.3))
      vector(correct, "layer", layer(s))
      vector(correct, "noise", SIMD4(s.noiseAmount, s.noiseScale, 0, 0))
      gl.setComputeShaderBuffer(correct, binding: 0, buffer: vel[b])
      gl.setComputeShaderBuffer(correct, binding: 1, buffer: dens[da])
      gl.setComputeShaderBuffer(correct, binding: 2, buffer: hat)
      gl.setComputeShaderBuffer(correct, binding: 3, buffer: dens[db])
      dispatch(correct, density: true)
      densCurrent = db
    }

    private func export()
    {
      guard let k = kernels["export"] else { return }
      grid(k, zUp: true, density: true)
      gl.setComputeShaderBuffer(k, binding: 0, buffer: dens[densCurrent])
      gl.setComputeShaderImage(k, index: 0, texture: texture, format: GLenum(GL_R16F), level: 0)
      dispatch(k, density: true)
      guard let kv = kernels["exportVelocity"] else { return }
      grid(kv, zUp: layoutKey.last == 1)
      gl.setComputeShaderBuffer(kv, binding: 0, buffer: vel[current])
      gl.setComputeShaderImage(kv, index: 0, texture: velocityTexture, format: GLenum(GL_RGBA16F), level: 0)
      dispatch(kv)
    }

    /// The fog's shadowing of up to four `lights` at their positions this frame.
    public func computeVisibility(lights: [Akari.Lux.PointLight])
    {
      guard isActive, visibilityTexture != 0, let k = kernels["visibility"] else { return }
      grid(k, zUp: layoutKey.last == 1)
      vector(k, "dgrid", SIMD4(Float(densDims.x), Float(densDims.y), Float(densDims.z), densCell))
      for slot in 0 ..< 4
      {
        let light = slot < lights.count ? lights[slot] : nil
        vector(k, "l\(slot * 2)", SIMD4(light?.position ?? .zero, light.map { $0.intensity * $0.color.max() } ?? 0))
        vector(k, "l\(slot * 2 + 1)", SIMD4(light?.color ?? .zero, light?.radius ?? 1))
      }
      vector(k, "count", SIMD4(Float(min(lights.count, 4)), 0, 0, 0))
      gl.setComputeShaderBuffer(k, binding: 0, buffer: dens[densCurrent])
      gl.setComputeShaderImage(k, index: 0, texture: visibilityTexture, format: GLenum(GL_R16F), level: 0)
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
      kernels.values.forEach { gl.deleteComputeShader($0) }
      kernels = [:]
      layoutKey = []
      frame = nil
      isActive = false
    }
  }
}
