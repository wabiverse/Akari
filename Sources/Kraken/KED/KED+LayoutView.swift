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
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
  import MetalKit
  import UniformTypeIdentifiers
#endif

extension Kraken
{
  /// The viewport's last frame camera, for drawing over it and casting rays into it.
  struct ViewCamera
  {
    let view: simd_double4x4
    let projection: simd_double4x4
    let size: CGSize
    let viewProjection: simd_double4x4
    let inverse: simd_double4x4
    let eye: SIMD3<Double>
    let forward: SIMD3<Double>
    let perspective: Bool

    init?(_ engine: Akari.RenderEngine, size: CGSize)
    {
      guard let camera = engine.viewportCamera, size.width > 1, size.height > 1 else { return nil }
      func wide(_ m: simd_float4x4) -> simd_double4x4
      {
        simd_double4x4(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1),
                                 SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3)))
      }

      view = wide(camera.view)
      projection = wide(camera.projection)
      self.size = size
      viewProjection = projection * view
      inverse = viewProjection.inverse
      let world = view.inverse
      eye = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
      forward = -simd_normalize(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
      perspective = abs(projection.columns.3.w) < 1e-6
    }

    func project(_ p: SIMD3<Double>) -> CGPoint?
    {
      let c = viewProjection * SIMD4(p, 1)
      guard c.w > 1e-9 else { return nil }
      return CGPoint(x: (c.x / c.w * 0.5 + 0.5) * size.width, y: (0.5 - c.y / c.w * 0.5) * size.height)
    }

    func ray(_ point: CGPoint) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)
    {
      let x = Double(point.x / size.width) * 2 - 1, y = 1 - Double(point.y / size.height) * 2
      func unproject(_ z: Double) -> SIMD3<Double>
      {
        let h = inverse * SIMD4(x, y, z, 1)
        return SIMD3(h.x, h.y, h.z) / h.w
      }

      let a = unproject(0.25), b = unproject(0.75)
      var direction = simd_normalize(b - a)
      if simd_dot(direction, forward) < 0 { direction = -direction }
      return (perspective ? eye : a - direction * 1e6, direction)
    }

    /// World units a pixel spans at `p`.
    func pixelSize(at p: SIMD3<Double>) -> Double
    {
      let depth = perspective ? max(simd_dot(p - eye, forward), 1e-6) : 1
      return 2 * depth / (abs(projection.columns.1.y) * Double(size.height))
    }

    func facing(_ p: SIMD3<Double>, _ normal: SIMD3<Double>) -> Bool
    {
      simd_dot(normal, perspective ? eye - p : -forward) > 0
    }
  }
}

#if os(macOS)
  extension Kraken
  {
    /// Draws the viewport overlays and runs the tools, modal transforms and hotkeys over the Hydra viewport.
    final class LayoutView: NSView
    {
      enum Handle: Equatable
      {
        case move(Int), plane(Int), free, rotate(Int), view, scale(Int), uniform
      }

      struct Modal
      {
        enum Kind
        {
          case translate, rotate, scale, inset
        }

        var kind: Kind
        var axis: Int?
        var plane = false
        var local = false
        var along: SIMD3<Double>?
        var start: CGPoint
        var pivot: SIMD3<Double>
        var numeric = ""
        var originals: [String: Layout.Placement] = [:]
        var mesh: EditMesh?
        var confirmOnRelease = false
      }

      var layout: Layout

      var isPicking: @MainActor () -> Bool = { false }
      /// Whether a top bar menu, drawn over the viewport, is open and takes the clicks.
      var isMenuOpen: @MainActor () -> Bool = { false }
      var toggleCamera: @MainActor () -> Void = {}

      private var monitor: Any?
      private var timer: Timer?
      weak var metal: NSView?
      var mouse = CGPoint.zero
      var press: (point: CGPoint, extend: Bool)?
      var box: CGRect?
      var boxArmed = false
      var orbiting = false
      var modal: Modal?
      var hover: Handle?
      var loopCutArmed = false
      var loopPress: CGPoint?
      var loopOrbiting = false
      var loopCut: (edge: Edge, ring: [Edge])?
      var widgetHits: [(path: String, points: [CGPoint])] = []
      var shownStatus = ""
      var statusSince = Date.distantPast
      var lightDrag: (handle: LightHandle, widget: Layout.Widget, placement: Layout.Placement, from: SIMD3<Double>)?
      var lightHover: LightHandle?

      static let red = NSColor(red: 1, green: 0.2, blue: 0.32, alpha: 1)
      static let green = NSColor(red: 0.54, green: 0.86, blue: 0, alpha: 1)
      static let blue = NSColor(red: 0.17, green: 0.56, blue: 1, alpha: 1)
      static let selected = NSColor(red: 0.95, green: 0.45, blue: 0.1, alpha: 1)
      static let activeColor = NSColor(red: 1, green: 0.67, blue: 0.25, alpha: 1)
      static let wire = NSColor(white: 0, alpha: 0.85)
      static let accent = NSColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      static let axisColors = [red, green, blue]

      init(layout: Layout)
      {
        self.layout = layout
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      override var isFlipped: Bool
      {
        true
      }

      override var isOpaque: Bool
      {
        false
      }

      override func hitTest(_: NSPoint) -> NSView?
      {
        nil
      }

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        guard window != nil, monitor == nil else { return }
        window?.acceptsMouseMovedEvents = true
        layout.viewport = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                              .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                                              .otherMouseDragged, .otherMouseUp, .mouseMoved,
                                                              .scrollWheel, .flagsChanged])
        { [weak self] event in
          let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
          return consumed ? nil : event
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.redrawIfChanged() }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
      }

      private var drawnState = 0
      private var madeOpaque = false

      /// What the overlay shows, so it repaints only when that changes, not every frame over the viewport.
      private var shownState: Int
      {
        var h = Hasher()
        if let c = layout.engine.viewportCamera
        {
          withUnsafeBytes(of: c.view) { h.combine(bytes: $0) }
          withUnsafeBytes(of: c.projection) { h.combine(bytes: $0) }
        }

        h.combine(bounds.width)
        h.combine(bounds.height)
        h.combine(mouse.x)
        h.combine(mouse.y)
        h.combine(layout.selection)
        h.combine(layout.mode == .edit)
        h.combine(layout.tool)
        h.combine(layout.overlays)
        h.combine(layout.xray)
        h.combine(layout.status)
        h.combine(layout.cursor.x)
        h.combine(layout.cursor.y)
        h.combine(layout.cursor.z)
        h.combine(layout.widgets.count)
        for widget in layout.widgets.prefix(64) { withUnsafeBytes(of: widget.world) { h.combine(bytes: $0) } }
        if let mesh = layout.mesh
        {
          h.combine(mesh.points.count)
          h.combine(mesh.faces.count)
          h.combine(mesh.verts)
          h.combine(mesh.edges)
          h.combine(mesh.selectedFaces)
          h.combine(mesh.mode)
        }

        for path in layout.selection { layout.placements[path].map { withUnsafeBytes(of: $0.local) { h.combine(bytes: $0) } } }
        h.combine(modal != nil)
        h.combine(box?.width)
        h.combine(box?.height)
        h.combine(loopCutArmed)
        h.combine(loopCut?.edge)
        return h.finalize()
      }

      private func redrawIfChanged()
      {
        // the viewport's Metal layer comes non-opaque, which has the window server blend it every frame.
        if !madeOpaque, let metal = metal ?? window?.contentView.flatMap({ Self.find($0) { $0 is MTKView } })
        {
          self.metal = metal
          metal.layer?.isOpaque = true
          madeOpaque = true
        }

        let state = shownState
        guard state != drawnState || Date().timeIntervalSince(statusSince) < 3.2 else { return }
        drawnState = state
        needsDisplay = true
      }

      func stop()
      {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
      }

      var camera: ViewCamera?
      {
        ViewCamera(layout.engine, size: bounds.size)
      }

      // MARK: axes

      /// The X, Y and Z axes, Z up whichever way the stage is.
      func axis(_ i: Int) -> SIMD3<Double>
      {
        switch i
        {
          case 0: SIMD3(1, 0, 0)
          case 1: layout.isZUp ? SIMD3(0, 1, 0) : SIMD3(0, 0, -1)
          default: layout.up
        }
      }

      func axisVector(_ modal: Modal) -> SIMD3<Double>?
      {
        if let along = modal.along { return along }
        guard let i = modal.axis else { return nil }
        let a = axis(i)
        guard modal.local else { return a }
        let world = layout.mode == .edit ? layout.meshWorld : layout.active.flatMap { layout.placements[$0]?.world }
        guard let world else { return a }
        let v = world * SIMD4(a, 0)
        let d = SIMD3(v.x, v.y, v.z)
        return simd_length(d) > 1e-12 ? simd_normalize(d) : a
      }
    }
  }
#endif
