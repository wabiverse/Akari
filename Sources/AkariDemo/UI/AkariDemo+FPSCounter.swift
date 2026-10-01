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
#if os(macOS)
  import AppKit
  import AppKitBackend

  private typealias PlatformFont = NSFont
  private typealias PlatformColor = NSColor
#else
  import UIKit
  import UIKitBackend

  private typealias PlatformFont = UIFont
  private typealias PlatformColor = UIColor
#endif

extension AkariDemo
{
  #if os(macOS)
    typealias PlatformView = NSView
  #else
    typealias PlatformView = UIView
  #endif

  /// The fps readout, drawn by its own native view at a fixed size,
  /// so a new value only redraws it and never relays out the HUD.
  struct FPSCounter
  {
    let driver: any Akari.HydraFrameDriver
  }

  final class FPSView: PlatformView
  {
    private static let attributes: [NSAttributedString.Key: Any] = [
      .font: PlatformFont.monospacedSystemFont(ofSize: 30, weight: .bold),
      .foregroundColor: PlatformColor.white,
    ]
    static let size = ("000 fps" as NSString).size(withAttributes: attributes)

    private let driver: any Akari.HydraFrameDriver
    private var timer: Timer?
    private var shown = 0

    init(driver: any Akari.HydraFrameDriver)
    {
      self.driver = driver
      super.init(frame: CGRect(origin: .zero, size: Self.size))

      #if !os(macOS)
        isOpaque = false
        backgroundColor = .clear
      #endif

      let timer = Timer(timeInterval: 0.25, target: self,
                        selector: #selector(refresh),
                        userInfo: nil, repeats: true)

      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder)
    {
      fatalError("init(coder:) is not supported")
    }

    #if os(macOS)
      override var isFlipped: Bool
      {
        true
      }
    #endif

    func stop()
    {
      timer?.invalidate()
      timer = nil
    }

    @objc private func refresh()
    {
      let fps = Int(driver.snapshot().framesPerSecond.rounded())
      guard fps != shown else { return }
      shown = fps
      #if os(macOS)
        needsDisplay = true
      #else
        setNeedsDisplay()
      #endif
    }

    override func draw(_: CGRect)
    {
      ("\(shown) fps" as NSString).draw(at: .zero, withAttributes: Self.attributes)
    }
  }
}

#if os(macOS)
  extension AkariDemo.FPSCounter: NSViewRepresentable
  {
    func makeNSView(context _: Context) -> AkariDemo.FPSView
    {
      AkariDemo.FPSView(driver: driver)
    }

    func updateNSView(_: AkariDemo.FPSView, context _: Context)
    {}

    func sizeThatFits(_: ProposedViewSize, nsView _: AkariDemo.FPSView, context _: Context) -> ViewSize
    {
      ViewSize(AkariDemo.FPSView.size.width, AkariDemo.FPSView.size.height)
    }

    static func dismantleNSView(_ nsView: AkariDemo.FPSView, coordinator _: Void)
    {
      MainActor.assumeIsolated { nsView.stop() }
    }
  }
#else
  extension AkariDemo.FPSCounter: UIViewRepresentable
  {
    func makeUIView(context _: Context) -> AkariDemo.FPSView
    {
      AkariDemo.FPSView(driver: driver)
    }

    func updateUIView(_: AkariDemo.FPSView, context _: Context)
    {}

    func sizeThatFits(_: ProposedViewSize, uiView _: AkariDemo.FPSView, context _: Context) -> ViewSize
    {
      ViewSize(AkariDemo.FPSView.size.width, AkariDemo.FPSView.size.height)
    }

    static func dismantleUIView(_ uiView: AkariDemo.FPSView, coordinator _: Void)
    {
      MainActor.assumeIsolated { uiView.stop() }
    }
  }
#endif
