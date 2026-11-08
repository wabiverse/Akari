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
import simd

extension Akari.ShadowAtlas
{
  /// Holds the sun's levels coarse while it moves,
  /// then forces a few fine redraws once it settles.
  struct SunMotion
  {
    static let movingLodBias: Float = 2
    /// Long enough to bridge a slow slider drag's gaps between steps.
    static let holdDuration = 45
    /// Frames the fine levels stay forced after the bias drops.
    static let settleDuration = 5

    public private(set) var smoothDirection: SIMD3<Float> = SIMD3<Float>(0, 1, 0)

    private var movingFrames = 0
    private var settleFrames = 0

    var lodBias: Float
    {
      movingFrames > 0 ? Self.movingLodBias : 0
    }

    /// Returns true when the directional pages must be redrawn this frame.
    mutating func advance(to direction: SIMD3<Float>) -> Bool
    {
      let blendFactor: Float = 0.08
      let continuousGlide = simd_mix(smoothDirection, direction, SIMD3<Float>(repeating: blendFactor))
      
      let nextSmooth = Akari.ShadowAtlas.quantize(Akari.Math.normalize(continuousGlide))
      
      let stepped = nextSmooth != smoothDirection
      
      let biasDropping = !stepped && movingFrames == 1
      if stepped { movingFrames = Self.holdDuration; settleFrames = 0 }
      else if movingFrames > 0 { movingFrames -= 1 }
      else if settleFrames > 0 { settleFrames -= 1 }
      
      let changed = stepped || biasDropping || settleFrames > 0
      if biasDropping { settleFrames = Self.settleDuration }
      
      smoothDirection = nextSmooth
      
      return changed
    }
  }

  struct DirectionalHistory
  {
    private var slotForLevel: [Int32: Int] = [:]
    private var freeSlotOffsets: [Int] = Array(0 ..< maxDirectionalTilemaps)
    private var lastGridOffset: [SIMD2<Int32>?] = Array(repeating: nil, count: maxDirectionalTilemaps)
    private var lastRotationFingerprint: [UInt64?] = Array(repeating: nil, count: maxDirectionalTilemaps)
    private var lastLevel: [Int32?] = Array(repeating: nil, count: maxDirectionalTilemaps)
    private var lastDepth: [SIMD3<Float>?] = Array(repeating: nil, count: maxDirectionalTilemaps)
    /// Per directional slot offset.
    private(set) var pendingShift: [SIMD2<Int32>] = Array(repeating: .zero, count: maxDirectionalTilemaps)

    /// Directional tilemaps active as of the last `render`, in loop position order.
    var slots: [Int] = []
    var view: Akari.Matrix4 = .identity

    /// Stable per tilemap slot for each active directional entry, in fit order.
    mutating func assignSlots(_ directional: [Cascade], technique: ShadowSettings.Technique) -> [Int]
    {
      switch technique
      {
        case .cascaded:
          return Array(0 ..< directional.count)

        case .clipmap:
          let activeLevels = Set(directional.map(\.absoluteLevel))
          return directional.map
          { cascade in
            if let existing = slotForLevel[cascade.absoluteLevel] { return existing }
            if
              freeSlotOffsets.isEmpty,
              let staleLevel = slotForLevel.keys.first(where: { !activeLevels.contains($0) })
            {
              freeSlotOffsets.append(slotForLevel.removeValue(forKey: staleLevel)!)
            }

            let offset = freeSlotOffsets.popLast() ?? 0
            slotForLevel[cascade.absoluteLevel] = offset
            return offset
          }
      }
    }

    mutating func updateShifts(_ directional: [Cascade], slots: [Int])
    {
      pendingShift = Array(repeating: .zero, count: maxDirectionalTilemaps)
      for (i, offset) in slots.enumerated()
      {
        let cascade = directional[i]
        let gridOffset = SIMD2<Int32>(cascade.gridOffsetX, cascade.gridOffsetY)
        let rotationFingerprint = rotationOnlyFingerprint(cascade.view)

        var isDirty = lastGridOffset[offset] == nil
        if let lastRotation = lastRotationFingerprint[offset], lastRotation != rotationFingerprint
        {
          isDirty = true
        }

        if let previousLevel = lastLevel[offset], previousLevel != cascade.absoluteLevel
        {
          isDirty = true
        }

        let depth = SIMD3<Float>(cascade.view.transform(.zero).z, cascade.zScale, cascade.zBias)
        if let previousDepth = lastDepth[offset], previousDepth != depth
        {
          isDirty = true
        }

        lastDepth[offset] = depth
        if let last = lastGridOffset[offset]
        {
          let delta = gridOffset &- last
          if abs(delta.x) > Int32(tilemapRes) || abs(delta.y) > Int32(tilemapRes)
          {
            isDirty = true
          }
        }

        lastRotationFingerprint[offset] = rotationFingerprint
        lastLevel[offset] = cascade.absoluteLevel

        pendingShift[offset] = isDirty
          ? SIMD2<Int32>(Int32(tilemapRes), Int32(tilemapRes))
          : gridOffset &- lastGridOffset[offset]!
        lastGridOffset[offset] = gridOffset
      }
    }
  }

  struct PunctualHistory
  {
    private var lastFingerprint: [UInt64?] = Array(repeating: nil, count: maxPunctualTilemaps)
    /// Punctual only dirty bits.
    var pendingDirty: Int32 = 0

    mutating func update(_ punctualFaces: [[PunctualFace]])
    {
      for lightIdx in 0 ..< maxPunctualLights where punctualFaces[lightIdx].count == 6
      {
        for face in 0 ..< facesPerLight
        {
          let slot = lightIdx * facesPerLight + face
          let key = fingerprint(punctualFaces[lightIdx][face].viewProjection)
          if
            let last = lastFingerprint[slot],
            last != key
          {
            pendingDirty |= (1 << Int32(slot))
          }

          lastFingerprint[slot] = key
        }
      }
    }
  }

  /// What `markPageUsage` fit for `render` to draw this frame.
  struct FrameFit
  {
    var directional: [Cascade] = []
    var slots: [Int] = []
    var punctualFaces: [[PunctualFace]] = []
    var lightDirection = SIMD3<Float>(0, 0, 1)
    var cameraWorld = SIMD3<Float>.zero
    var sunChanged = false
    var isCurrent = false
    var castersMoved = false
    var redraw = CasterRedraw.none
    /// Moved static caster boxes, uploaded to `Frame.movedStaticBoxes`, whose tiles redraw.
    var staticRedraw = 0
  }

  /// What a scene change left stale in the shadow pages.
  enum CasterRedraw: Equatable
  {
    case none
    /// Only around this many moved boxes, uploaded to `Frame.movedBoxes`.
    case boxes(Int)
    case all

    var isNeeded: Bool
    {
      self != .none && self != .boxes(0)
    }
  }

  /// Finds the casters that moved or changed between scene revisions.
  /// A batch's caster boxes, six floats each, and their keys, read in place from the batch.
  public typealias Casters = (bounds: [Float], keys: [UInt64])

  /// Finds the casters that moved or changed between scene revisions.
  struct CasterMotion
  {
    /// Each caster's hash of its box and key, sorted, with where it sits across `parts`.
    private var previous: (hashes: [UInt64], order: [Int32], parts: [Casters])?

    private static func sorted(_ parts: [Casters]) -> (hashes: [UInt64], order: [Int32])
    {
      var hashes: [UInt64] = []
      hashes.reserveCapacity(parts.reduce(0) { $0 + min($1.keys.count, $1.bounds.count / 6) })
      for part in parts
      {
        part.bounds.withUnsafeBufferPointer
        { b in
          for i in 0 ..< min(part.keys.count, b.count / 6)
          {
            var h: UInt64 = 14_695_981_039_346_656_037 ^ part.keys[i]
            for k in 0 ..< 6 { h = (h ^ UInt64(b[i * 6 + k].bitPattern)) &* 1_099_511_628_211 }
            hashes.append(h ^ (h >> 29))
          }
        }
      }

      let order = (0 ..< Int32(hashes.count)).sorted { hashes[Int($0)] < hashes[Int($1)] }
      return (order.map { hashes[Int($0)] }, order)
    }

    private static func box(_ parts: [Casters], _ index: Int32) -> ArraySlice<Float>
    {
      var i = Int(index)
      for part in parts
      {
        let count = min(part.keys.count, part.bounds.count / 6)
        if i < count { return part.bounds[i * 6 ..< i * 6 + 6] }
        i -= count
      }

      return []
    }

    /// Old and new boxes of every changed caster, six floats each, merged down
    /// to `limit` boxes past it. nil on the first frame, when every shadow has
    /// to redraw.
    mutating func movedBoxes(_ parts: [Casters], limit: Int) -> [Float]?
    {
      let next = Self.sorted(parts)
      defer { previous = (next.hashes, next.order, parts) }
      guard let previous else { return nil }

      var moved: [Float] = []
      var i = 0, j = 0
      let a = next.hashes, b = previous.hashes
      while i < a.count || j < b.count
      {
        let h = i < a.count && (j >= b.count || a[i] <= b[j]) ? a[i] : b[j]
        let firstNew = i, firstOld = j
        while i < a.count, a[i] == h { i += 1 }
        while j < b.count, b[j] == h { j += 1 }
        guard i - firstNew != j - firstOld else { continue }
        moved += i > firstNew ? Self.box(parts, next.order[firstNew]) : Self.box(previous.parts, previous.order[firstOld])
      }

      return moved.count / 6 > limit ? Self.merge(moved, into: limit) : moved
    }

    /// Unions neighboring boxes, in Morton order of their centers,
    /// into `limit` boxes.
    private static func merge(_ boxes: [Float], into limit: Int) -> [Float]
    {
      let count = boxes.count / 6
      func box(_ i: Int) -> (min: SIMD3<Float>, max: SIMD3<Float>)
      {
        let o = i * 6
        return (SIMD3(boxes[o], boxes[o + 1], boxes[o + 2]), SIMD3(boxes[o + 3], boxes[o + 4], boxes[o + 5]))
      }

      var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var hi = -lo
      for i in 0 ..< count
      {
        lo = pointwiseMin(lo, box(i).min)
        hi = pointwiseMax(hi, box(i).max)
      }

      let scale = 1023 / pointwiseMax(hi - lo, SIMD3(repeating: 1e-6))

      func spread(_ v: UInt32) -> UInt32
      {
        var x = v & 0x3FF
        x = (x | (x << 16)) & 0x0300_00FF
        x = (x | (x << 8)) & 0x0300_F00F
        x = (x | (x << 4)) & 0x030C_30C3
        x = (x | (x << 2)) & 0x0924_9249
        return x
      }

      let keys = (0 ..< count).map
      { i in
        let q = (((box(i).min + box(i).max) * 0.5 - lo) * scale).rounded(.down)
        return spread(UInt32(q.x)) | (spread(UInt32(q.y)) << 1) | (spread(UInt32(q.z)) << 2)
      }

      let order = (0 ..< count).sorted { keys[$0] < keys[$1] }

      var merged: [Float] = []
      merged.reserveCapacity(limit * 6)
      for group in 0 ..< limit
      {
        let members = order[group * count / limit ..< (group + 1) * count / limit]
        guard let first = members.first else { continue }
        var groupMin = box(first).min
        var groupMax = box(first).max
        for i in members
        {
          groupMin = pointwiseMin(groupMin, box(i).min)
          groupMax = pointwiseMax(groupMax, box(i).max)
        }

        merged += [groupMin.x, groupMin.y, groupMin.z, groupMax.x, groupMax.y, groupMax.z]
      }

      return merged
    }
  }
}
