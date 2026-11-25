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


import Foundation
import simd

extension Kraken
{
  /// the brush settings a stroke keeps from the moment it begins
  struct SculptStrokeSettings: Sendable
  {
    var brush: SculptBrush
    var invert: Bool
    /// the brush size in viewport points
    var radius: Float
    var strength: Float
    var falloff: SculptFalloff
    var mirror: [Bool]
    var lazy: Float
    var pressureSize: Bool
    var pressureStrength: Bool
    var paint: SIMD4<UInt8>
    var paintsWhileSculpting: Bool
  }

  /// what the stroke worker hands back, new brick meshes, the brush position and the undo step when a stroke ends
  struct SculptStrokeNews: @unchecked Sendable
  {
    var meshes: [SIMD3<Int32>: SculptChunk?] = [:]
    var cursor: (center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float)?
    var record: [SIMD3<Int32>: SculptBrickState]?
    var done = false
  }

  /// lays a stroke's dabs and meshes on a queue of its own so the viewport keeps drawing, it alone touches the volume meanwhile
  final class SculptStroker: @unchecked Sendable
  {
    private enum Command
    {
      case start(SculptVolume, SculptStrokeSettings, SculptPointer, SIMD3<Float>)
      case move(SculptPointer)
      case finish
      case cancel
    }

    /// a stroke in progress
    private struct Stroke
    {
      var settings: SculptStrokeSettings
      var record: [SIMD3<Int32>: SculptBrickState] = [:]
      var touched: Set<SIMD3<Int32>> = []
      var anchor: SIMD3<Float>
      var last: SIMD3<Float>
      var steady: SIMD3<Float>
      var radius: Float
      var travelled: Float = 0
      /// where the last dab went, so tube segments join end to end
      var dabbed: SIMD3<Float>?
    }

    private let queue = DispatchQueue(label: "kraken.sculpt.stroke", qos: .userInteractive)
    private let lock = NSLock()

    // shared with the main thread, under the lock
    private var inbox: [Command] = []
    private var draining = false
    private var outbox: [SculptStrokeNews] = []

    // the queue's own
    private var volume: SculptVolume?
    private var stroke: Stroke?
    private var dirty = Set<SIMD3<Int32>>()
    private var news = SculptStrokeNews()
    private var posted = 0.0

    /// called on the queue whenever news is waiting
    var deliver: (@Sendable () -> Void)?

    // MARK: main thread

    /// true when nothing is queued or running, so the volume is the main thread's to touch
    var isIdle: Bool
    {
      lock.withLock { !draining && inbox.isEmpty }
    }

    func start(_ volume: SculptVolume, _ settings: SculptStrokeSettings, _ pointer: SculptPointer, at start: SIMD3<Float>)
    {
      send(.start(volume, settings, pointer, start))
    }

    /// queues a pointer move. grab only follows the newest, it reads the volume as the stroke found it
    func move(_ pointer: SculptPointer)
    {
      lock.lock()
      if case .move = inbox.last, grabbing { inbox.removeLast() }
      inbox.append(.move(pointer))
      let wake = !draining
      draining = true
      lock.unlock()
      if wake { queue.async { self.drain() } }
    }

    func finish()
    {
      send(.finish)
    }

    func cancel()
    {
      send(.cancel)
    }

    /// waits for every queued command to run, for anything on the main thread about to touch the volume
    func wait()
    {
      queue.sync {}
    }

    /// the news gathered since the last call
    func collect() -> [SculptStrokeNews]
    {
      lock.withLock
      {
        let taken = outbox
        outbox.removeAll()
        return taken
      }
    }

    private var grabbing = false

    private func send(_ command: Command)
    {
      lock.lock()
      if case let .start(_, settings, _, _) = command { grabbing = settings.brush == .grab }
      inbox.append(command)
      let wake = !draining
      draining = true
      lock.unlock()
      if wake { queue.async { self.drain() } }
    }

    // MARK: queue

    private func drain()
    {
      while true
      {
        lock.lock()
        guard !inbox.isEmpty else
        {
          lock.unlock()
          post(force: true)
          lock.lock()

          // a command may have arrived while the last news went out
          if inbox.isEmpty
          {
            draining = false
            lock.unlock()
            return
          }
          lock.unlock()
          continue
        }

        let command = inbox.removeFirst()
        lock.unlock()

        run(command)
        post(force: false)
      }
    }

    private func run(_ command: Command)
    {
      switch command
      {
        case let .start(volume, settings, pointer, start):
          self.volume = volume
          let r = worldRadius(settings, pointer, at: start, volume)
          stroke = Stroke(settings: settings, anchor: start, last: start, steady: start, radius: r)
          if !settings.brush.drags
          {
            dab(at: start, previous: start, pointer: pointer)
            stroke?.dabbed = start
          }

        case let .move(pointer):
          follow(pointer)

        case .finish:
          guard let finished = stroke, let volume else { break }
          stroke = nil
          news.done = true
          guard !finished.record.isEmpty else { break }

          let touched = Array(finished.touched)
          switch finished.settings.brush
          {
            case .grab, .snake, .draw, .pinch, .crease:
              volume.renormalize(touched.filter { volume.bricks[$0] != nil })
            default:
              break
          }

          volume.compact(touched)

          // bricks the tidy dropped still have meshes to clear
          for k in touched { dirty.insert(k) }
          markDirty(touched)
          news.record = finished.record

        case .cancel:
          guard let dropped = stroke, let volume else { break }
          stroke = nil
          news.done = true
          for (k, state) in dropped.record { volume.restore(k, state) }
          for k in dropped.record.keys { dirty.insert(k) }
          markDirty(Array(dropped.record.keys))
      }
    }

    /// meshes what changed and hands it over, at most once a frame unless the queue ran dry
    private func post(force: Bool)
    {
      let now = ProcessInfo.processInfo.systemUptime
      guard force || now - posted > 1.0 / 60 else { return }
      remesh()
      guard !news.meshes.isEmpty || news.cursor != nil || news.done else { return }

      posted = now
      let ready = news
      news = SculptStrokeNews()
      lock.withLock { outbox.append(ready) }
      deliver?()
    }

    private func markDirty(_ keys: some Sequence<SIMD3<Int32>>)
    {
      guard let volume else { return }
      for k in keys
      {
        for z: Int32 in -1 ... 1
        {
          for y: Int32 in -1 ... 1
          {
            for x: Int32 in -1 ... 1
            {
              let n = k &+ SIMD3(x, y, z)
              if volume.bricks[n] != nil { dirty.insert(n) }
            }
          }
        }
      }
    }

    /// marks changed bricks and only the neighbors whose meshes read the changed grid points
    private func markNear(_ changes: [SIMD3<Int32>: UInt8])
    {
      guard let volume else { return }
      for (k, faces) in changes
      {
        dirty.insert(k)
        let xs: ClosedRange<Int32> = (faces & 1 != 0 ? -1 : 0) ... (faces & 2 != 0 ? 1 : 0)
        let ys: ClosedRange<Int32> = (faces & 4 != 0 ? -1 : 0) ... (faces & 8 != 0 ? 1 : 0)
        let zs: ClosedRange<Int32> = (faces & 16 != 0 ? -1 : 0) ... (faces & 32 != 0 ? 1 : 0)
        for z in zs
        {
          for y in ys
          {
            for x in xs where x != 0 || y != 0 || z != 0
            {
              let n = k &+ SIMD3(x, y, z)
              if volume.bricks[n] != nil { dirty.insert(n) }
            }
          }
        }
      }
    }

    private func remesh()
    {
      guard let volume, !dirty.isEmpty else { return }
      let keys = Array(dirty)
      dirty.removeAll()
      let meshes = SculptMesher.mesh(volume, keys)
      for (k, mesh) in zip(keys, meshes) { news.meshes.updateValue(mesh, forKey: k) }
    }

    // MARK: dabs

    private func worldRadius(_ settings: SculptStrokeSettings, _ pointer: SculptPointer, at p: SIMD3<Float>, _ volume: SculptVolume) -> Float
    {
      let scale = settings.pressureSize ? 0.35 + 0.65 * pointer.pressure : 1
      return min(max(settings.radius * scale * pointer.pixelSize(at: p), volume.voxel * 1.5), volume.widestBrush)
    }

    private func dabStrength(_ settings: SculptStrokeSettings, _ pointer: SculptPointer, invert: Bool) -> Float
    {
      let scale = settings.pressureStrength ? pointer.pressure : 1
      return settings.strength * scale * (invert ? -1 : 1)
    }

    /// lays the dabs a move asks for
    private func follow(_ pointer: SculptPointer)
    {
      guard var current = stroke, let volume else { return }
      let settings = current.settings

      switch settings.brush
      {
        case .grab:
          let target = pointer.onPlane(through: current.anchor)
          var dab = SculptDab(brush: .grab, center: target, normal: -pointer.forward, radius: current.radius,
                              strength: 1, falloff: settings.falloff)
          dab.delta = target - current.anchor
          dab.anchor = current.anchor
          applySymmetric(dab)
          news.cursor = (target, -pointer.forward, current.radius)

        case .snake:
          let target = pointer.onPlane(through: current.last)
          let delta = target - current.last
          guard simd_length(delta) > volume.voxel * 0.3 else { return }
          var dab = SculptDab(brush: .snake, center: current.last, normal: volume.normal(current.last), radius: current.radius,
                              strength: dabStrength(settings, pointer, invert: false), falloff: settings.falloff)
          dab.delta = delta
          applySymmetric(dab)
          current.last = target
          stroke = current
          news.cursor = (target, dab.normal, current.radius)

        default:
          let hit = settings.brush == .tube ? wireHit(pointer, current) : volume.raycast(origin: pointer.origin, direction: pointer.direction)
          let target: SIMD3<Float>
          if let hit { target = hit }
          else if settings.brush == .tube { target = pointer.onPlane(through: current.last) }
          else { return }

          // the stabilizer trails the pointer on a rope so wobbly hands draw clean lines
          var steady = target
          if settings.lazy > 0
          {
            let rope = settings.lazy * current.radius * 3
            let offset = target - current.steady
            let distance = simd_length(offset)
            steady = distance > rope ? current.steady + offset * ((distance - rope) / distance) : current.steady
          }

          current.steady = steady
          let segment = steady - current.last
          let length = simd_length(segment)
          guard length > 1e-7 else
          {
            stroke = current
            return
          }

          let r = worldRadius(settings, pointer, at: steady, volume)
          let spacing = max(settings.brush.spacing * r, volume.voxel * 0.5)
          let direction = segment / length

          // walk the segment by arc length so every dab lands one spacing after the last, however the moves arrive
          var need = spacing - current.travelled
          var along: Float = 0
          var from = current.dabbed ?? current.last
          var laid = 0
          stroke = current
          while need <= length - along, laid < 64
          {
            along += need
            let next = current.last + direction * along
            dab(at: next, previous: from, pointer: pointer, radius: r)
            from = next
            need = spacing
            laid += 1

            // news goes out between dabs, so a long move shows as it lands
            post(force: false)
          }

          stroke!.travelled = laid > 0 ? length - along : current.travelled + length
          stroke!.last = steady
          if laid > 0 { stroke!.dabbed = from }
      }
    }

    /// where a wire lands under the pointer, on the surface as the stroke found it, lifted half above it
    private func wireHit(_ pointer: SculptPointer, _ current: Stroke) -> SIMD3<Float>?
    {
      guard let volume, let box = volume.bounds else { return nil }
      let before = SculptSnapshot(copies: [:], states: current.record, volume: volume)
      let pad = SIMD3<Float>(repeating: volume.band * 2)
      guard let found = before.raycast(origin: pointer.origin, direction: pointer.direction, within: (box.lo - pad, box.hi + pad))
      else { return nil }

      let e = volume.voxel
      let gradient = SIMD3(before.blended(found + SIMD3(e, 0, 0)) - before.blended(found - SIMD3(e, 0, 0)),
                           before.blended(found + SIMD3(0, e, 0)) - before.blended(found - SIMD3(0, e, 0)),
                           before.blended(found + SIMD3(0, 0, e)) - before.blended(found - SIMD3(0, 0, e)))
      let length = simd_length(gradient)
      let r = worldRadius(current.settings, pointer, at: found, volume) * 0.35
      return length > 1e-9 ? found + gradient / length * r * 0.5 : found
    }

    private func dab(at center: SIMD3<Float>, previous: SIMD3<Float>, pointer: SculptPointer, radius r: Float? = nil)
    {
      guard let current = stroke, let volume else { return }
      let settings = current.settings

      let r = r ?? current.radius
      let normal = volume.normal(center, scale: r * 0.4)
      var dab = SculptDab(brush: settings.brush, center: center, normal: normal, radius: r,
                          strength: dabStrength(settings, pointer, invert: settings.invert), falloff: settings.falloff)
      dab.previous = previous
      dab.color = settings.paint
      dab.paints = settings.brush == .tube ? 1 : (settings.paintsWhileSculpting ? 1 : 0)
      dab.ignoresMask = settings.brush == .mask

      if settings.brush == .tube
      {
        dab.radius = r * 0.35
        dab.strength = settings.invert ? -1 : 1
      }

      applySymmetric(dab)
      news.cursor = (center, normal, r)
    }

    /// runs a dab and its mirror images
    private func applySymmetric(_ dab: SculptDab)
    {
      guard let volume, let mirror = stroke?.settings.mirror else { return }
      var dabs = [dab]
      for axis in 0 ..< 3 where mirror[axis]
      {
        dabs += dabs.map { Self.mirrored($0, axis) }
      }

      for one in dabs
      {
        let origin: (() -> SculptSnapshot)? = one.brush == .grab
          ? { [unowned self] in SculptSnapshot(copies: [:], states: self.stroke?.record ?? [:], volume: volume) }
          : nil
        volume.changed.removeAll(keepingCapacity: true)
        let keys = volume.apply(one, origin: origin)
        { [unowned self] k, make in
          if self.stroke?.record[k] == nil { self.stroke?.record[k] = make() }
        }

        // bricks the dab readied but left as they were mesh the same, so only the changed ones are meshed again
        stroke?.touched.formUnion(keys)
        markNear(volume.changed)
      }
    }

    private static func mirrored(_ dab: SculptDab, _ axis: Int) -> SculptDab
    {
      func flip(_ v: SIMD3<Float>) -> SIMD3<Float>
      {
        var v = v
        v[axis] = -v[axis]
        return v
      }

      var out = dab
      out.center = flip(dab.center)
      out.normal = flip(dab.normal)
      out.delta = flip(dab.delta)
      out.anchor = flip(dab.anchor)
      out.previous = flip(dab.previous)
      return out
    }
  }
}
