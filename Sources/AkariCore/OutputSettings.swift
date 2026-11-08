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

/// The file each rendered frame is written as.
public enum OutputFormat: String, Sendable, CaseIterable
{
  /// One image per frame, numbered.
  case png
  /// A single movie, with the stage's soundtrack.
  case mpeg4
}

/// Bits per channel for image output.
public enum ColorDepth: Int, Sendable, CaseIterable
{
  case eight = 8
  case sixteen = 16
}

/// The channels an image is written with.
public enum ColorMode: String, Sendable, CaseIterable
{
  case bw
  case rgb
  case rgba
}

/// Where and how final renders are written, the counterpart
/// to the render settings that decide how a frame looks.
public struct OutputSettings: Sendable, Equatable
{
  /// Width of the final image in pixels, before `percentage`.
  public var resolutionX: Int = 1920
  /// Height of the final image in pixels, before `percentage`.
  public var resolutionY: Int = 1080
  /// Scales both dimensions, 100 renders at full size.
  public var percentage: Int = 100
  /// First frame, a stage time code.
  public var frameStart: Int = 1
  /// Last frame, inclusive.
  public var frameEnd: Int = 250
  /// Renders every n-th frame.
  public var frameStep: Int = 1
  /// Playback rate written into movies, in frames per second.
  public var frameRate: Double = 24
  /// The camera prim rendered through, `nil` renders the viewport's view.
  public var cameraPath: String?
  /// Output path, `#` runs are replaced with the zero padded frame number.
  public var path: String = "/tmp/akari/####"
  public var format: OutputFormat = .png
  public var colorMode: ColorMode = .rgba
  public var colorDepth: ColorDepth = .eight
  /// Appends the format's extension to the output path.
  public var fileExtensions: Bool = true
  /// Rerenders frames whose file already exists.
  public var overwrite: Bool = true
  /// Writes an empty file before a frame renders, so other
  /// renders of the same output skip it when `overwrite` is
  /// off.
  public var placeholders: Bool = false
  /// Muxes the stage's spatial audio into movies.
  public var audio: Bool = true

  public init()
  {}

  /// The size of the image that gets written.
  public var pixelSize: (width: Int, height: Int)
  {
    let scale = Double(min(max(percentage, 1), 1000)) / 100
    return (max(Int((Double(resolutionX) * scale).rounded()), 1),
            max(Int((Double(resolutionY) * scale).rounded()), 1))
  }

  /// The frames an animation render visits, in order.
  public var frames: [Int]
  {
    guard frameEnd >= frameStart else { return [frameStart] }
    return Array(stride(from: frameStart, through: frameEnd, by: max(frameStep, 1)))
  }

  /// The file a frame is written to, `path` with its `#` run filled in,
  /// four digits when it has none, and the format's extension appended.
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

  /// The movie a whole animation is written to.
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

  /// Only the last path component is searched, so `#` in a directory name stays put.
  private func hashSearchRange(in name: String) -> Range<String.Index>
  {
    let slash = name.lastIndex(of: "/").map { name.index(after: $0) } ?? name.startIndex
    return slash ..< name.endIndex
  }
}

extension OutputFormat: CustomStringConvertible
{
  /// Human label for UI (pickers, HUD).
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
  /// Human label for UI (pickers, HUD).
  public var description: String
  {
    "\(rawValue)"
  }
}
