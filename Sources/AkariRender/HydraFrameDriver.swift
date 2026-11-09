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
import HydraKit
import Nanocolor

@_silgen_name("objc_autoreleasePoolPush")
private func autoreleasePoolPush() -> UnsafeMutableRawPointer?

@_silgen_name("objc_autoreleasePoolPop")
private func autoreleasePoolPop(_ pool: UnsafeMutableRawPointer)

public extension Akari
{
  protocol HydraFrameDriver: Hydra.FrameDelegate
  {
    func snapshot() -> Akari.RenderStats
  }

  final class FrameDriver: HydraFrameDriver
  {
    /// weak: the app owns the hydra render engine.
    public weak var engine: Hydra.RenderEngine?
    public weak var akari: Akari.RenderEngine?
    public var cameraView: Akari.CameraView?
    public var playback: Akari.Playback?
    /// Off for a view nothing is picked in, such as a material preview.
    public var outlinesSelection = true

    /// Start of the current one second average, and the frames pulled in it.
    private var windowStart: CFAbsoluteTime = 0
    private var windowFrames = 0

    private let statsLock = NSLock()
    private var stats = Akari.RenderStats()

    /// Hydra's selection the outline labels were last built for.
    private var selectionKey: SelectionKey?
    private var selectionLabels: (labels: [Int32], all: Bool)?

    private struct SelectionKey: Equatable
    {
      var primId: Int32
      var groupVersion: Int?
      var modelsVersion: Int?
      var objects: Int?
    }

    private var objectSelection: (paths: [String], version: Int)?
    private var primPaths: [(id: Int32, path: String)]?
    private var unresolved = (version: 0, tries: 0, frame: 0)

    /// Outlines these objects in place of Hydra's pick, each on its own, `nil` hands the outline back.
    public func select(objects paths: [String]?)
    {
      statsLock.lock()
      objectSelection = paths.map { ($0, (objectSelection?.version ?? 0) + 1) }
      statsLock.unlock()
    }

    private var missing = false

    /// A just added prim gets its id a frame or so after it's selected, so a selection
    /// with paths the ids don't reach yet looks again for a little while.
    private func retryUnresolved()
    {
      statsLock.lock()
      let resyncs = resyncFrames > 0
      if resyncs { resyncFrames -= 1 }
      statsLock.unlock()
      if resyncs
      {
        primPaths = nil
        selectionKey = nil
        return
      }

      guard missing, objectSelection != nil, unresolved.tries < 12 else { return }
      unresolved.frame += 1
      guard unresolved.frame % 8 == 0 else { return }
      unresolved.tries += 1
      primPaths = nil
      selectionKey = nil
    }

    /// The frames still to look the ids up again, a prim made again under its path
    /// gets its new id only once Hydra syncs, after the frame's selection.
    private var resyncFrames = 0

    /// Forgets the prim ids' paths after prims come or go.
    public func primsChanged()
    {
      statsLock.lock()
      primPaths = nil
      resyncFrames = 3
      objectSelection = objectSelection.map { ($0.paths, $0.version + 1) }
      statsLock.unlock()
    }

    private func objectLabels(_ engine: Hydra.RenderEngine, _ paths: [String]) -> [Int32]
    {
      if primPaths == nil
      {
        let imaging = engine.getEngine()
        var found: [(id: Int32, path: String)] = []
        var misses = 0
        var id: Int32 = 0
        while misses < 1024, id < 4_000_000
        {
          if let path = imaging.decodePrimPath(primId: id, instanceId: -1)
          {
            found.append((id, String(path.GetAsString())))
            misses = 0
          }
          else { misses += 1 }
          id += 1
        }

        primPaths = found
      }

      guard let cache = primPaths, let top = cache.last?.id, !paths.isEmpty else { return [] }
      var labels = [Int32](repeating: 0, count: Int(top) + 1)
      let index = Dictionary(paths.enumerated().map { ($1, Int32($0 + 1)) }, uniquingKeysWith: { a, _ in a })
      var found = Set<Int32>()
      for entry in cache
      {
        var path = Substring(entry.path)
        while !path.isEmpty
        {
          if let label = index[String(path)]
          {
            labels[Int(entry.id)] = label
            found.insert(label)
            break
          }

          guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { break }
          path = path[..<slash]
        }
      }

      missing = found.count < index.count
      return labels
    }

    public init(hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      engine = hydra
      self.akari = akari

      engine?.frameDelegate = self
      // akari outlines the selection in its own graph.
      engine?.drawsSelectionOutline = false
    }

    public func snapshot() -> Akari.RenderStats
    {
      statsLock.lock()
      defer { statsLock.unlock() }
      return stats
    }

    public func hydraWillPull(deltaTime _: Double)
    {
      framePool = autoreleasePoolPush()
      let pullStart = CFAbsoluteTimeGetCurrent()
      if windowStart == 0 { windowStart = pullStart }
      else { windowFrames += 1 }

      let elapsed = pullStart - windowStart
      if elapsed >= 1, windowFrames > 0
      {
        statsLock.lock()
        stats.frameMilliseconds = elapsed * 1000.0 / Double(windowFrames)
        statsLock.unlock()
        windowStart = pullStart
        windowFrames = 0
      }

      playback?.advance()
      cameraView?.update()
      retryUnresolved()
      syncSelection()
    }

    /// Hydra's frame queue runs frames back to back without draining, so every frame's command
    /// buffers, and the textures and buffers they hold, go with the frame.
    public func hydraDidPull()
    {
      if let pool = framePool
      {
        framePool = nil
        autoreleasePoolPop(pool)
      }
    }

    private var framePool: UnsafeMutableRawPointer?

    /// Hands Hydra's selection to Akari's outline,
    /// rebuilding the labels only when it changed.
    private func syncSelection()
    {
      guard outlinesSelection, let engine, let akari else { return }

      statsLock.lock()
      let objects = objectSelection
      statsLock.unlock()
      let key = objects.map { SelectionKey(primId: -1, objects: $0.version) }
        ?? SelectionKey(primId: engine.selectedPrimId,
                        groupVersion: engine.selectionUsesGroup ? engine.selectionGroupVersion : nil,
                        modelsVersion: engine.selectionSelectAll ? engine.selectionModelLUTVersion : nil)
      if key != selectionKey
      {
        selectionKey = key
        if let objects
        {
          let labels = objectLabels(engine, objects.paths)
          selectionLabels = labels.isEmpty ? nil : (labels, false)
          if unresolved.version != objects.version { unresolved = (objects.version, 0, 0) }
        }
        else if engine.selectionSelectAll
        {
          // model ids are hashes, renumber them so each stays exact as a float.
          var numbers: [Int32: Int32] = [:]
          let labels = engine.selectionModelLUT.map
          { model in
            if let number = numbers[model] { return number }
            let number = Int32(numbers.count + 1)
            numbers[model] = number
            return number
          }

          selectionLabels = (labels, true)
        }
        else if engine.selectionUsesGroup
        {
          selectionLabels = (engine.selectionGroup, false)
        }
        else if engine.selectedPrimId >= 0
        {
          var labels = [Int32](repeating: 0, count: Int(engine.selectedPrimId) + 1)
          labels[Int(engine.selectedPrimId)] = 1
          selectionLabels = (labels, false)
        }
        else
        {
          selectionLabels = nil
        }
      }

      // display sRGB in, akari composites before hydra's color correction.
      let c = engine.selectionOutlineColor
      let rgb = transformColor(to: namedColorSpace("lin_rec709_scene")!,
                               from: namedColorSpace("srgb_rec709_scene")!,
                               RGB(r: c[0], g: c[1], b: c[2]))
      let color = SIMD4(rgb.r, rgb.g, rgb.b, c[3])
      akari.selection = selectionLabels.map
      {
        Akari.Selection(labels: $0.labels, all: $0.all, color: color, width: engine.selectionOutlineWidth)
      }
    }
  }
}
