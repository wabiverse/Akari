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
import SwiftCrossUI

extension AkariDemo
{
  /// The rendered frame, over the viewport, with the job's progress.
  @MainActor
  struct RenderResult: View
  {
    @State private var job: RenderJob

    init(job: RenderJob)
    {
      _job = State(wrappedValue: job)
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        header
        Rectangle()
          .fill(Color(white: 0.09))
          .frame(height: 1)
        ZStack
        {
          Rectangle().fill(Color(white: 0.11))
          if let image = job.result
          {
            Image(image)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .padding(16)
          }
          else
          {
            Text(job.isRendering ? "Rendering..." : "No render yet, F12 renders the current frame.")
              .font(Properties.font)
              .foregroundColor(Properties.label)
          }
        }
      }
      .background(Properties.region)
    }

    private var header: some View
    {
      HStack(spacing: 10)
      {
        Text("Render Result")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(Properties.text)
        if let progress = job.progress
        {
          Text(Self.status(progress))
            .font(Properties.font)
            .foregroundColor(Properties.label)
          ProgressBar(fraction: Self.fraction(progress))
        }

        Spacer()
        if let message = job.message
        {
          Text(message)
            .font(.system(size: 10))
            .foregroundColor(Color(white: 0.6))
        }

        if job.isRendering
        {
          PropertiesButton("Cancel  Esc") { job.cancel() }
        }
        else
        {
          if job.progress?.job != .animation, job.result != nil
          {
            PropertiesButton("Save Image") { job.saveImage() }
          }

          PropertiesButton("Close  Esc") { job.closeResult() }
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(Properties.popup)
    }

    /// "Frame 120 (45/2843) | Sample 64/64 | Time 00:42.18 | Remaining 1:10:03.00"
    static func status(_ p: Akari.FinalRender.Progress) -> String
    {
      var parts = ["Frame \(p.frame)" + (p.frameCount > 1 ? " (\(p.frameNumber)/\(p.frameCount))" : "")]
      switch p.status
      {
        case .preparing: parts.append("Preparing")
        case .rendering: parts.append("Sample \(p.sample)/\(p.samples)")
        case .finished: parts.append("Finished")
        case .cancelled: parts.append("Cancelled")
        case .failed: parts.append("Failed")
      }

      parts.append("Time \(RenderJob.clock(p.elapsed))")
      if p.lastFrameTime > 0, p.frameCount > 1 { parts.append("Last \(RenderJob.clock(p.lastFrameTime))") }
      if let remaining = p.remaining, p.status == .rendering { parts.append("Remaining \(RenderJob.clock(remaining))") }
      return parts.joined(separator: "  |  ")
    }

    static func fraction(_ p: Akari.FinalRender.Progress) -> Double
    {
      guard p.frameCount > 0 else { return 0 }
      if p.status == .finished { return 1 }
      let frame = Double(max(p.frameNumber - 1, 0)) + Double(p.sample) / Double(max(p.samples, 1))
      return min(frame / Double(p.frameCount), 1)
    }
  }

  @MainActor
  struct ProgressBar: View
  {
    let fraction: Double

    private static let width = 140.0

    var body: some View
    {
      HStack(spacing: 0)
      {
        Rectangle()
          .fill(Properties.accent)
          .frame(width: Self.width * fraction, height: 4)
        Rectangle()
          .fill(Properties.field)
          .frame(width: Self.width * (1 - fraction), height: 4)
      }
    }
  }

  /// A push button styled like the properties editor's fields.
  @MainActor
  struct PropertiesButton: View
  {
    let title: String
    let action: () -> Void

    @State private var hovered = false

    init(_ title: String, action: @escaping () -> Void)
    {
      self.title = title
      self.action = action
    }

    var body: some View
    {
      Text(title)
        .font(Properties.font)
        .foregroundColor(Properties.text)
        .padding(.horizontal, 10)
        .frame(height: Double(Properties.rowHeight))
        .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Properties.fieldHover : Properties.field))
        .onHover { hovered = $0 }
        .onTapGesture { action() }
    }
  }
}
