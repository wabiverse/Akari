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
import HydraKit
#if canImport(AVFoundation)
  import AVFoundation
#endif

public extension Akari
{
  /// The timeline plays at the scene's frame rate, looping between
  /// its start and end frames, with the stage's soundtrack playing
  /// in time with it.
  final class Playback: @unchecked Sendable
  {
    public weak var hydra: Hydra.RenderEngine?
    public weak var akari: Akari.RenderEngine?

    private let lock = NSLock()
    private var direction = 0.0
    private var _range: ClosedRange<Double>
    private var _frameRate: Double
    private var _muted = false
    private var pendingSeek: Double?
    private var epoch = 0

    private var anchor: (timeCode: Double, uptime: Double, epoch: Int)?
    private var audible = false
    private let soundtrack: Soundtrack?

    public init(hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      self.hydra = hydra
      self.akari = akari
      let info = Pixar.HdAkariInspectStage(hydra.stage)
      let timeCodesPerSecond = info.timeCodesPerSecond > 0 ? info.timeCodesPerSecond : 24
      _range = info.startTimeCode ... max(info.endTimeCode, info.startTimeCode)
      _frameRate = timeCodesPerSecond
      let path = String(info.soundtrack)
      soundtrack = path.isEmpty ? nil : Soundtrack(url: URL(fileURLWithPath: path),
                                                   startTimeCode: info.soundtrackStartTimeCode,
                                                   mediaOffset: info.soundtrackMediaOffset,
                                                   gain: info.soundtrackGain,
                                                   timeCodesPerSecond: timeCodesPerSecond)
    }

    public var isPlaying: Bool
    {
      lock.withLock { direction != 0 }
    }

    public var isReversed: Bool
    {
      lock.withLock { direction < 0 }
    }

    public var hasSoundtrack: Bool
    {
      soundtrack != nil
    }

    /// The frames played, start and end inclusive.
    public var range: ClosedRange<Double>
    {
      get { lock.withLock { _range } }
      set { lock.withLock { _range = newValue } }
    }

    /// Frames per second.
    public var frameRate: Double
    {
      get { lock.withLock { _frameRate } }
      set { lock.withLock { _frameRate = newValue; epoch += 1 } }
    }

    public var isMuted: Bool
    {
      get { lock.withLock { _muted } }
      set { lock.withLock { _muted = newValue; epoch += 1 } }
    }

    /// The current frame, a seek not yet applied included.
    public var frame: Double
    {
      lock.withLock { pendingSeek } ?? hydra?.currentTimeCode ?? 0
    }

    public func play(reverse: Bool = false)
    {
      lock.withLock
      {
        direction = reverse ? -1 : 1
        epoch += 1
      }
    }

    public func pause()
    {
      lock.withLock { direction = 0 }
    }

    /// Plays, or pauses when already playing that way.
    public func toggle(reverse: Bool = false)
    {
      lock.withLock
      {
        direction = direction == (reverse ? -1 : 1) ? 0 : reverse ? -1 : 1
        epoch += 1
      }
    }

    public func seek(to frame: Double)
    {
      lock.withLock
      {
        pendingSeek = frame
        epoch += 1
      }
    }

    public func jump(toEnd: Bool)
    {
      let range = range
      seek(to: toEnd ? range.upperBound : range.lowerBound)
    }

    public func step(by frames: Int)
    {
      seek(to: frame.rounded(.down) + Double(frames))
    }

    /// The first frame each of the stage's authored light probes shows.
    public static func probeBakeTimes(_ stage: UsdStage) -> [Double]
    {
      var times = [Double](repeating: 0, count: 16)
      let count = times.withUnsafeMutableBufferPointer { Int(Pixar.HdAkariProbeBakeTimes(stage, $0.baseAddress!, 16)) }
      return Array(times.prefix(count))
    }

    /// Bakes the light probes at `times` as the stage loads, then comes back, so playback never waits on a bake.
    public func prebakeProbes(at times: [Double]) async
    {
      guard !times.isEmpty, let akari, let hydra else { return }
      let home = hydra.currentTimeCode
      let began = ProcessInfo.processInfo.systemUptime
      defer { print("[akari] light probes baked at \(times.map { Int($0) }) in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - began)) s") }
      for time in times
      {
        seek(to: time)
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        // a few frames drawn there first, so the probes it shows have been seen.
        while hydra.currentTimeCode != time, ProcessInfo.processInfo.systemUptime < deadline
        {
          try? await Task.sleep(for: .milliseconds(20))
        }
        let seen = akari.viewportFrames + 3
        while akari.viewportFrames < seen, ProcessInfo.processInfo.systemUptime < deadline
        {
          try? await Task.sleep(for: .milliseconds(20))
        }
        while akari.labfx.lightProbes.isBaking, ProcessInfo.processInfo.systemUptime < deadline
        {
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
      seek(to: home)
    }

    /// Moves time along, on the frame queue before each frame.
    func advance()
    {
      guard let hydra else { return }
      let (direction, range, rate, muted, seek, epoch) = lock.withLock
      {
        defer { pendingSeek = nil }
        return (self.direction, _range, _frameRate, _muted, pendingSeek, self.epoch)
      }
      if let seek { hydra.currentTimeCode = seek }
      akari?.labfx.isPlaying = direction != 0

      guard direction != 0, rate > 0
      else
      {
        anchor = nil
        silence()
        return
      }

      let now = ProcessInfo.processInfo.systemUptime
      if anchor?.epoch != epoch
      {
        var start = hydra.currentTimeCode
        if start < range.lowerBound || start >= range.upperBound + 1 { start = direction > 0 ? range.lowerBound : range.upperBound }
        restart(at: start, now: now, epoch: epoch, forward: direction > 0, rate: rate, muted: muted)
      }
      guard let anchor else { return }

      var t = anchor.timeCode + direction * (now - anchor.uptime) * rate
      if t >= range.upperBound + 1
      {
        t = range.lowerBound + (t - range.upperBound - 1).truncatingRemainder(dividingBy: range.upperBound + 1 - range.lowerBound)
        restart(at: t, now: now, epoch: epoch, forward: true, rate: rate, muted: muted)
      }
      else if t < range.lowerBound
      {
        t = range.upperBound - (range.lowerBound - t).truncatingRemainder(dividingBy: range.upperBound + 1 - range.lowerBound)
        restart(at: t, now: now, epoch: epoch, forward: false, rate: rate, muted: muted)
      }
      hydra.currentTimeCode = min(t, range.upperBound)
    }

    private func restart(at timeCode: Double, now: Double, epoch: Int, forward: Bool, rate: Double, muted: Bool)
    {
      anchor = (timeCode, now, epoch)
      if forward, !muted, let soundtrack
      {
        soundtrack.play(at: timeCode, frameRate: rate)
        audible = true
      }
      else
      {
        silence()
      }
    }

    private func silence()
    {
      guard audible else { return }
      audible = false
      soundtrack?.stop()
    }
  }
}

#if canImport(AVFoundation)

  /// The stage's soundtrack, decoded whole up front so a seek lands on the exact sample.
  private final class Soundtrack: @unchecked Sendable
  {
    private let queue = DispatchQueue(label: "akari.soundtrack")
    private let url: URL
    private let startTimeCode: Double
    private let mediaOffset: Double
    private let gain: Float
    private let timeCodesPerSecond: Double

    private var pcm: AVAudioPCMBuffer?
    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()

    init?(url: URL, startTimeCode: Double, mediaOffset: Double, gain: Double, timeCodesPerSecond: Double)
    {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      self.url = url
      self.startTimeCode = startTimeCode
      self.mediaOffset = mediaOffset
      self.gain = Float(gain)
      self.timeCodesPerSecond = timeCodesPerSecond
      queue.async { self.decode() }
    }

    private func decode()
    {
      guard
        let file = try? AVAudioFile(forReading: url),
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
        (try? file.read(into: buffer)) != nil
      else { return }
      pcm = buffer
    }

    func play(at timeCode: Double, frameRate: Double)
    {
      queue.async
      { [self] in
        guard let pcm, start(pcm.format) else { return }
        player.stop()
        let speed = frameRate / timeCodesPerSecond
        varispeed.rate = Float(speed)
        player.volume = gain

        let position = (timeCode - startTimeCode) / timeCodesPerSecond + mediaOffset
        let first = AVAudioFramePosition(max(position, 0) * pcm.format.sampleRate)
        guard first < AVAudioFramePosition(pcm.frameLength), let rest = Self.tail(of: pcm, from: first) else { return }
        player.scheduleBuffer(rest)
        if position < 0
        {
          let delay = AVAudioTime.hostTime(forSeconds: -position / speed)
          player.play(at: AVAudioTime(hostTime: mach_absolute_time() + delay))
        }
        else
        {
          player.play()
        }
      }
    }

    func stop()
    {
      queue.async { [self] in player.stop() }
    }

    private func start(_ format: AVAudioFormat) -> Bool
    {
      if let engine, engine.isRunning { return true }
      let engine = engine ?? AVAudioEngine()
      if self.engine == nil
      {
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        self.engine = engine
      }
      return (try? engine.start()) != nil
    }

    private static func tail(of pcm: AVAudioPCMBuffer, from first: AVAudioFramePosition) -> AVAudioPCMBuffer?
    {
      let count = AVAudioFrameCount(AVAudioFramePosition(pcm.frameLength) - first)
      guard
        let tail = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: count),
        let source = pcm.floatChannelData,
        let target = tail.floatChannelData
      else { return nil }
      tail.frameLength = count
      let stride = pcm.stride
      for channel in 0 ..< Int(pcm.format.channelCount)
      {
        let offset = pcm.format.isInterleaved ? Int(first) * stride : Int(first)
        let length = pcm.format.isInterleaved ? Int(count) * stride : Int(count)
        target[channel].update(from: source[channel] + offset, count: length)
        if pcm.format.isInterleaved { break }
      }
      return tail
    }
  }

#else

  private final class Soundtrack: @unchecked Sendable
  {
    init?(url _: URL, startTimeCode _: Double, mediaOffset _: Double, gain _: Double, timeCodesPerSecond _: Double)
    {
      nil
    }

    func play(at _: Double, frameRate _: Double) {}
    func stop() {}
  }

#endif
