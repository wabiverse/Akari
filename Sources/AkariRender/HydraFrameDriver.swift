
import AkariCore
import CNanocolor
import Foundation
import OpenUSDKit
import HydraKit


public extension Akari
{
  protocol HydraFrameDriver: Hydra.FrameDelegate
  {
    func snapshot() -> Akari.RenderStats
  }
  
  final class FrameDriver: HydraFrameDriver
  {
    /// the active usd stage.
    public let stage: UsdStage

    /// weak: the app owns the hydra render engine.
    public weak var engine: Hydra.RenderEngine?
    public weak var akari: Akari.RenderEngine?
    
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
    }
    
    public init(stage: UsdStage, hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      self.stage = stage
      self.engine = hydra
      self.akari = akari
      
      self.engine?.frameDelegate = self
      // akari outlines the selection in its own graph.
      self.engine?.drawsSelectionOutline = false
    }
    
    public func snapshot() -> Akari.RenderStats
    {
      statsLock.lock()
      defer { statsLock.unlock() }
      return stats
    }
    
    public func hydraWillPull(deltaTime: Double)
    {
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

      advanceTime(by: deltaTime)
      syncSelection()
    }

    public func hydraDidPull()
    {}

    /// Hands Hydra's selection to Akari's outline,
    /// rebuilding the labels only when it changed.
    private func syncSelection()
    {
      guard let engine, let akari else { return }

      let key = SelectionKey(primId: engine.selectedPrimId,
                             groupVersion: engine.selectionUsesGroup ? engine.selectionGroupVersion : nil,
                             modelsVersion: engine.selectionSelectAll ? engine.selectionModelLUTVersion : nil)
      if key != selectionKey
      {
        selectionKey = key
        if engine.selectionSelectAll
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
      let rgb = nc_ref_TransformColor(nc_ref_GetNamedColorSpace("lin_rec709_scene"),
                                      nc_ref_GetNamedColorSpace("srgb_rec709_scene"),
                                      nc_ref_RGB(r: c[0], g: c[1], b: c[2]))
      let color = SIMD4(rgb.r, rgb.g, rgb.b, c[3])
      akari.selection = selectionLabels.map
      {
        Akari.Selection(labels: $0.labels, all: $0.all, color: color, width: engine.selectionOutlineWidth)
      }
    }

    /// Loops the stage's animation, held while the light probes bake.
    private func advanceTime(by deltaTime: Double)
    {
      guard
        stage.HasAuthoredTimeCodeRange(),
        let engine,
        let akari
      else { return }

      if akari.settings.features.contains(.lightProbes), !akari.labfx.lightProbes.isReady { return }

      let start = stage.getStartTimeCode()
      let end = stage.GetEndTimeCode()
      let range = end - start
      guard range > 0 else { return }

      let step = min(max(deltaTime, 1.0 / 240.0), 1.0 / 20.0) * stage.GetTimeCodesPerSecond()
      var next = engine.currentTimeCode + step
      if next > end
      {
        next = start + (next - start).truncatingRemainder(dividingBy: range)
      }
      engine.currentTimeCode = next
    }
  }
}
