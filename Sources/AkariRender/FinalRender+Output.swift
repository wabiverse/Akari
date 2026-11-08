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
#if canImport(Metal)
  import AVFoundation
  import CoreMedia
  import CoreVideo
  import ImageIO
  import Metal
  import UniformTypeIdentifiers
#endif

public extension Akari.FinalRender
{
  /// A rendered frame, the display image, and the same
  /// pixels at 16 bits per channel when the output asks
  /// for them.
  struct Frame: Sendable
  {
    public let display: Image
    let wide: [UInt16]?

    public var width: Int
    {
      display.width
    }

    public var height: Int
    {
      display.height
    }
  }

  enum OutputError: Error, CustomStringConvertible
  {
    case encode(URL)
    case movie(String)

    public var description: String
    {
      switch self
      {
        case let .encode(url): "could not write \(url.path)"
        case let .movie(reason): "movie: \(reason)"
      }
    }
  }

  /// Writes the most recent frame, for saving a still render.
  func saveLastFrame(to url: URL) throws
  {
    guard let frame = lastFrame else { return }
    #if canImport(Metal)
      try Self.writePNG(frame, to: url)
    #endif
  }
}

#if canImport(Metal)

  extension Akari.FinalRender
  {
    /// Copies the color AOV into memory, rows flipped top to bottom (the AOV is stored bottom up)
    /// and opaque, as the viewport shows it.
    static func readback(_ texture: MTLTexture, queue: MTLCommandQueue, depth: ColorDepth) -> Frame?
    {
      let width = texture.width
      let height = texture.height
      let bytesPerPixel: Int
      switch texture.pixelFormat
      {
        case .rgba16Float: bytesPerPixel = 8
        case .rgba32Float: bytesPerPixel = 16
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb: bytesPerPixel = 4
        default: return nil
      }

      let bytesPerRow = width * bytesPerPixel

      guard
        texture.textureType == .type2D,
        let buffer = queue.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
        let commands = queue.makeCommandBuffer(),
        let blit = commands.makeBlitCommandEncoder()
      else { return nil }

      blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
      blit.endEncoding()
      commands.commit()
      commands.waitUntilCompleted()

      var display = [UInt8](repeating: 255, count: width * height * 4)
      var wide = depth == .sixteen ? [UInt16](repeating: .max, count: width * height * 4) : nil
      let raw = buffer.contents()
      let swapsRedBlue = texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb

      for y in 0 ..< height
      {
        let source = raw + (height - 1 - y) * bytesPerRow
        for x in 0 ..< width
        {
          var rgb: (Float, Float, Float)
          switch bytesPerPixel
          {
            case 8:
              let p = source.assumingMemoryBound(to: Float16.self) + x * 4
              rgb = (Float(p[0]), Float(p[1]), Float(p[2]))
            case 16:
              let p = source.assumingMemoryBound(to: Float.self) + x * 4
              rgb = (p[0], p[1], p[2])
            default:
              let p = source.assumingMemoryBound(to: UInt8.self) + x * 4
              rgb = (Float(p[0]) / 255, Float(p[1]) / 255, Float(p[2]) / 255)
              if swapsRedBlue { rgb = (rgb.2, rgb.1, rgb.0) }
          }

          let o = (y * width + x) * 4
          let channels = [rgb.0, rgb.1, rgb.2]
          for c in 0 ..< 3
          {
            let v = min(max(channels[c].isFinite ? channels[c] : 0, 0), 1)
            display[o + c] = UInt8((v * 255).rounded())
            wide?[o + c] = UInt16((v * 65535).rounded())
          }
        }
      }

      return Frame(display: Image(width: width, height: height, rgba: display), wide: wide)
    }

    /// Writes an sRGB PNG, at 16 bits per channel when the frame carries them.
    static func writePNG(_ frame: Frame, to url: URL, color: ColorMode = .rgba) throws
    {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

      let width = frame.width
      let height = frame.height
      let channels = color == .bw ? 1 : 4
      let data: Data
      let bitsPerComponent: Int
      var bitmapInfo = CGBitmapInfo(rawValue: (color == .rgba ? CGImageAlphaInfo.last
          : color == .rgb ? .noneSkipLast : .none).rawValue)
      if let wide = frame.wide
      {
        data = (color == .bw ? gray(wide) : wide).withUnsafeBufferPointer { Data(buffer: $0) }
        bitsPerComponent = 16
        bitmapInfo.insert(.byteOrder16Little)
      }
      else
      {
        data = Data(color == .bw ? gray(frame.display.rgba) : frame.display.rgba)
        bitsPerComponent = 8
      }

      guard
        let provider = CGDataProvider(data: data as CFData),
        let space = CGColorSpace(name: color == .bw ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB),
        let image = CGImage(width: width, height: height,
                            bitsPerComponent: bitsPerComponent,
                            bitsPerPixel: bitsPerComponent * channels,
                            bytesPerRow: width * bitsPerComponent / 8 * channels,
                            space: space, bitmapInfo: bitmapInfo, provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw OutputError.encode(url) }

      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw OutputError.encode(url) }
    }

    private static func gray<T: FixedWidthInteger & UnsignedInteger>(_ rgba: [T]) -> [T]
    {
      stride(from: 0, to: rgba.count, by: 4).map
      { i in
        T((0.2126 * Double(rgba[i]) + 0.7152 * Double(rgba[i + 1]) + 0.0722 * Double(rgba[i + 2])).rounded())
      }
    }

    /// An H.264 movie, with the stage's soundtrack interleaved as AAC.
    final class MovieWriter
    {
      struct Soundtrack
      {
        let url: URL
        /// Seconds after the first frame the sound starts, negative when it started before.
        let delay: TimeInterval
        /// Seconds into the file playback begins from.
        let mediaOffset: TimeInterval
      }

      private let writer: AVAssetWriter
      private let video: AVAssetWriterInput
      private let adaptor: AVAssetWriterInputPixelBufferAdaptor
      private let width: Int
      private let height: Int
      private let frameRate: Double
      private var audio: AVAssetWriterInput?
      private var reader: AVAssetReader?
      private var readerOutput: AVAssetReaderTrackOutput?
      private var audioShift = CMTime.zero
      private var audioStart = CMTime.zero
      private var pendingAudio: CMSampleBuffer?
      private var frames = 0

      private static let timescale: CMTimeScale = 90000

      init(url: URL, width: Int, height: Int, frameRate: Double, soundtrack: Soundtrack?) throws
      {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        // h.264 wants even dimensions.
        self.width = max(width & ~1, 2)
        self.height = max(height & ~1, 2)
        self.frameRate = frameRate
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: self.width,
          AVVideoHeightKey: self.height,
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Int(Double(self.width * self.height) * frameRate * 0.35),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: frameRate,
          ],
          AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
          ],
        ])
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: self.width,
          kCVPixelBufferHeightKey as String: self.height,
        ])
        writer.add(video)

        if let soundtrack { try addAudio(soundtrack) }

        guard writer.startWriting()
        else
        {
          throw OutputError.movie(writer.error?.localizedDescription ?? "could not start writing")
        }

        writer.startSession(atSourceTime: .zero)
        reader?.startReading()
      }

      private final class TrackBox: @unchecked Sendable
      {
        var track: AVAssetTrack?
      }

      private func addAudio(_ soundtrack: Soundtrack) throws
      {
        let asset = AVURLAsset(url: soundtrack.url)
        let box = TrackBox()
        let loaded = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .audio)
        { tracks, _ in
          box.track = tracks?.first
          loaded.signal()
        }

        loaded.wait()
        guard let track = box.track else { return }

        let reader = try AVAssetReader(asset: asset)
        // decoded from the top and skipped up to here, an mp3 seek only lands near it.
        let readStart = CMTime(seconds: soundtrack.mediaOffset + max(0, -soundtrack.delay), preferredTimescale: Self.timescale)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: 48000,
          AVNumberOfChannelsKey: 2,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return }
        reader.add(output)

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 48000,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: 256_000,
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { return }
        writer.add(audio)

        self.audio = audio
        self.reader = reader
        readerOutput = output
        audioStart = readStart
        audioShift = CMTime(seconds: max(0, soundtrack.delay), preferredTimescale: Self.timescale) - readStart
      }

      private func time(of frame: Int) -> CMTime
      {
        CMTime(seconds: Double(frame) / frameRate, preferredTimescale: Self.timescale)
      }

      func append(_ image: Akari.FinalRender.Image, index: Int) throws
      {
        while !video.isReadyForMoreMediaData
        {
          pumpAudio(until: time(of: index + Int(frameRate)))
          Thread.sleep(forTimeInterval: 0.002)
        }

        guard let pool = adaptor.pixelBufferPool else { throw OutputError.movie("no pixel buffer pool") }
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
        guard let pixels else { throw OutputError.movie("no pixel buffer") }

        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels)
        {
          let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
          image.rgba.withUnsafeBufferPointer
          { src in
            for y in 0 ..< height
            {
              let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
              for x in 0 ..< width
              {
                let s = (y * image.width + x) * 4
                row[x * 4 + 0] = src[s + 2]
                row[x * 4 + 1] = src[s + 1]
                row[x * 4 + 2] = src[s + 0]
                row[x * 4 + 3] = 255
              }
            }
          }
        }

        CVPixelBufferUnlockBaseAddress(pixels, [])

        guard adaptor.append(pixels, withPresentationTime: time(of: index))
        else
        {
          throw OutputError.movie(writer.error?.localizedDescription ?? "could not append frame \(index)")
        }

        frames = index + 1
        pumpAudio(until: time(of: frames))
      }

      /// Feeds the audio input up to `limit`, as far as it will take right now.
      private func pumpAudio(until limit: CMTime)
      {
        guard let audio, let readerOutput else { return }
        while audio.isReadyForMoreMediaData
        {
          guard let next = pendingAudio ?? readerOutput.copyNextSampleBuffer()
          else
          {
            finishAudio()
            return
          }

          pendingAudio = nil
          guard let buffer = Self.trimmed(next, from: audioStart) else { continue }
          let start = CMSampleBufferGetPresentationTimeStamp(buffer) + audioShift
          if start > limit
          {
            pendingAudio = buffer
            return
          }

          if let shifted = Self.retimed(buffer, by: audioShift)
          {
            audio.append(shifted)
          }
        }
      }

      private func finishAudio()
      {
        audio?.markAsFinished()
        reader?.cancelReading()
        audio = nil
        readerOutput = nil
        pendingAudio = nil
      }

      private static func trimmed(_ buffer: CMSampleBuffer, from start: CMTime) -> CMSampleBuffer?
      {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts < start else { return buffer }
        let count = CMSampleBufferGetNumSamples(buffer)
        let rate = CMSampleBufferGetFormatDescription(buffer)
          .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48000
        let drop = Int(((start - pts).seconds * rate).rounded())
        guard drop < count else { return nil }
        var out: CMSampleBuffer?
        CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: buffer,
                                               sampleRange: CFRange(location: drop, length: count - drop),
                                               sampleBufferOut: &out)
        return out
      }

      private static func retimed(_ buffer: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer?
      {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices
        {
          timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + shift
          timing[i].decodeTimeStamp = .invalid
        }

        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
      }

      /// Closes the movie at the last frame, the sound trimmed to it.
      func finish()
      {
        video.markAsFinished()
        let end = time(of: frames)
        while audio != nil
        {
          pumpAudio(until: end)
          if pendingAudio != nil { finishAudio() }
          else if audio != nil { Thread.sleep(forTimeInterval: 0.002) }
        }

        writer.endSession(atSourceTime: end)

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
      }
    }
  }

#endif
