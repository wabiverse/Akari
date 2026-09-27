
import AkariCore
import Foundation
import HydraKit


public extension Akari
{
  protocol HydraFrameDriver: Hydra.FrameDelegate
  {
    func snapshot() -> Akari.RenderStats
  }
  
  final class FrameDriver: HydraFrameDriver
  {
    private var lastPullStart: CFAbsoluteTime = 0
    
    private let statsLock = NSLock()
    private var stats = Akari.RenderStats()
    
    public init()
    {}
    
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
    }
    
    public func hydraDidPull()
    {}
  }
}
