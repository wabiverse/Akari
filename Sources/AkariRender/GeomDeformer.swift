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
import HdAkari
import LabGL
import OpenUSDKit

public extension Akari.Geom
{
  /// Deforms the animated meshes on the GPU. Their triangulation is laid out
  /// once into buffers a capture records against, then each frame only their
  /// points and matrices are uploaded and compute rebuilds normals and the
  /// world space vertices in place, the same layout `Batch` writes.
  final class Deformer
  {
    private struct Mesh
    {
      var key: UInt64
      var topologyRevision: UInt64
      var flipWinding: Bool
      var pointCount: Int
      var pointBase: Int
      var cornerBase: Int
      var cornerCount: Int
      var dataRevision: UInt64 = .max
      var worldMatrix: [Float] = []
    }

    /// The per mesh matrices, world (16), normal (9) and prim id, padded.
    private static let xfStride = 32
    private static let ring = 3

    private var meshes: [Mesh] = []
    /// Every mesh the layout was built from, empty ones too, by what a rebuild keys on.
    private var inputs: [UInt64: Input] = [:]

    private struct Input
    {
      var topologyRevision: UInt64
      var flipWinding: Bool
      var pointCount: Int
      var tris: Pixar.VtVec3iArray
      var uvs: Pixar.VtVec2fArray
    }

    private var topologies: [UInt64: (revision: UInt64, topology: Akari.Geom.Topology)] = [:]
    private var pointCount = 0
    private var faceCount = 0
    private var cornerCount = 0

    private var faces: GLuint = 0
    private var corners: GLuint = 0
    private var uvs: GLuint = 0
    private var faceStart: GLuint = 0
    private var faceList: GLuint = 0
    private var pointMesh: GLuint = 0
    private var faceNormals: GLuint = 0
    private var pointNormals: GLuint = 0
    private var points: [GLuint] = []
    private var transforms: [GLuint] = []
    private var cursor = 0
    /// The vertex buffer compute writes, owned by the capture once recorded.
    private var vertices: GLuint = 0

    private var faceKernel: GLuint = 0
    private var pointKernel: GLuint = 0
    private var emitKernel: GLuint = 0

    public init() {}

    deinit
    {
      releaseBuffers()
      for kernel in [faceKernel, pointKernel, emitKernel] where kernel != 0
      {
        gl.deleteComputeShader(kernel)
      }
    }

    /// Whether `meshes` need relaying out (other meshes, or one's triangles changed).
    public func needsRebuild(_ meshes: [Recorder.RawMesh]) -> Bool
    {
      let meshes = Self.unique(meshes)
      guard meshes.count == inputs.count else { return true }
      for mesh in meshes
      {
        guard
          let old = inputs[mesh.key],
          old.flipWinding == mesh.flipWinding,
          old.pointCount == mesh.points.size()
        else { return true }
        guard old.topologyRevision != mesh.topologyRevision else { continue }

        // a resync can bump the revision with the same triangles, only a real change relays out.
        guard Pixar.HdAkariSameTopology(old.tris, mesh.tris, old.uvs, mesh.uvs) else { return true }
        inputs[mesh.key]?.topologyRevision = mesh.topologyRevision
        if let cached = topologies[mesh.key] { topologies[mesh.key] = (mesh.topologyRevision, cached.topology) }
      }
      return false
    }

    /// Lays `meshes` out and records their draws into `capture`, one per mesh.
    public func rebuild(_ meshes: [Recorder.RawMesh], into capture: OpaquePointer)
    {
      let meshes = Self.unique(meshes)
      guard ensureKernels() else { return }
      releaseBuffers()
      labgl.captureClear(capture)
      self.meshes = []
      inputs = Dictionary(meshes.map
      {
        ($0.key, Input(topologyRevision: $0.topologyRevision,
                       flipWinding: $0.flipWinding,
                       pointCount: $0.points.size(),
                       tris: $0.tris,
                       uvs: $0.uvs))
      }, uniquingKeysWith: { a, _ in a })

      var faceData: [Int32] = []
      var cornerData: [Int32] = []
      var uvData: [Float] = []
      var startData: [Int32] = [0]
      var listData: [Int32] = []
      var meshOfPoint: [Int32] = []
      var live = Set<UInt64>()

      for mesh in meshes
      {
        let count = mesh.points.size()
        let topology: Akari.Geom.Topology
        if let cached = topologies[mesh.key],
           cached.revision == mesh.topologyRevision,
           cached.topology.vertexFaceStart.count == count + 1
        {
          topology = cached.topology
        }
        else
        {
          let (_, tris, uvs) = Akari.Geom.flatten(points: Pixar.VtVec3fArray(), tris: mesh.tris, uvs: mesh.uvs)
          topology = Akari.Geom.topology(trisFlat: tris, uvsFlat: uvs, pointCount: count)
          topologies[mesh.key] = (mesh.topologyRevision, topology)
        }
        live.insert(mesh.key)

        let triCount = topology.triIndices.count / 3
        guard count > 0, triCount > 0 else { continue }

        let pointBase = pointCount, faceBase = faceCount, cornerBase = cornerCount
        let meshIndex = Int32(self.meshes.count)
        for t in 0 ..< triCount
        {
          let i = (0 ..< 3).map { Int(topology.triIndices[t * 3 + $0]) }
          let valid = i.allSatisfy { $0 >= 0 && $0 < count }
          faceData += valid ? [Int32(pointBase + i[0]),
                               Int32(pointBase + i[1]),
                               Int32(pointBase + i[2]),
                               meshIndex]
            : [-1, -1, -1, meshIndex]
          for c in mesh.flipWinding ? [0, 2, 1] : [0, 1, 2]
          {
            cornerData += [Int32(pointBase + (valid ? i[c] : 0)), Int32(faceBase + t)]
            uvData += [topology.triUvs[(t * 3 + c) * 2], topology.triUvs[(t * 3 + c) * 2 + 1]]
          }
        }
        for p in 0 ..< count
        {
          for k in Int(topology.vertexFaceStart[p]) ..< Int(topology.vertexFaceStart[p + 1])
          {
            listData.append(Int32(faceBase) + topology.vertexFaces[k])
          }
          startData.append(Int32(listData.count))
          meshOfPoint.append(meshIndex)
        }

        self.meshes.append(Mesh(key: mesh.key,
                                topologyRevision: mesh.topologyRevision,
                                flipWinding: mesh.flipWinding,
                                pointCount: count,
                                pointBase: pointBase,
                                cornerBase: cornerBase,
                                cornerCount: triCount * 3))
        pointCount += count
        faceCount += triCount
        cornerCount += triCount * 3
      }
      topologies = topologies.filter { live.contains($0.key) }
      guard cornerCount > 0 else { return }

      let read = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE
      faces = upload(faceData, read)
      corners = upload(cornerData, read)
      uvs = upload(uvData, read)
      faceStart = upload(startData, read)
      faceList = upload(listData.isEmpty ? [0] : listData, read)
      pointMesh = upload(meshOfPoint, read)

      let scratch = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
      faceNormals = gl.createBuffer(usage: scratch, sizeBytes: GLsizei(faceCount * 16))
      pointNormals = gl.createBuffer(usage: scratch, sizeBytes: GLsizei(pointCount * 16))
      points = (0 ..< Self.ring).map { _ in gl.createBuffer(usage: read, sizeBytes: GLsizei(pointCount * 12)) }
      transforms = (0 ..< Self.ring).map
      { _ in
        gl.createBuffer(usage: read, sizeBytes: GLsizei(self.meshes.count * Self.xfStride * 4))
      }

      record(into: capture)
    }

    /// Uploads this frame's points and matrices and deforms on the GPU.
    /// Returns the bounds, per mesh caster bounds and keys, in draw order.
    public func update(_ meshes: [Recorder.RawMesh]) -> (bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?,
                                                         casterBounds: [Float], casterKeys: [UInt64])
    {
      guard
        cornerCount > 0,
        !points.isEmpty
      else { return (nil, [], []) }

      cursor = (cursor + 1) % Self.ring
      guard
        let pointPtr = gl.mapBuffer(points[cursor])?.assumingMemoryBound(to: Float.self),
        let xfPtr = gl.mapBuffer(transforms[cursor])?.assumingMemoryBound(to: Float.self)
      else { return (nil, [], []) }

      let byID = Dictionary(meshes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
      var casterBounds: [Float] = []
      var casterKeys: [UInt64] = []
      casterBounds.reserveCapacity(self.meshes.count * 6)
      var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo

      for (index, laidOut) in self.meshes.enumerated()
      {
        guard let mesh = byID[laidOut.key] else { continue }
        var local = [Float](repeating: 0, count: 6)
        Pixar.HdAkariCopyPoints(mesh.points, pointPtr + laidOut.pointBase * 3, &local)

        let xf = xfPtr + index * Self.xfStride
        let m = mesh.worldMatrix
        for k in 0 ..< 16
        {
          xf[k] = m[k]
        }
        for k in 0 ..< 9
        {
          xf[16 + k] = mesh.normalMatrix[k]
        }
        xf[25] = Float(mesh.primId)

        var wlo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), whi = -wlo
        for corner in 0 ..< 8
        {
          let p = SIMD3(corner & 1 != 0 ? local[3] : local[0],
                        corner & 2 != 0 ? local[4] : local[1],
                        corner & 4 != 0 ? local[5] : local[2])
          let w = SIMD3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                        m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                        m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
          wlo = pointwiseMin(wlo, w)
          whi = pointwiseMax(whi, w)
        }
        casterBounds += [wlo.x, wlo.y, wlo.z, whi.x, whi.y, whi.z]
        lo = pointwiseMin(lo, wlo)
        hi = pointwiseMax(hi, whi)

        var key = (14_695_981_039_346_656_037 ^ mesh.dataRevision) &* 1_099_511_628_211
        for value in m
        {
          key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
        }
        casterKeys.append(key)
      }
      gl.unmapBuffer(points[cursor])
      gl.unmapBuffer(transforms[cursor])

      dispatch()
      return (lo.x <= hi.x ? (lo, hi) : nil, casterBounds, casterKeys)
    }

    private func dispatch()
    {
      setCount(faceKernel, faceCount)
      gl.setComputeShaderBuffer(faceKernel, binding: 0, buffer: faces)
      gl.setComputeShaderBuffer(faceKernel, binding: 1, buffer: points[cursor])
      gl.setComputeShaderBuffer(faceKernel, binding: 2, buffer: faceNormals)
      gl.dispatchCompute(faceKernel, groupsX: GLuint((faceCount + 63) / 64), groupsY: 1, groupsZ: 1)

      setCount(pointKernel, pointCount)
      gl.setComputeShaderBuffer(pointKernel, binding: 0, buffer: faceStart)
      gl.setComputeShaderBuffer(pointKernel, binding: 1, buffer: faceList)
      gl.setComputeShaderBuffer(pointKernel, binding: 2, buffer: faceNormals)
      gl.setComputeShaderBuffer(pointKernel, binding: 3, buffer: pointNormals)
      gl.dispatchCompute(pointKernel, groupsX: GLuint((pointCount + 63) / 64), groupsY: 1, groupsZ: 1)

      setCount(emitKernel, cornerCount)
      gl.setComputeShaderBuffer(emitKernel, binding: 0, buffer: corners)
      gl.setComputeShaderBuffer(emitKernel, binding: 1, buffer: uvs)
      gl.setComputeShaderBuffer(emitKernel, binding: 2, buffer: points[cursor])
      gl.setComputeShaderBuffer(emitKernel, binding: 3, buffer: pointNormals)
      gl.setComputeShaderBuffer(emitKernel, binding: 4, buffer: faceNormals)
      gl.setComputeShaderBuffer(emitKernel, binding: 5, buffer: pointMesh)
      gl.setComputeShaderBuffer(emitKernel, binding: 6, buffer: transforms[cursor])
      gl.setComputeShaderBuffer(emitKernel, binding: 7, buffer: vertices)
      gl.dispatchCompute(emitKernel, groupsX: GLuint((cornerCount + 63) / 64), groupsY: 1, groupsZ: 1)
    }

    /// Records one draw per mesh against the vertex buffer compute fills,
    /// the capture takes the vertex and index buffers over at their unmap.
    private func record(into capture: OpaquePointer)
    {
      let stride = Batch.vertexStride
      vertices = gl.createBuffer(usage: LGL_BUFFER_VERTEX | LGL_BUFFER_COMPUTE_WRITE | LGL_BUFFER_MAP_WRITE
        | LGL_BUFFER_CAPTURE_ADOPT,
        sizeBytes: GLsizei(cornerCount * stride))
      let indices = gl.createBuffer(usage: LGL_BUFFER_INDEX | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT,
                                    sizeBytes: GLsizei(cornerCount * 4))
      guard vertices != 0, indices != 0 else { return }
      if let p = gl.mapBuffer(indices)?.assumingMemoryBound(to: Int32.self)
      {
        for i in 0 ..< cornerCount
        {
          p[i] = Int32(i)
        }
      }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
      labgl.captureStart(capture)
      _ = gl.mapBuffer(vertices)
      gl.unmapBuffer(vertices)
      gl.unmapBuffer(indices)

      gl.enable(GL_DEPTH_TEST)
      gl.depthFunc(GLenum(GL_GREATER))
      gl.enable(GL_CULL_FACE)
      gl.cullFace(GL_BACK)
      gl.frontFace(GL_CCW)

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: vertices)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: indices)
      gl.enableClientState(GL_VERTEX_ARRAY)
      gl.enableClientState(GL_COLOR_ARRAY)
      gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.enableClientState(GL_NORMAL_ARRAY)
      let floatBytes = MemoryLayout<Float>.stride
      gl.vertexPointer(size: 4, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 0 * floatBytes))
      gl.colorPointer(size: 4, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 4 * floatBytes))
      gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 8 * floatBytes))
      gl.normalPointer(type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 10 * floatBytes))

      // the real bounds arrive per frame, these only keep the capture from scanning.
      let unbounded: [Float] = [-1e30, -1e30, -1e30, 1e30, 1e30, 1e30]
      for mesh in meshes
      {
        unbounded.withUnsafeBufferPointer { labgl.captureNextDrawBounds($0.baseAddress!) }
        gl.drawElements(mode: GL_TRIANGLES,
                        count: Int32(mesh.cornerCount),
                        type: GL_UNSIGNED_INT,
                        indices: .init(bitPattern: mesh.cornerBase * 4))
      }

      gl.disableClientState(GL_NORMAL_ARRAY)
      gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.disableClientState(GL_COLOR_ARRAY)
      gl.disableClientState(GL_VERTEX_ARRAY)
      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: 0)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: 0)
      labgl.captureStop()
    }

    /// The first of any meshes sharing an id.
    private static func unique(_ meshes: [Recorder.RawMesh]) -> [Recorder.RawMesh]
    {
      var seen = Set<UInt64>()
      return meshes.filter { seen.insert($0.key).inserted }
    }

    private func upload<T>(_ values: [T], _ usage: GLuint) -> GLuint
    {
      let buffer = gl.createBuffer(usage: usage, sizeBytes: GLsizei(max(values.count, 1) * MemoryLayout<T>.stride))
      if let p = gl.mapBuffer(buffer)
      {
        values.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        gl.unmapBuffer(buffer)
      }
      return buffer
    }

    private func setCount(_ kernel: GLuint, _ count: Int)
    {
      var params = SIMD4<Int32>(Int32(count), 0, 0, 0)
      gl.setComputeShaderUniform(kernel, name: "u_params", type: GL_INT_VEC4, data: &params)
    }

    /// Everything but `vertices`, which the capture owns and frees on its clear.
    private func releaseBuffers()
    {
      for buffer in [faces, corners, uvs, faceStart, faceList, pointMesh, faceNormals, pointNormals]
        + points + transforms where buffer != 0
      {
        gl.deleteBuffer(buffer)
      }
      faces = 0; corners = 0; uvs = 0; faceStart = 0; faceList = 0; pointMesh = 0
      faceNormals = 0; pointNormals = 0; points = []; transforms = []; vertices = 0
      pointCount = 0; faceCount = 0; cornerCount = 0
    }

    private func ensureKernels() -> Bool
    {
      if faceKernel == 0
      {
        faceKernel = gl.precompileComputeShader(name: "akari-deform-faces", glsl: Self.faceGLSL, msl: Self.faceMSL)
        pointKernel = gl.precompileComputeShader(name: "akari-deform-points", glsl: Self.pointGLSL, msl: Self.pointMSL)
        emitKernel = gl.precompileComputeShader(name: "akari-deform-emit", glsl: Self.emitGLSL, msl: Self.emitMSL)
        for kernel in [faceKernel, pointKernel, emitKernel]
        {
          gl.setComputeShaderThreadgroupSize(kernel, x: 64, y: 1, z: 1)
        }
      }
      return [faceKernel, pointKernel, emitKernel].allSatisfy { $0 != 0 && gl.waitComputeShader($0) != 0 }
    }
  }
}

extension Akari.Geom.Deformer
{
  /// Per triangle: its unit normal, and its doubled area for the smooth weighting.
  static let faceBody = """
      if (int(gid) >= PARAMS.x) return;
      INT4 f = faces[gid];
      if (f.x < 0) { face_normals[gid] = VEC4(0.0); return; }
      VEC3 p0 = VEC3(points[f.x * 3], points[f.x * 3 + 1], points[f.x * 3 + 2]);
      VEC3 p1 = VEC3(points[f.y * 3], points[f.y * 3 + 1], points[f.y * 3 + 2]);
      VEC3 p2 = VEC3(points[f.z * 3], points[f.z * 3 + 1], points[f.z * 3 + 2]);
      VEC3 n = cross(p1 - p0, p2 - p0);
      float l = length(n);
      face_normals[gid] = l > 1e-8 ? VEC4(n / l, l) : VEC4(0.0);
    """

  /// Per point: the area weighted smooth normal, and whether its faces meet within 30°.
  static let pointBody = """
      if (int(gid) >= PARAMS.x) return;
      int s = face_start[gid], e = face_start[gid + 1];
      VEC3 sum = VEC3(0.0);
      for (int i = s; i < e; ++i) { VEC4 fn = face_normals[face_list[i]]; sum += fn.xyz * fn.w; }
      float sl = length(sum);
      VEC3 smooth_n = sl > 1e-8 ? sum / sl : VEC3(0.0, 1.0, 0.0);
      bool is_smooth = true;
      for (int a = s; a < e && is_smooth; ++a)
      {
        VEC4 na = face_normals[face_list[a]];
        if (na.w <= 0.0) continue;
        for (int b = a + 1; b < e; ++b)
        {
          VEC4 nb = face_normals[face_list[b]];
          if (nb.w <= 0.0) continue;
          if (dot(na.xyz, nb.xyz) <= 0.8660254) { is_smooth = false; break; }
        }
      }
      point_normals[gid] = VEC4(smooth_n, is_smooth ? 1.0 : 0.0);
    """

  /// Per triangle corner: the world space vertex `Batch` lays out.
  static let emitBody = """
      if (int(gid) >= PARAMS.x) return;
      INT2 c = corners[gid];
      int p = c.x;
      int base = point_mesh[p] * 32;
      VEC3 lp = VEC3(points[p * 3], points[p * 3 + 1], points[p * 3 + 2]);
      VEC4 pn = point_normals[p];
      VEC4 fn = face_normals[c.y];
      VEC3 n = (pn.w > 0.5 || fn.w <= 0.0) ? pn.xyz : fn.xyz;
      int o = int(gid) * 14;
      out_verts[o + 0] = xf[base + 0] * lp.x + xf[base + 4] * lp.y + xf[base + 8] * lp.z + xf[base + 12];
      out_verts[o + 1] = xf[base + 1] * lp.x + xf[base + 5] * lp.y + xf[base + 9] * lp.z + xf[base + 13];
      out_verts[o + 2] = xf[base + 2] * lp.x + xf[base + 6] * lp.y + xf[base + 10] * lp.z + xf[base + 14];
      out_verts[o + 3] = 1.0;
      out_verts[o + 4] = xf[base + 25];
      out_verts[o + 5] = 0.0;
      out_verts[o + 6] = 0.0;
      out_verts[o + 7] = 1.0;
      out_verts[o + 8] = uvs[gid].x;
      out_verts[o + 9] = uvs[gid].y;
      out_verts[o + 10] = xf[base + 16] * n.x + xf[base + 17] * n.y + xf[base + 18] * n.z;
      out_verts[o + 11] = xf[base + 19] * n.x + xf[base + 20] * n.y + xf[base + 21] * n.z;
      out_verts[o + 12] = xf[base + 22] * n.x + xf[base + 23] * n.y + xf[base + 24] * n.z;
      out_verts[o + 13] = 0.0;
    """

  static let glslPrelude = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    uniform ivec4 u_params;
    #define PARAMS u_params
    #define INT2 ivec2
    #define INT4 ivec4
    #define VEC3 vec3
    #define VEC4 vec4

    """

  static let mslPrelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 params; };
    #define PARAMS u.params
    #define INT2 int2
    #define INT4 int4
    #define VEC3 float3
    #define VEC4 float4

    """

  static let faceGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Faces { ivec4 faces[]; };
    layout(std430, binding = 1) buffer Points { float points[]; };
    layout(std430, binding = 2) buffer FaceNormals { vec4 face_normals[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(faceBody)
    }
    """

  static let faceMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int4* faces [[buffer(1)]],
                             device const float* points [[buffer(2)]],
                             device float4* face_normals [[buffer(3)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(faceBody)
    }
    """

  static let pointGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer FaceStart { int face_start[]; };
    layout(std430, binding = 1) buffer FaceList { int face_list[]; };
    layout(std430, binding = 2) buffer FaceNormals { vec4 face_normals[]; };
    layout(std430, binding = 3) buffer PointNormals { vec4 point_normals[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(pointBody)
    }
    """

  static let pointMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int* face_start [[buffer(1)]],
                             device const int* face_list [[buffer(2)]],
                             device const float4* face_normals [[buffer(3)]],
                             device float4* point_normals [[buffer(4)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(pointBody)
    }
    """

  static let emitGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Corners { ivec2 corners[]; };
    layout(std430, binding = 1) buffer Uvs { vec2 uvs[]; };
    layout(std430, binding = 2) buffer Points { float points[]; };
    layout(std430, binding = 3) buffer PointNormals { vec4 point_normals[]; };
    layout(std430, binding = 4) buffer FaceNormals { vec4 face_normals[]; };
    layout(std430, binding = 5) buffer PointMesh { int point_mesh[]; };
    layout(std430, binding = 6) buffer Xf { float xf[]; };
    layout(std430, binding = 7) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(emitBody)
    }
    """

  static let emitMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int2* corners [[buffer(1)]],
                             device const float2* uvs [[buffer(2)]],
                             device const float* points [[buffer(3)]],
                             device const float4* point_normals [[buffer(4)]],
                             device const float4* face_normals [[buffer(5)]],
                             device const int* point_mesh [[buffer(6)]],
                             device const float* xf [[buffer(7)]],
                             device float* out_verts [[buffer(8)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(emitBody)
    }
    """
}
