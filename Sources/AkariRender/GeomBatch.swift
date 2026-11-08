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
import LabGL

public extension Akari.Geom
{
  /// Accumulates packed interleaved vertex/index data across meshes and
  /// flushes to a GPU buffer pair + draw call whenever either buffer would
  /// overflow, or on an explicit final `draw()`.
  final class Batch
  {
    public static let vertexFloats = 14
    public static let vertexStride = vertexFloats * MemoryLayout<Float>.stride // 56

    private let maxVerts: Int
    private let maxIndices: Int
    /// Keeps one mapped buffer pair from growing to gigabytes when a scene
    /// records hundreds of thousands of meshes in a single batch. Appending
    /// past either cap flushes first, the capture then replays every chunk.
    private static let batchVertexCap = 1 << 20
    private static let batchIndexCap = 3 << 20
    /// Where appending writes, which `draw()` hands the recording capture
    /// as a buffer pair mapped from a file, in memory when the disk is full.
    private var vertBuf: UnsafeMutablePointer<Float>?
    private var idxBuf: UnsafeMutablePointer<Int32>?
    private var vOff = 0
    private var iOff = 0
    /// Index ranges drawn separately so the shadow pass can cull by chunk.
    private static let chunkIndices = 6000
    private var chunkStarts: [Int] = [0]
    /// World bounds per chunk, min then max.
    private var chunkBounds: [Float] = Batch.emptyBounds
    private static let emptyBounds: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude,
                                               .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                                               -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    private var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    /// One world AABB per appended mesh, min then max, six floats each.
    public private(set) var casterBounds: [Float] = []
    /// Per caster, a key that changes whenever it moves or deforms.
    public private(set) var casterKeys: [UInt64] = []

    /// One prototype's index range, the instance set it draws with and how many of it.
    fileprivate struct InstanceGroup
    {
      var indexStart: Int
      var indexCount: Int
      var set: UInt64
      var count: Int
      /// Before each instance's transform, the culls.
      var bounds: [Float]
      var lod: SIMD2<Float>
    }

    private var instanceGroups: [InstanceGroup] = []
    /// How many of a prototype's own size across an instance caster cell is.
    private static let instancesPerCasterCell: Float = 8
    /// The sets this flush's groups draw with, each uploaded
    /// once, as far as the most of it any group draws.
    private var instanceSets: [UInt64: Akari.Geom.Matrices] = [:]
    private var liveSets: [UInt64: String] = [:]
    private var drawnInstances: [UInt64: Int] = [:]
    /// Each set's group still open to the next prototype's indices, per level of detail.
    private var openRuns: [SIMD4<UInt64>: Int] = [:]

    private let expands: Bool
    /// Prototype vertices stay in object space and each group draws once per transform.
    private let instanced: Bool
    /// Where each draw's triangles' Ptex faces go, and this flush's, a triangle each.
    private let ptexFaces: PtexFaces?
    private var triangleFaces: [UInt32] = []

    public init(vertexCount: Int, indexCount: Int,
                largestVertexCount: Int = 0, largestIndexCount: Int = 0,
                expands: Bool = false, instanced: Bool = false, ptexFaces: PtexFaces? = nil)
    {
      self.expands = expands
      self.instanced = instanced
      self.ptexFaces = ptexFaces
      // a single mesh larger than the cap still has to fit in its batch.
      maxVerts = min(max(expands ? indexCount : vertexCount, largestVertexCount, 1),
                     max(Self.batchVertexCap, largestVertexCount, 1),
                     Int(Int32.max) / Self.vertexStride)
      maxIndices = min(max(indexCount, largestIndexCount, 1),
                       max(Self.batchIndexCap, largestIndexCount, 1),
                       Int(Int32.max) / MemoryLayout<Int32>.stride)
    }

    deinit
    {
      vertBuf?.deallocate()
      idxBuf?.deallocate()
    }

    private var vertexCount: Int
    {
      vOff / Self.vertexFloats
    }

    public var indexCount: Int
    {
      iOff
    }

    /// World space bounds of everything appended so far,
    /// `nil` until the first vertex lands.
    public var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    {
      boundsMin.x <= boundsMax.x ? (boundsMin, boundsMax) : nil
    }

    private func ensureBuffers() -> Bool
    {
      if vertBuf != nil, idxBuf != nil { return true }
      vertBuf = .allocate(capacity: maxVerts * Self.vertexFloats)
      idxBuf = .allocate(capacity: maxIndices)
      return true
    }

    /// Appends one mesh's local-space vertex/index data,
    /// transforming positions/normals into world space
    /// as it writes straight into the GPU buffers.
    public func append(localVerts: UnsafeBufferPointer<Float>, localIndices: UnsafeBufferPointer<Int32>,
                       worldMatrix m: UnsafePointer<Float>,
                       normalMatrix n: [Float],
                       primId: Int32,
                       key: UInt64,
                       ptexFaces faces: UnsafeBufferPointer<UInt32> = .init(start: nil, count: 0))
    {
      let vertCount = expands ? localIndices.count : localVerts.count / 8
      if vOff + vertCount * Self.vertexFloats > maxVerts * Self.vertexFloats || iOff + localIndices.count > maxIndices
      {
        draw()
      }

      guard ensureBuffers(), let vertBuf, let idxBuf else { return }

      let baseVertex = Int32(vertexCount)
      let (m0, m1, m2, m4, m5, m6) = (m[0], m[1], m[2], m[4], m[5], m[6])
      let (m8, m9, m10, m12, m13, m14) = (m[8], m[9], m[10], m[12], m[13], m[14])
      let (n0, n1, n2, n3, n4, n5, n6, n7, n8) = (n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8])
      // materials come from the atlas, so the color slot carries the prim id.
      let id = Float(primId)

      var minX = Float.greatestFiniteMagnitude, minY = minX, minZ = minX
      var maxX = -Float.greatestFiniteMagnitude, maxY = maxX, maxZ = maxX
      do
      {
        let src = localVerts
        var d = vertBuf + vOff
        for v in 0 ..< vertCount
        {
          let s = (expands ? Int(localIndices[v]) : v) * 8
          let px = src[s + 0], py = src[s + 1], pz = src[s + 2]
          let nx = src[s + 3], ny = src[s + 4], nz = src[s + 5]

          let wx = m0 * px + m4 * py + m8 * pz + m12
          let wy = m1 * px + m5 * py + m9 * pz + m13
          let wz = m2 * px + m6 * py + m10 * pz + m14
          minX = wx < minX ? wx : minX; maxX = wx > maxX ? wx : maxX
          minY = wy < minY ? wy : minY; maxY = wy > maxY ? wy : maxY
          minZ = wz < minZ ? wz : minZ; maxZ = wz > maxZ ? wz : maxZ

          d[0] = wx
          d[1] = wy
          d[2] = wz
          d[3] = 1

          // a static vertex's previous position is where it is.
          d[4] = id
          d[5] = wx
          d[6] = wy
          d[7] = wz

          d[8] = src[s + 6]
          d[9] = src[s + 7]

          d[10] = n0 * nx + n1 * ny + n2 * nz
          d[11] = n3 * nx + n4 * ny + n5 * nz
          d[12] = n6 * nx + n7 * ny + n8 * nz
          d[13] = 0

          d += Self.vertexFloats
        }
      }

      vOff += vertCount * Self.vertexFloats

      let hasBounds = minX <= maxX
      if hasBounds
      {
        boundsMin = pointwiseMin(boundsMin, SIMD3(minX, minY, minZ))
        boundsMax = pointwiseMax(boundsMax, SIMD3(maxX, maxY, maxZ))
        casterBounds += [minX, minY, minZ, maxX, maxY, maxZ]
        casterKeys.append(key)
      }

      do
      {
        let src = localIndices
        let dst = idxBuf + iOff
        for j in 0 ..< src.count
        {
          dst[j] = (expands ? Int32(j) : src[j]) &+ baseVertex
        }
      }

      if iOff - chunkStarts[chunkStarts.count - 1] >= Self.chunkIndices
      {
        chunkStarts.append(iOff)
        chunkBounds += Self.emptyBounds
      }

      if hasBounds
      {
        let o = chunkBounds.count - 6
        chunkBounds[o + 0] = min(chunkBounds[o + 0], minX)
        chunkBounds[o + 1] = min(chunkBounds[o + 1], minY)
        chunkBounds[o + 2] = min(chunkBounds[o + 2], minZ)
        chunkBounds[o + 3] = max(chunkBounds[o + 3], maxX)
        chunkBounds[o + 4] = max(chunkBounds[o + 4], maxY)
        chunkBounds[o + 5] = max(chunkBounds[o + 5], maxZ)
      }

      appendFaces(faces, triangles: localIndices.count / 3)
      iOff += localIndices.count
    }

    /// Appends one instanced prototype's vertices, moved by its own `worldMatrix` into its instancer's space,
    /// and the instance sets it draws with. The vertices are written once, each set becomes one GPU instanced
    /// draw of the same index range.
    public func appendInstanced(localVerts: UnsafeBufferPointer<Float>, localIndices: UnsafeBufferPointer<Int32>,
                                worldMatrix m: [Float], normalMatrix n: [Float],
                                draws: [Akari.Geom.Recorder.InstanceDraw],
                                primId: Int32, key: UInt64,
                                ptexFaces faces: UnsafeBufferPointer<UInt32> = .init(start: nil, count: 0))
    {
      let draws = draws.filter { $0.count > 0 && $0.transforms.count >= $0.count * 16 }
      guard !draws.isEmpty else { return }
      let vertCount = localVerts.count / 8
      if vOff + vertCount * Self.vertexFloats > maxVerts * Self.vertexFloats || iOff + localIndices.count > maxIndices
      {
        draw()
      }

      guard ensureBuffers(), let vertBuf, let idxBuf else { return }

      let baseVertex = Int32(vertexCount)
      let (lo, hi) = writeInstancedVertices(localVerts, count: vertCount, worldMatrix: m, normalMatrix: n,
                                            primId: primId, into: vertBuf + vOff)
      let (minX, minY, minZ, maxX, maxY, maxZ) = (lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
      vOff += vertCount * Self.vertexFloats

      do
      {
        let src = localIndices
        let dst = idxBuf + iOff
        for j in 0 ..< src.count
        {
          dst[j] = src[j] &+ baseVertex
        }
      }

      // world bounds of each draw, from the prototype's bounds under each of its matrices, as casters a
      // cell of instances each, so a set keeping more or fewer of them only redraws the shadows around those.
      var protoMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var protoMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
      let cellSize = max(maxX - minX, maxY - minY, maxZ - minZ, 1e-6) * Self.instancesPerCasterCell
      var cells: [SIMD3<Int32>: (min: SIMD3<Float>, max: SIMD3<Float>, key: UInt64)] = [:]
      // a coarser level casts where its finest does.
      let casts = draws.contains { $0.lod.y == .infinity }
      for draw in draws
      {
        if minX <= maxX, casts
        {
          addCasterCells(draw, lo: lo, hi: hi, cellSize: cellSize, into: &cells, protoMin: &protoMin, protoMax: &protoMax)
        }

        addInstanceGroup(draw, indexCount: localIndices.count, lo: lo, hi: hi)
      }

      if protoMin.x <= protoMax.x
      {
        boundsMin = pointwiseMin(boundsMin, protoMin)
        boundsMax = pointwiseMax(boundsMax, protoMax)
      }

      for (cell, entry) in cells
      {
        casterBounds += [entry.min.x, entry.min.y, entry.min.z, entry.max.x, entry.max.y, entry.max.z]
        var cellKey = (key ^ entry.key) &* 1_099_511_628_211
        cellKey = (cellKey ^ UInt64(UInt32(bitPattern: cell.x))) &* 1_099_511_628_211
        cellKey = (cellKey ^ UInt64(UInt32(bitPattern: cell.y))) &* 1_099_511_628_211
        cellKey = (cellKey ^ UInt64(UInt32(bitPattern: cell.z))) &* 1_099_511_628_211
        casterKeys.append(cellKey)
      }

      appendFaces(faces, triangles: localIndices.count / 3)
      iOff += localIndices.count
    }

    /// Writes a prototype's vertices moved into its instancer's space, returning their bounds there.
    private func writeInstancedVertices(_ localVerts: UnsafeBufferPointer<Float>, count vertCount: Int,
                                        worldMatrix m: [Float], normalMatrix n: [Float], primId: Int32,
                                        into destination: UnsafeMutablePointer<Float>) -> (SIMD3<Float>, SIMD3<Float>)
    {
      let id = Float(primId)
      let (m0, m1, m2, m4, m5, m6) = (m[0], m[1], m[2], m[4], m[5], m[6])
      let (m8, m9, m10, m12, m13, m14) = (m[8], m[9], m[10], m[12], m[13], m[14])
      let (n0, n1, n2, n3, n4, n5, n6, n7, n8) = (n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8])

      var minX = Float.greatestFiniteMagnitude, minY = minX, minZ = minX
      var maxX = -Float.greatestFiniteMagnitude, maxY = maxX, maxZ = maxX
      do
      {
        let src = localVerts
        var d = destination
        for v in 0 ..< vertCount
        {
          let s = v * 8
          let px = src[s + 0], py = src[s + 1], pz = src[s + 2]
          let nx = src[s + 3], ny = src[s + 4], nz = src[s + 5]
          let wx = m0 * px + m4 * py + m8 * pz + m12
          let wy = m1 * px + m5 * py + m9 * pz + m13
          let wz = m2 * px + m6 * py + m10 * pz + m14
          minX = wx < minX ? wx : minX; maxX = wx > maxX ? wx : maxX
          minY = wy < minY ? wy : minY; maxY = wy > maxY ? wy : maxY
          minZ = wz < minZ ? wz : minZ; maxZ = wz > maxZ ? wz : maxZ

          d[0] = wx
          d[1] = wy
          d[2] = wz
          d[3] = 1

          // previous position stays in the instancer's space too, the shader applies the instance.
          d[4] = id
          d[5] = wx
          d[6] = wy
          d[7] = wz

          d[8] = src[s + 6]
          d[9] = src[s + 7]

          d[10] = n0 * nx + n1 * ny + n2 * nz
          d[11] = n3 * nx + n4 * ny + n5 * nz
          d[12] = n6 * nx + n7 * ny + n8 * nz
          d[13] = 0

          d += Self.vertexFloats
        }
      }

      return (SIMD3(minX, minY, minZ), SIMD3(maxX, maxY, maxZ))
    }

    /// Bins each instance's bounds into caster cells, keyed by the sum of the instances' matrix hashes.
    private func addCasterCells(_ draw: Akari.Geom.Recorder.InstanceDraw, lo: SIMD3<Float>, hi: SIMD3<Float>, cellSize: Float,
                                into cells: inout [SIMD3<Int32>: (min: SIMD3<Float>, max: SIMD3<Float>, key: UInt64)],
                                protoMin: inout SIMD3<Float>, protoMax: inout SIMD3<Float>)
    {
      let (minX, minY, minZ, maxX, maxY, maxZ) = (lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
      draw.transforms.withUnsafeBufferPointer
      { m in
        for i in 0 ..< draw.count
        {
          let o = i * 16
          let m0 = m[o], m1 = m[o + 1], m2 = m[o + 2], m4 = m[o + 4]
          let m5 = m[o + 5], m6 = m[o + 6], m8 = m[o + 8], m9 = m[o + 9]
          let m10 = m[o + 10], m12 = m[o + 12], m13 = m[o + 13], m14 = m[o + 14]
          var instanceMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
          var instanceMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
          for corner in 0 ..< 8
          {
            let px = corner & 1 == 0 ? minX : maxX
            let py = corner & 2 == 0 ? minY : maxY
            let pz = corner & 4 == 0 ? minZ : maxZ
            let wx = m0 * px + m4 * py + m8 * pz + m12
            let wy = m1 * px + m5 * py + m9 * pz + m13
            let wz = m2 * px + m6 * py + m10 * pz + m14
            instanceMin = pointwiseMin(instanceMin, SIMD3(wx, wy, wz))
            instanceMax = pointwiseMax(instanceMax, SIMD3(wx, wy, wz))
          }

          var instanceKey: UInt64 = 14_695_981_039_346_656_037
          for k in 0 ..< 16
          {
            instanceKey = (instanceKey ^ UInt64(m[o + k].bitPattern)) &* 1_099_511_628_211
          }

          let center = ((instanceMin + instanceMax) * 0.5 / cellSize).rounded(.down)
          let cell = center.x.isFinite && center.y.isFinite && center.z.isFinite
            ? SIMD3<Int32>(pointwiseMax(pointwiseMin(center, SIMD3(repeating: 1e9)), SIMD3(repeating: -1e9)))
            : .zero
          let entry = cells[cell] ?? (instanceMin, instanceMax, 0)
          // summed, the order a set keeps its instances in doesn't change the key.
          cells[cell] = (pointwiseMin(entry.min, instanceMin), pointwiseMax(entry.max, instanceMax), entry.key &+ instanceKey)
          protoMin = pointwiseMin(protoMin, instanceMin)
          protoMax = pointwiseMax(protoMax, instanceMax)
        }
      }
    }

    /// Records the draw's instance set, extending the open run it continues or starting a new one.
    private func addInstanceGroup(_ draw: Akari.Geom.Recorder.InstanceDraw, indexCount: Int, lo: SIMD3<Float>, hi: SIMD3<Float>)
    {
      let (minX, minY, minZ, maxX, maxY, maxZ) = (lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
      if instanceSets[draw.key] == nil { instanceSets[draw.key] = draw.transforms }
      if let live = draw.livePrototype { liveSets[draw.key] = live }
      drawnInstances[draw.key] = max(drawnInstances[draw.key] ?? 0, draw.count)
      // a run of prototypes drawing the same instances at the same level is one draw.
      let run = SIMD4(draw.key, UInt64(draw.lod.x.bitPattern), UInt64(draw.lod.y.bitPattern),
                      draw.bounds.map { $0.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1.bitPattern)) &* 1_099_511_628_211 } } ?? 0)
      if let open = openRuns[run], instanceGroups[open].count == draw.count,
         instanceGroups[open].indexStart + instanceGroups[open].indexCount == iOff
      {
        let last = instanceGroups[open]
        instanceGroups[open].indexCount += indexCount
        if draw.bounds != nil { return }
        instanceGroups[open].bounds = [min(last.bounds[0], minX), min(last.bounds[1], minY),
                                       min(last.bounds[2], minZ), max(last.bounds[3], maxX),
                                       max(last.bounds[4], maxY), max(last.bounds[5], maxZ)]
        return
      }

      openRuns[run] = instanceGroups.count
      instanceGroups.append(InstanceGroup(indexStart: iOff,
                                          indexCount: indexCount,
                                          set: draw.key,
                                          count: draw.count,
                                          bounds: draw.bounds ?? [minX, minY, minZ, maxX, maxY, maxZ],
                                          lod: draw.lod))
    }

    private func appendFaces(_ faces: UnsafeBufferPointer<UInt32>, triangles: Int)
    {
      guard ptexFaces != nil else { return }
      if faces.count == triangles { triangleFaces += faces } else { triangleFaces += repeatElement(.max, count: triangles) }
    }

    /// A flush's bytes, written to the geometry cache where it has room, else kept in memory.
    fileprivate enum Bytes
    {
      case packed(Akari.Geom.GeometryCache.Slice)
      case memory([UInt8])

      init(_ bytes: UnsafeRawBufferPointer)
      {
        if let slice = Akari.Geom.GeometryCache.shared.pack([bytes]) { self = .packed(slice) } else { self = .memory(Array(bytes)) }
      }

      func buffer(_ usage: GLuint) -> GLuint
      {
        switch self
        {
          case let .packed(slice):
            return Akari.Geom.GeometryCache.shared.buffer(usage: usage | LGL_BUFFER_CAPTURE_ADOPT, slice)
          case let .memory(bytes):
            let buffer = gl.createBuffer(usage: usage | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT, sizeBytes: GLsizei(bytes.count))
            bytes.withUnsafeBytes { gl.mapBuffer(buffer)?.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return buffer
        }
      }
    }

    /// One filled buffer pair and its draws, sealed on any thread and recorded on the render thread.
    public struct Flush: @unchecked Sendable
    {
      fileprivate var vertices: Bytes
      fileprivate var indices: Bytes
      fileprivate var chunks: [(range: Range<Int>, bounds: ArraySlice<Float>)]
      fileprivate var groups: [InstanceGroup]
      fileprivate var sets: [(key: UInt64, transforms: Bytes?, live: (path: String, transforms: Akari.Geom.Matrices)?)]
      fileprivate var triangleFaces: [UInt32]
    }

    /// What a batch made with `defers` set leaves for `record`, rather than drawing as it fills.
    public private(set) var flushes: [Flush] = []
    private var defers = false

    /// Keeps each flush in `flushes` for a later `record`, so filling the batch makes no GL calls.
    public func deferDraws()
    {
      defers = true
    }

    /// Hands the filled buffer pair to the recording capture and issues
    /// one draw per chunk, then resets for the next batch.
    public func draw()
    {
      guard let flush = seal() else { return }
      if defers { flushes.append(flush) } else { Self.record(flush, instanced: instanced, ptexFaces: ptexFaces) }
    }

    /// Takes the filled buffers and their draws, writing the bytes out, and resets for the next batch.
    private func seal() -> Flush?
    {
      guard vOff > 0, let vertBuf, let idxBuf else { return nil }

      var chunks: [(range: Range<Int>, bounds: ArraySlice<Float>)] = []
      if !instanced
      {
        for (c, start) in chunkStarts.enumerated()
        {
          let end = c + 1 < chunkStarts.count ? chunkStarts[c + 1] : iOff
          if end > start { chunks.append((start ..< end, chunkBounds[c * 6 ..< c * 6 + 6])) }
        }
      }

      let sets = instanceSets.map
      { key, transforms -> (key: UInt64, transforms: Bytes?, live: (path: String, transforms: Akari.Geom.Matrices)?) in
        if let live = liveSets[key] { return (key, nil, (live, transforms)) }
        let floats = min(transforms.count, (drawnInstances[key] ?? 0) * 16)
        return (key, transforms.withUnsafeBytes { Bytes(UnsafeRawBufferPointer(rebasing: $0[0 ..< floats * MemoryLayout<Float>.stride])) }, nil)
      }

      let flush = Flush(vertices: Bytes(UnsafeRawBufferPointer(start: vertBuf, count: vOff * MemoryLayout<Float>.stride)),
                        indices: Bytes(UnsafeRawBufferPointer(start: idxBuf, count: iOff * MemoryLayout<Int32>.stride)),
                        chunks: chunks, groups: instanceGroups, sets: sets, triangleFaces: triangleFaces)

      vOff = 0
      iOff = 0
      chunkStarts = [0]
      chunkBounds = Self.emptyBounds
      triangleFaces.removeAll(keepingCapacity: true)
      instanceGroups.removeAll(keepingCapacity: true)
      instanceSets.removeAll(keepingCapacity: true)
      liveSets.removeAll(keepingCapacity: true)
      drawnInstances.removeAll(keepingCapacity: true)
      openRuns.removeAll(keepingCapacity: true)
      return flush
    }

    /// Points the next draw at its triangles faces, when any of them stream.
    private static func drawFaces(_ indices: Range<Int>, _ flush: Flush, _ ptexFaces: PtexFaces?)
    {
      guard let ptexFaces, indices.upperBound / 3 <= flush.triangleFaces.count else { return }
      let faces = flush.triangleFaces[indices.lowerBound / 3 ..< indices.upperBound / 3]
      guard faces.contains(where: { $0 != .max }) else { return }
      labgl.captureNextDrawBase(ptexFaces.add(faces))
    }

    /// Records a sealed flush's buffers and draws into the recording capture.
    public static func record(_ flush: Flush, instanced: Bool, ptexFaces: PtexFaces?)
    {
      let vb = flush.vertices.buffer(LGL_BUFFER_VERTEX)
      let ib = flush.indices.buffer(LGL_BUFFER_INDEX)
      // unmapping is where the recording capture takes the buffers over.
      gl.unmapBuffer(vb)
      gl.unmapBuffer(ib)

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: vb)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: ib)

      gl.enableClientState(GL_VERTEX_ARRAY)
      gl.enableClientState(GL_COLOR_ARRAY)
      gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.enableClientState(GL_NORMAL_ARRAY)

      // float offsets into the interleaved vertex `append` writes.
      let stride = GLsizei(Self.vertexStride)
      let floatBytes = MemoryLayout<Float>.stride
      gl.vertexPointer(size: 4, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 0 * floatBytes))
      gl.colorPointer(size: 4, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 4 * floatBytes))
      gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 8 * floatBytes))
      gl.normalPointer(type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 10 * floatBytes))

      if instanced
      {
        var handles: [UInt64: GLuint] = [:]
        for set in flush.sets
        {
          let handle = gl.genInstanceTransforms(count: 1)
          guard handle != 0 else { continue }
          if let live = set.live
          {
            // shared and mapped, the capture adopts it and its writer moves the instances in place.
            let bytes = live.transforms.count * MemoryLayout<Float>.stride
            let buffer = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT,
                                         sizeBytes: GLsizei(bytes))
            if buffer != 0, let base = gl.mapBuffer(buffer)
            {
              live.transforms.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
              gl.unmapBuffer(buffer)
              Akari.LiveInstances.publish(live.path, base: base)
              gl.instanceTransformsBuffer(handle, buffer: buffer)
            }
            else
            {
              live.transforms.withUnsafeBufferPointer
              {
                gl.instanceTransformsData(handle: handle, size: GLsizei(bytes), transforms: $0.baseAddress,
                                          cullRadius: 0, usage: GL_STATIC_DRAW)
              }
            }

            handles[set.key] = handle
            continue
          }

          switch set.transforms
          {
            case let .packed(slice):
              // read in place from a file, the capture keeps the buffer instead of a copy.
              let file = Akari.Geom.GeometryCache.shared.buffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_CAPTURE_ADOPT, slice)
              gl.unmapBuffer(file)
              gl.instanceTransformsBuffer(handle, buffer: file)
            case let .memory(bytes):
              bytes.withUnsafeBytes
              {
                gl.instanceTransformsData(handle: handle, size: GLsizei($0.count),
                                          transforms: $0.baseAddress?.assumingMemoryBound(to: Float.self),
                                          cullRadius: 0, usage: GL_STATIC_DRAW)
              }
            case nil:
              continue
          }

          handles[set.key] = handle
        }

        for group in flush.groups
        {
          guard let handle = handles[group.set] else { continue }
          group.bounds.withUnsafeBufferPointer { labgl.captureNextDrawBounds($0.baseAddress!) }
          if group.lod != SIMD2(0, .infinity) { labgl.captureNextDrawLod(group.lod.x, group.lod.y) }
          drawFaces(group.indexStart ..< group.indexStart + group.indexCount, flush, ptexFaces)
          gl.instancedDrawElements(handle: handle,
                                   mode: GL_TRIANGLES,
                                   count: Int32(group.indexCount),
                                   type: GL_UNSIGNED_INT,
                                   indices: .init(bitPattern: group.indexStart * MemoryLayout<Int32>.stride),
                                   drawCount: Int32(group.count))
        }

        for var handle in handles.values
        {
          gl.deleteInstanceTransforms(count: 1, handles: &handle)
        }
      }
      else
      {
        for chunk in flush.chunks
        {
          Array(chunk.bounds).withUnsafeBufferPointer { labgl.captureNextDrawBounds($0.baseAddress!) }
          drawFaces(chunk.range, flush, ptexFaces)
          gl.drawElements(mode: GL_TRIANGLES,
                          count: Int32(chunk.range.count),
                          type: GL_UNSIGNED_INT,
                          indices: .init(bitPattern: chunk.range.lowerBound * MemoryLayout<Int32>.stride))
        }
      }

      gl.disableClientState(GL_NORMAL_ARRAY)
      gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.disableClientState(GL_COLOR_ARRAY)
      gl.disableClientState(GL_VERTEX_ARRAY)

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: 0)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: 0)
    }
  }
}
