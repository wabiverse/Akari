
import AkariCore
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
    
    private var lastPullStart: CFAbsoluteTime = 0
    
    private let statsLock = NSLock()
    private var stats = Akari.RenderStats()
    
    public init(stage: UsdStage, hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      self.stage = stage
      self.engine = hydra
      self.akari = akari
      
      self.engine?.frameDelegate = self
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
      let frameMs = lastPullStart > 0 ? (pullStart - lastPullStart) * 1000.0 : 0
      lastPullStart = pullStart

      statsLock.lock()
      stats.frameMilliseconds = frameMs
      statsLock.unlock()

      advanceTime(by: deltaTime)
    }

    public func hydraDidPull()
    {}

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
