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

/// the file each rendered frame is written as.
public enum OutputFormat: String, Sendable, CaseIterable
{
  /// one image per frame, numbered.
  case png
  /// a single movie, with the stage's soundtrack.
  case mpeg4
}

/// bits per channel for image output.
public enum ColorDepth: Int, Sendable, CaseIterable
{
  case eight = 8
  case sixteen = 16
}

/// the channels an image is written with.
public enum ColorMode: String, Sendable, CaseIterable
{
  case bw
  case rgb
  case rgba
}

/// where and how final renders are written, beside the render settings that decide how a frame looks
public struct OutputSettings: Sendable, Equatable
{
  /// width of the final image in pixels, before `percentage`.
  public var resolutionX: Int = 1920
  /// height of the final image in pixels, before `percentage`.
  public var resolutionY: Int = 1080
  /// scales both dimensions, 100 renders at full size.
  public var percentage: Int = 100
  /// first frame, a stage time code.
  public var frameStart: Int = 1
  /// last frame, inclusive.
  public var frameEnd: Int = 250
  /// renders every n-th frame.
  public var frameStep: Int = 1
  /// playback rate written into movies, in frames per second.
  public var frameRate: Double = 24
  /// the camera prim rendered through, `nil` renders the viewport's view.
  public var cameraPath: String?
  /// output path, `#` runs are replaced with the zero padded frame number.
  public var path: String = "/tmp/akari/####"
  public var format: OutputFormat = .png
  public var colorMode: ColorMode = .rgba
  public var colorDepth: ColorDepth = .eight
  /// appends the format's extension to the output path.
  public var fileExtensions: Bool = true
  /// rerenders frames whose file already exists.
  public var overwrite: Bool = true
  /// writes an empty file before a frame renders so other renders of the same output skip it when overwrite is off
  public var placeholders: Bool = false
  /// muxes the stage's spatial audio into movies.
  public var audio: Bool = true

  public init()
  {}

  /// the size of the image that gets written.
  public var pixelSize: (width: Int, height: Int)
  {
    let scale = Double(min(max(percentage, 1), 1000)) / 100
    return (max(Int((Double(resolutionX) * scale).rounded()), 1),
            max(Int((Double(resolutionY) * scale).rounded()), 1))
  }

  /// the frames an animation render visits, in order.
  public var frames: [Int]
  {
    guard frameEnd >= frameStart else { return [frameStart] }
    return Array(stride(from: frameStart, through: frameEnd, by: max(frameStep, 1)))
  }

  /// the file a frame is written to, the path's hash run filled with the frame or four digits added, with the format's extension
  public func fileURL(frame: Int) -> URL
  {
    var name = path
    if let range = name.range(of: "#+", options: .regularExpression, range: hashSearchRange(in: name))
    {
      let digits = name.distance(from: range.lowerBound, to: range.upperBound)
      name.replaceSubrange(range, with: String(format: "%0\(digits)d", frame))
    }
    else if format == .png
    {
      name += String(format: "%04d", frame)
    }

    return url(name)
  }

  /// the movie a whole animation is written to.
  public var movieURL: URL
  {
    var name = path
    if let range = name.range(of: "#+", options: .regularExpression, range: hashSearchRange(in: name))
    {
      let digits = name.distance(from: range.lowerBound, to: range.upperBound)
      name.replaceSubrange(range, with: String(format: "%0\(digits)d-%0\(digits)d", frameStart, frameEnd))
    }

    return url(name)
  }

  public var fileExtension: String
  {
    switch format
    {
      case .png: "png"
      case .mpeg4: "mp4"
    }
  }

  private func url(_ name: String) -> URL
  {
    let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
    return fileExtensions ? url.appendingPathExtension(fileExtension) : url
  }

  /// only the last path component is searched, so `#` in a directory name stays put.
  private func hashSearchRange(in name: String) -> Range<String.Index>
  {
    let slash = name.lastIndex(of: "/").map { name.index(after: $0) } ?? name.startIndex
    return slash ..< name.endIndex
  }
}

extension OutputFormat: CustomStringConvertible
{
  /// the label pickers and the hud show
  public var description: String
  {
    switch self
    {
      case .png: "PNG"
      case .mpeg4: "MPEG-4"
    }
  }
}

extension ColorMode: CustomStringConvertible
{
  public var description: String
  {
    switch self
    {
      case .bw: "BW"
      case .rgb: "RGB"
      case .rgba: "RGBA"
    }
  }
}

extension ColorDepth: CustomStringConvertible
{
  /// the label pickers and the hud show
  public var description: String
  {
    "\(rawValue)"
  }
}
