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
  /// A built mesh's vertices, eight floats each, indices, and each
  /// triangle's streamed Ptex face when it has them, read straight
  /// from the cache's mapped pack if it exists.
  final class Built: @unchecked Sendable
  {
    public let verts: UnsafeBufferPointer<Float>
    public let indices: UnsafeBufferPointer<Int32>
    public let ptexFaces: UnsafeBufferPointer<UInt32>
    private let base: UnsafeMutableRawPointer?
    private let pack: Pack?

    init(copying verts: [Float], _ indices: [Int32], _ ptexFaces: [UInt32])
    {
      let vertBytes = verts.count * MemoryLayout<Float>.stride
      let indexBytes = indices.count * MemoryLayout<Int32>.stride
      let bytes = vertBytes + indexBytes + ptexFaces.count * MemoryLayout<UInt32>.stride
      let base = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 16), alignment: 16)
      let vertStart = base.bindMemory(to: Float.self, capacity: verts.count)
      let indexStart = (base + vertBytes).bindMemory(to: Int32.self, capacity: indices.count)
      let faceStart = (base + vertBytes + indexBytes).bindMemory(to: UInt32.self, capacity: ptexFaces.count)
      vertStart.update(from: verts, count: verts.count)
      indexStart.update(from: indices, count: indices.count)
      faceStart.update(from: ptexFaces, count: ptexFaces.count)
      self.base = base
      pack = nil
      self.verts = UnsafeBufferPointer(start: vertStart, count: verts.count)
      self.indices = UnsafeBufferPointer(start: indexStart, count: indices.count)
      self.ptexFaces = UnsafeBufferPointer(start: faceStart, count: ptexFaces.count)
    }

    init(_ pack: Pack, at offset: Int, vertCount: Int, indexCount: Int, faceCount: Int)
    {
      let start = pack.base + offset
      let indicesAt = vertCount * MemoryLayout<Float>.stride
      let facesAt = indicesAt + indexCount * MemoryLayout<Int32>.stride
      base = nil
      self.pack = pack
      verts = UnsafeBufferPointer(start: start.assumingMemoryBound(to: Float.self), count: vertCount)
      indices = UnsafeBufferPointer(start: (start + indicesAt).assumingMemoryBound(to: Int32.self), count: indexCount)
      ptexFaces = UnsafeBufferPointer(start: (start + facesAt).assumingMemoryBound(to: UInt32.self), count: faceCount)
    }

    deinit
    {
      base?.deallocate()
    }

    public var isEmpty: Bool
    {
      verts.isEmpty || indices.isEmpty
    }

    /// Read from the cache's file, so the system can drop its pages, not held in memory.
    public var isMapped: Bool
    {
      pack != nil
    }
  }

  /// An append only file, unlinked as soon as it's open and
  /// mapped read only once over a reservation far past what
  /// it grows to.
  final class Pack: @unchecked Sendable
  {
    public let base: UnsafeMutableRawPointer
    private let fd: Int32
    private let capacity: Int
    private let lock = NSLock()
    private var end = 0

    init?(in directory: String, capacity: Int = 1 << 38)
    {
      let path = "\(directory)/pack-\(UInt64.random(in: 1 ... .max))"
      let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
      guard fd >= 0 else { return nil }
      unlink(path)
      guard let base = mmap(nil, capacity, PROT_READ, MAP_SHARED, fd, 0), base != MAP_FAILED
      else
      {
        close(fd)
        return nil
      }

      self.fd = fd
      self.base = base
      self.capacity = capacity
    }

    deinit
    {
      munmap(base, capacity)
      close(fd)
    }

    /// Appends `parts` one after another at a page aligned offset, nil when it can't.
    func append(_ parts: [UnsafeRawBufferPointer]) -> (offset: Int, length: Int)?
    {
      let page = Int(getpagesize())
      let length = (parts.reduce(0) { $0 + $1.count } + page - 1) / page * page
      // writing past the end grows the file, the lock only hands out the room.
      lock.lock()
      let offset = end
      guard length > 0, offset + length <= capacity
      else
      {
        lock.unlock()
        return nil
      }

      end += length
      lock.unlock()
      var at = offset
      for part in parts where part.count > 0
      {
        var written = 0
        while written < part.count
        {
          let count = pwrite(fd, part.baseAddress! + written, part.count - written, off_t(at + written))
          guard count > 0 else { return nil }
          written += count
        }

        at += part.count
      }

      return (offset, length)
    }
  }

  /// Built meshes kept on disk by content and mapped back read only, so
  /// what's built never has to fit in memory twice and a rerecord maps it
  /// back instead of rebuilding. Builds append to the session's packs, each
  /// record's GPU buffers to packs of their own that go with the last of
  /// them. It stops storing builds once they hold a quarter of the free disk
  /// or `AKARI_GEOMETRY_CACHE_GB`, `AKARI_GEOMETRY_CACHE=0` disables the cache.
  final class GeometryCache: @unchecked Sendable
  {
    public static let shared = GeometryCache()

    private static let version: UInt32 = 3
    private let root: String?
    private let limit: Int64
    private let lock = NSLock()
    private var stored: Int64 = 0
    private var builds: [Pack] = []
    private var index: [UInt64: (pack: Int, offset: Int, verts: Int, indices: Int, faces: Int)] = [:]
    private var buffers: [Pack] = []
    private var next = 0

    /// Appends to one file serialize on it, so they spread over several.
    private static let shards = 8

    private init()
    {
      let environment = ProcessInfo.processInfo.environment
      guard
        environment["AKARI_GEOMETRY_CACHE"] != "0",
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      else
      {
        root = nil
        limit = 0
        return
      }

      let parent = caches.appendingPathComponent("Akari/geometry-v\(Self.version)").path
      Self.sweep(parent)
      let root = "\(parent)/\(getpid())"
      guard (try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)) != nil
      else
      {
        self.root = nil
        limit = 0
        return
      }

      self.root = root
      let free = (try? FileManager.default.attributesOfFileSystem(forPath: root)[.systemFreeSize] as? Int64) ?? 0
      let configured = Double(environment["AKARI_GEOMETRY_CACHE_GB"] ?? "").map { Int64($0 * 1_073_741_824) }
      limit = configured ?? free / 4
      builds = Self.packs(in: root)
      atexit { GeometryCache.shared.removeAll() }
    }

    private static func packs(in root: String) -> [Pack]
    {
      (0 ..< shards).compactMap { _ in Pack(in: root, capacity: 1 << 36) }
    }

    /// Removes this session's folder, its packs are already unlinked.
    public func removeAll()
    {
      guard let root else { return }
      try? FileManager.default.removeItem(atPath: root)
    }

    /// Removes the caches of sessions that are no longer running.
    private static func sweep(_ parent: String)
    {
      for name in (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
      {
        guard let pid = pid_t(name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
        try? FileManager.default.removeItem(atPath: "\(parent)/\(name)")
      }
    }

    public var isEnabled: Bool
    {
      root != nil
    }

    /// The cache key of a mesh's build, zero when it has no content key.
    public static func key(contentKey: UInt64, flipWinding: Bool, points: Int, triangles: Int, uvs: Int) -> UInt64
    {
      guard contentKey != 0 else { return 0 }
      var key: UInt64 = 14_695_981_039_346_656_037
      for value in [contentKey, flipWinding ? 1 : 0, UInt64(points), UInt64(triangles), UInt64(uvs), UInt64(version)]
      {
        key = (key ^ value) &* 1_099_511_628_211
      }

      return key == 0 ? 1 : key
    }

    public func load(_ key: UInt64) -> Built?
    {
      lock.lock()
      defer { lock.unlock() }
      guard key != 0, let found = index[key] else { return nil }
      return Built(builds[found.pack], at: found.offset, vertCount: found.verts, indexCount: found.indices, faceCount: found.faces)
    }

    /// Appends a build under `key` and maps it back, or keeps a copy in memory when it can't be stored.
    public func store(_ key: UInt64, verts: [Float], indices: [Int32], ptexFaces: [UInt32]) -> Built
    {
      let bytes = Int64(verts.count * 4 + indices.count * 4 + ptexFaces.count * 4)
      lock.lock()
      let fits = stored + bytes <= limit
      if fits { stored += bytes }
      let shard = builds.isEmpty ? 0 : next % builds.count
      next &+= 1
      lock.unlock()
      guard
        key != 0, fits, !builds.isEmpty,
        let stored = verts.withUnsafeBytes({ v in
          indices.withUnsafeBytes { i in ptexFaces.withUnsafeBytes { f in builds[shard].append([v, i, f]) } }
        })
      else { return Built(copying: verts, indices, ptexFaces) }
      lock.lock()
      index[key] = (shard, stored.offset, verts.count, indices.count, ptexFaces.count)
      lock.unlock()
      return Built(builds[shard], at: stored.offset, vertCount: verts.count, indexCount: indices.count, faceCount: ptexFaces.count)
    }

    /// Starts a record's GPU buffers in a pack of
    /// their own, the last ones go once the buffers
    /// made from it do.
    public func beginRecord()
    {
      lock.lock()
      buffers = []
      lock.unlock()
    }

    /// Leaves this much of the disk free.
    private static let diskReserve: Int64 = 2 << 30

    /// The disk's room past the reserve, nil when there's none or no cache.
    public var freeDisk: Int64?
    {
      var disk = statfs()
      guard let root, statfs(root, &disk) == 0 else { return nil }
      let free = Int64(disk.f_bavail) * Int64(disk.f_bsize) - Self.diskReserve
      return free > 0 ? free : nil
    }

    /// A readonly GPU buffer of `parts` one after another, appended to the
    /// record's pack and mapped, so its pages are the file's for the system
    /// to drop and read back rather than the process's to swap. 0 when the
    /// disk is short of room, the caller keeps them in memory instead.
    public func mappedBuffer(usage: GLuint, _ parts: [UnsafeRawBufferPointer]) -> GLuint
    {
      pack(parts).map { buffer(usage: usage, $0) } ?? 0
    }

    /// Where `pack` wrote, which holds its file open.
    public struct Slice: @unchecked Sendable
    {
      let pack: Pack
      let offset: Int
      let length: Int
    }

    /// `mappedBuffer`'s write, from any thread, nil when the disk is short of room.
    public func pack(_ parts: [UnsafeRawBufferPointer]) -> Slice?
    {
      let bytes = parts.reduce(0) { $0 + $1.count }
      guard bytes > 0, let root, let free = freeDisk, free > Int64(bytes) else { return nil }
      lock.lock()
      if buffers.isEmpty { buffers = Self.packs(in: root) }
      let pack = buffers.isEmpty ? nil : buffers[next % buffers.count]
      next &+= 1
      lock.unlock()
      guard let pack, let slice = pack.append(parts) else { return nil }
      return Slice(pack: pack, offset: slice.offset, length: slice.length)
    }

    /// `mappedBuffer`'s GPU buffer, from the render thread.
    public func buffer(usage: GLuint, _ slice: Slice) -> GLuint
    {
      // each buffer holds the pack, which unmaps after the last of them.
      gl.createBuffer(usage: usage, noCopy: slice.pack.base + slice.offset, length: GLsizei(slice.length),
                      release: { Unmanaged<Pack>.fromOpaque($0!).release() },
                      context: Unmanaged.passRetained(slice.pack).toOpaque())
    }
  }
}
