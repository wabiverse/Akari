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
import AkariRender
import Foundation
import SwiftCrossUI

extension AkariDemo
{
  enum MediaType: CaseIterable, CustomStringConvertible
  {
    case image, video

    var description: String
    {
      self == .image ? "Image" : "Video"
    }
  }

  enum VideoContainer: CaseIterable, CustomStringConvertible
  {
    case mpeg4

    var description: String
    {
      "MPEG-4"
    }
  }

  enum VideoCodec: CaseIterable, CustomStringConvertible
  {
    case h264

    var description: String
    {
      "H.264"
    }
  }

  enum AudioCodec: CaseIterable, CustomStringConvertible
  {
    case noAudio, aac

    var description: String
    {
      self == .aac ? "AAC" : "No Audio"
    }
  }

  /// The frame size, rate and range, and where frames are written.
  @MainActor
  struct OutputProperties: View
  {
    @State private var job: RenderJob

    init(job: RenderJob)
    {
      _job = State(wrappedValue: job)
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          PropertiesPanel("Format")
          {
            Properties.row("Resolution X") { NumberField(value: job.$resolutionX, range: 4 ... 65536, unit: "px") }
            Properties.row("Y") { NumberField(value: job.$resolutionY, range: 4 ... 65536, unit: "px") }
            Properties.row("%")
            {
              SliderField(value: Binding(get: { Double(job.percentage) }, set: { job.percentage = Int($0) }),
                          range: 1 ... 100, step: 1) { "\(Int($0))%" }
            }

            Spacer().frame(height: 4)
            Properties.row("Frame Rate") { Dropdown(options: FrameRate.allCases, selection: frameRate) }
            if frameRate.wrappedValue == .custom
            {
              Properties.row("FPS") { NumberField(value: job.$fps, range: 1 ... 1000) }
              Properties.row("Base")
              {
                NumberField(value: job.$fpsBase, range: 0.001 ... 1000, step: 0.001) { String(format: "%.3f", $0) }
              }
            }
          }

          PropertiesPanel("Frame Range")
          {
            Properties.row("Frame Start") { NumberField(value: job.$frameStart) }
            Properties.row("End") { NumberField(value: job.$frameEnd) }
            Properties.row("Step") { NumberField(value: job.$frameStep, range: 1 ... 10000) }
          }

          PropertiesPanel("Output")
          {
            PathField(text: job.$path)
            Properties.row("Saving") { Checkbox(label: "File Extensions", isOn: job.$fileExtensions) }
            Spacer().frame(height: 4)
            Properties.row("Media Type") { Dropdown(options: MediaType.allCases, selection: mediaType) }
            if mediaType.wrappedValue == .video
            {
              PropertiesPanel("Encoding", nested: true)
              {
                Properties.row("Container") { Dropdown(options: VideoContainer.allCases, selection: constant(.mpeg4)) }
                PropertiesPanel("Video", nested: true)
                {
                  Properties.row("Video Codec") { Dropdown(options: VideoCodec.allCases, selection: constant(.h264)) }
                }

                PropertiesPanel("Audio", nested: true)
                {
                  Properties.row("Audio Codec") { Dropdown(options: AudioCodec.allCases, selection: audioCodec) }
                }
              }
            }
            else
            {
              Properties.row("File Format") { Dropdown(options: [OutputFormat.png], selection: job.$format) }
              Properties.row("Color") { Segmented(options: ColorMode.allCases, selection: job.$colorMode) }
              Properties.row("Color Depth") { Segmented(options: ColorDepth.allCases, selection: job.$colorDepth) }
              Spacer().frame(height: 4)
              Properties.row("Image Sequence") { Checkbox(label: "Overwrite", isOn: job.$overwrite) }
              Properties.check("Placeholders", job.$placeholders)
            }
          }
        }
        .padding(6)
      }
    }

    private var frameRate: Binding<FrameRate?>
    {
      Binding(get: { job.customFrameRate ? .custom : FrameRate.preset(fps: job.fps, base: job.fpsBase) ?? .custom },
              set:
              { choice in
                if let rate = choice?.rate
                {
                  job.fps = rate.fps
                  job.fpsBase = rate.base
                  job.customFrameRate = false
                }
                else
                {
                  job.customFrameRate = true
                }
              })
    }

    private var mediaType: Binding<MediaType?>
    {
      Binding(get: { job.format == .mpeg4 ? .video : .image },
              set: { job.format = $0 == .video ? .mpeg4 : .png })
    }

    private var audioCodec: Binding<AudioCodec?>
    {
      Binding(get: { job.audio ? .aac : .noAudio }, set: { job.audio = $0 == .aac })
    }

    private func constant<Value>(_ value: Value) -> Binding<Value?>
    {
      Binding(get: { value }, set: { _ in })
    }
  }

  /// The camera renders look through.
  @MainActor
  struct SceneProperties: View
  {
    @State private var job: RenderJob

    init(job: RenderJob)
    {
      _job = State(wrappedValue: job)
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          PropertiesPanel("Scene")
          {
            Properties.row("Camera")
            {
              Dropdown(options: job.cameras, selection: job.$camera.onChange { job.lookThrough($0) })
            }
          }
        }
        .padding(6)
      }
    }
  }
}
