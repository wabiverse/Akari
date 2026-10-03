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
    static let settleDuration = 3

    private var lastDirection: SIMD3<Float>?
    private var movingFrames = 0
    private var settleFrames = 0

    var lodBias: Float
    {
      movingFrames > 0 ? Self.movingLodBias : 0
    }

    /// Returns true when the directional pages must be redrawn this frame.
    mutating func advance(to direction: SIMD3<Float>) -> Bool
    {
      let stepped = direction != lastDirection
      let biasDropping = !stepped && movingFrames == 1
      if stepped { movingFrames = Self.holdDuration; settleFrames = 0 }
      else if movingFrames > 0 { movingFrames -= 1 }
      else if settleFrames > 0 { settleFrames -= 1 }
      let changed = stepped || biasDropping || settleFrames > 0
      if biasDropping { settleFrames = Self.settleDuration }
      lastDirection = direction
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
    /// Last fit invalidated a cube face.
    var invalidated = false

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
  struct CasterMotion
  {
    private struct Caster: Hashable
    {
      var min: SIMD3<Float>
      var max: SIMD3<Float>
      var key: UInt64
    }

    private var previous: [Caster: Int]?

    /// Old and new boxes of every changed caster, six floats each, merged down
    /// to `limit` boxes past it. nil on the first frame, when every shadow has
    /// to redraw.
    mutating func movedBoxes(bounds: [Float], keys: [UInt64], limit: Int) -> [Float]?
    {
      var next: [Caster: Int] = [:]
      next.reserveCapacity(keys.count)
      for i in 0 ..< min(keys.count, bounds.count / 6)
      {
        let o = i * 6
        let caster = Caster(min: SIMD3(bounds[o], bounds[o + 1], bounds[o + 2]),
                            max: SIMD3(bounds[o + 3], bounds[o + 4], bounds[o + 5]),
                            key: keys[i])
        next[caster, default: 0] += 1
      }
      defer { self.previous = next }
      guard let previous else { return nil }

      var moved: [Float] = []
      func add(_ c: Caster)
      {
        moved += [c.min.x, c.min.y, c.min.z, c.max.x, c.max.y, c.max.z]
      }
      for (caster, count) in next where previous[caster] != count
      {
        add(caster)
      }
      for (caster, _) in previous where next[caster] == nil
      {
        add(caster)
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
