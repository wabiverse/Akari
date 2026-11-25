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
import MetalKit
import simd
import SwiftCrossUI
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

extension Kraken
{
  /// the sculpt viewport's turntable camera, turning about the world up
  struct SculptCamera: Equatable
  {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 2.2
    var yaw: Float = 0.45
    var pitch: Float = 0.12
    var fov: Float = 0.6

    var offset: SIMD3<Float>
    {
      SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
    }

    var eye: SIMD3<Float>
    {
      target + offset
    }

    var forward: SIMD3<Float>
    {
      simd_normalize(-offset)
    }

    var view: simd_float4x4
    {
      let f = forward
      let s = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
      let u = simd_cross(s, f)
      let e = eye
      return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                     SIMD4(-simd_dot(s, e), -simd_dot(u, e), simd_dot(f, e), 1)))
    }

    func projection(aspect: Float) -> simd_float4x4
    {
      // far enough to take in the scene around the sculpt
      let near = max(distance * 0.01, 1e-4), far = distance * 2000 + 100
      let y = 1 / tan(fov * 0.5), x = y / max(aspect, 1e-4)
      let z = far / (near - far)
      return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// world size of a screen point one unit in front of the eye
    func pixelScale(height: Float) -> Float
    {
      2 * tan(fov * 0.5) / max(height, 1)
    }

    func ray(_ point: CGPoint, in size: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)
    {
      let aspect = Float(size.width / max(size.height, 1))
      let inverse = (projection(aspect: aspect) * view).inverse
      let x = Float(point.x / max(size.width, 1)) * 2 - 1, y = 1 - Float(point.y / max(size.height, 1)) * 2
      let near = inverse * SIMD4(x, y, 0, 1), far = inverse * SIMD4(x, y, 1, 1)
      let a = SIMD3(near.x, near.y, near.z) / near.w, b = SIMD3(far.x, far.y, far.z) / far.w
      return (eye, simd_normalize(b - a))
    }

    mutating func orbit(dx: Float, dy: Float)
    {
      yaw -= dx * 0.008
      pitch = min(max(pitch + dy * 0.008, -1.55), 1.55)
    }

    mutating func pan(dx: Float, dy: Float, height: Float)
    {
      let scale = pixelScale(height: height) * distance
      let s = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
      let u = simd_cross(s, forward)
      target += (-s * dx + u * dy) * scale
    }

    mutating func zoom(_ factor: Float)
    {
      distance = min(max(distance * factor, 0.05), 200)
    }

    /// fits a box in view
    mutating func frame(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>)
    {
      target = (lo + hi) * 0.5
      distance = max(simd_length(hi - lo) * 0.5 / tan(fov * 0.5) * 1.1, 0.1)
    }
  }

  /// the sculpt viewport, a metal view that draws the sculpt and turns pointers into strokes and camera moves
  final class SculptView: MTKView, MTKViewDelegate
  {
    var sculpt: Sculpt
    var camera = SculptCamera()
    {
      didSet { sculpt.viewCamera = camera }
    }

    private var renderer: SculptRenderer?
    private var drawn = 0
    private var painted = 0
    private var navigating: Navigation?
    private var last = CGPoint.zero
    private var hasCursor = false
    private var framed = 0

    enum Navigation
    {
      case orbit, pan, zoom
    }

    init(sculpt: Sculpt)
    {
      self.sculpt = sculpt
      let device = MTLCreateSystemDefaultDevice()
      super.init(frame: .zero, device: device)
      colorPixelFormat = .bgra8Unorm
      framebufferOnly = true
      preferredFramesPerSecond = 120
      delegate = self
      if let device { renderer = SculptRenderer(device: device, pixelFormat: colorPixelFormat) }
      if renderer == nil { sculpt.status = "Couldn't start the sculpt renderer" }

      #if os(macOS)
        layer?.isOpaque = true
      #else
        isMultipleTouchEnabled = true
        addInteraction(pencilInteraction)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
      #endif

      if let kept = sculpt.viewCamera { camera = kept }
      else if let box = worldBounds { camera.frame(box.lo, box.hi) }
      framed = sculpt.frameRequest
      sculpt.viewport = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder)
    {
      fatalError("init(coder:) is not supported")
    }

    // MARK: drawing

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in _: MTKView)
    {
      // the tab moved on while this view stayed in place, so the scene's viewport takes over again
      guard sculpt.layout?.tab == .sculpting else
      {
        if scene?.isPaused == true { pauseScene(false) }
        return
      }

      if scene == nil || scene?.isPaused == false { pauseScene(true) }
      sculpt.step()
      guard let renderer else { return }

      // a view asked for wins over framing everything, however the two arrive
      if var requested = sculpt.requestedCamera
      {
        // widens the view until a pixel covers as much as it did in the taller layout viewport, comparing heights in points
        if let height = sculpt.requestedHeight, height > 1, bounds.height > 1
        {
          let seen = height / Self.pixelScale(of: scene)
          requested.fov = 2 * atan(tan(requested.fov * 0.5) * Float(bounds.height) / seen)
        }

        camera = requested
        sculpt.requestedCamera = nil
        sculpt.requestedHeight = nil
        framed = sculpt.frameRequest
      }
      else if framed != sculpt.frameRequest
      {
        framed = sculpt.frameRequest
        frameAll()
      }

      let size = drawableSize
      let scale = Float(size.height / max(bounds.height, 1))
      var u = renderer.uniforms(sculpt, camera: camera, width: Int(size.width), height: Int(size.height), scale: scale)

      // the brush ring rides on top of the finished picture, so moving it alone only redraws the last pass
      var ring = Hasher()
      ring.combine(hasCursor)
      withUnsafeBytes(of: u.cursor) { ring.combine(bytes: $0) }
      withUnsafeBytes(of: u.cursorNormal) { ring.combine(bytes: $0) }
      u.cursor = .zero
      u.cursorNormal = .zero
      var h = Hasher()
      h.combine(sculpt.revision)
      h.combine(sculpt.pencilRevision)
      h.combine(sculpt.sceneRevision)
      withUnsafeBytes(of: &u) { h.combine(bytes: $0) }
      let scene = h.finalize()
      let state = scene &+ ring.finalize()

      // a frame still on the gpu is left to finish instead of waited on, so the window keeps taking clicks
      guard state != drawn || sculpt.isStroking, !renderer.isBusy, let drawable = currentDrawable else { return }
      drawn = state
      let repaint = scene != painted
      painted = scene
      renderer.draw(sculpt, camera: camera, drawable: drawable, scale: scale, showsCursor: hasCursor, repaint: repaint)
    }

    /// the scene's viewport under this one, paused while sculpting so the gpu is all the sculpt's
    private weak var scene: MTKView?

    /// pixels a point in a view's drawable, read from the view itself since each picks its own
    private static func pixelScale(of view: MTKView?) -> Float
    {
      guard let view, view.bounds.height > 1, view.drawableSize.height > 1 else
      {
        #if os(macOS)
          return Float(view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        #else
          return Float(view?.window?.screen.scale ?? UIScreen.main.scale)
        #endif
      }

      return Float(view.drawableSize.height / view.bounds.height)
    }

    /// lets the scene's viewport draw again, for leaving the sculpting tab
    func resumeScene()
    {
      pauseScene(false)
    }

    private func pauseScene(_ paused: Bool)
    {
      if paused, scene == nil, let root = window.flatMap({ Self.root(of: $0) })
      {
        scene = Self.find(root) { $0 is MTKView && !($0 is SculptView) } as? MTKView
      }

      scene?.isPaused = paused
    }

    private static func find(_ view: PlatformView, _ match: (PlatformView) -> Bool) -> PlatformView?
    {
      if match(view) { return view }
      for child in view.subviews
      {
        if let found = find(child, match) { return found }
      }

      return nil
    }

    #if os(macOS)
      private static func root(of window: NSWindow) -> NSView?
      {
        window.contentView
      }
    #else
      private static func root(of window: UIWindow) -> UIView?
      {
        window
      }
    #endif

    func dismantle()
    {
      pauseScene(false)
      isPaused = true
      sculpt.viewport = nil
    }

    /// the sculpt's bounds where it sits in the scene
    private var worldBounds: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    {
      guard let box = sculpt.volume.bounds else { return nil }

      var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
      for corner in 0 ..< 8
      {
        let p = SIMD3(corner & 1 == 0 ? box.lo.x : box.hi.x, corner & 2 == 0 ? box.lo.y : box.hi.y, corner & 4 == 0 ? box.lo.z : box.hi.z)
        let placed = sculpt.frame * SIMD4(p, 1)
        lo = simd_min(lo, SIMD3(placed.x, placed.y, placed.z))
        hi = simd_max(hi, SIMD3(placed.x, placed.y, placed.z))
      }

      return (lo, hi)
    }

    /// frames the whole sculpt
    func frameAll()
    {
      sculpt.settle()
      guard let box = worldBounds else { return }
      camera.frame(box.lo, box.hi)
    }

    /// a pointer in the sculpt's own space, the camera looks at the scene and the brushes work on the sculpt
    private func pointer(_ point: CGPoint, pressure: Float = 1, invert: Bool = false, smooth: Bool = false) -> SculptPointer
    {
      let ray = camera.ray(point, in: bounds.size)
      let back = sculpt.frame.inverse
      func place(_ p: SIMD3<Float>) -> SIMD3<Float>
      {
        let q = back * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
      }

      func turn(_ d: SIMD3<Float>) -> SIMD3<Float>
      {
        let q = back * SIMD4(d, 0)
        return simd_normalize(SIMD3(q.x, q.y, q.z))
      }

      return SculptPointer(origin: place(ray.origin), direction: turn(ray.direction), eye: place(camera.eye), forward: turn(camera.forward),
                           pixelScale: camera.pixelScale(height: Float(bounds.height)), perspective: true,
                           pressure: max(pressure, 0.05), invert: invert, smooth: smooth)
    }

    private func navigate(_ mode: Navigation, by delta: CGPoint)
    {
      switch mode
      {
        case .orbit: camera.orbit(dx: Float(delta.x), dy: Float(delta.y))
        case .pan: camera.pan(dx: Float(delta.x), dy: Float(delta.y), height: Float(bounds.height))
        case .zoom: camera.zoom(exp(Float(delta.y) * 0.01))
      }
    }

    /// the brushes, shapes and views as a menu at a point, what a right click or a long press opens
    private var brushEntries: [MenuEntry]
    {
      let sculpt = sculpt
      var entries = SculptBrush.groups.flatMap
      { group in
        group.map { brush in MenuEntry(title: brush.rawValue, checked: sculpt.brush == brush) { sculpt.brush = brush } }
          + [MenuEntry.separator]
      }

      entries.append(MenuEntry.submenu("Add Shape", SculptShape.allCases.map
      { shape in
        MenuEntry(title: shape.rawValue)
        {
          sculpt.shape = shape
          sculpt.insertShape()
        }
      }))
      entries.append(MenuEntry(title: "Frame All") { [weak self] in self?.frameAll() })
      return entries
    }

    #if os(macOS)
      // MARK: mouse and trackpad

      override var acceptsFirstResponder: Bool
      {
        true
      }

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        if window != nil { DispatchQueue.main.async { [weak self] in self?.pauseScene(true) } } else { pauseScene(false) }
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
      }

      private func location(_ event: NSEvent) -> CGPoint
      {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
      }

      /// a tablet pen's pressure, a mouse or trackpad presses fully
      private func pressure(_ event: NSEvent) -> Float
      {
        event.subtype == .tabletPoint ? Float(event.pressure) : 1
      }

      override func mouseDown(with event: NSEvent)
      {
        window?.makeFirstResponder(self)
        let p = location(event)
        last = p
        let flags = event.modifierFlags
        let invert = flags.contains(.option) || flags.contains(.control)

        if !flags.contains(.command), sculpt.begin(pointer(p, pressure: pressure(event), invert: invert, smooth: flags.contains(.shift)))
        {
          hasCursor = true
          return
        }

        navigating = flags.contains(.shift) || flags.contains(.option) ? .pan : flags.contains(.command) ? .zoom : .orbit
      }

      override func mouseDragged(with event: NSEvent)
      {
        let p = location(event)
        defer { last = p }

        if let navigating
        {
          navigate(navigating, by: CGPoint(x: p.x - last.x, y: p.y - last.y))
          return
        }

        let flags = event.modifierFlags
        sculpt.move(pointer(p, pressure: pressure(event), invert: flags.contains(.option) || flags.contains(.control),
                            smooth: flags.contains(.shift)))
      }

      override func mouseUp(with _: NSEvent)
      {
        if navigating == nil { sculpt.end() }
        navigating = nil
      }

      override func mouseMoved(with event: NSEvent)
      {
        hasCursor = true
        sculpt.hover(pointer(location(event)))
      }

      override func mouseExited(with _: NSEvent)
      {
        hasCursor = false
      }

      override func otherMouseDown(with event: NSEvent)
      {
        last = location(event)
        let flags = event.modifierFlags
        navigating = flags.contains(.shift) ? .pan : flags.contains(.control) ? .zoom : .orbit
      }

      override func otherMouseDragged(with event: NSEvent)
      {
        mouseDragged(with: event)
      }

      override func otherMouseUp(with _: NSEvent)
      {
        navigating = nil
      }

      override func rightMouseDown(with event: NSEvent)
      {
        Kraken.MenuEntry.menu(brushEntries).popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
      }

      override func scrollWheel(with event: NSEvent)
      {
        let flags = event.modifierFlags
        if event.hasPreciseScrollingDeltas
        {
          // two fingers on a trackpad turn the view, with shift they slide it and with command they zoom
          let delta = CGPoint(x: -event.scrollingDeltaX, y: -event.scrollingDeltaY)
          if flags.contains(.command) || flags.contains(.control) { camera.zoom(exp(Float(delta.y) * 0.01)) }
          else { navigate(flags.contains(.shift) ? .pan : .orbit, by: CGPoint(x: -delta.x, y: -delta.y)) }
        }
        else
        {
          camera.zoom(exp(Float(-event.scrollingDeltaY) * 0.08))
        }
      }

      override func magnify(with event: NSEvent)
      {
        camera.zoom(exp(Float(-event.magnification)))
      }

      override func smartMagnify(with _: NSEvent)
      {
        frameAll()
      }

      override func keyDown(with event: NSEvent)
      {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), let key = characters.first else
        {
          super.keyDown(with: event)
          return
        }

        let flags = event.modifierFlags
        if flags.contains(.command)
        {
          switch key
          {
            case "z": flags.contains(.shift) ? sculpt.redo() : sculpt.undo()
            default: super.keyDown(with: event)
          }

          return
        }

        // more or less surface, the remesh shortcut sculptors reach for
        if flags.contains(.control), key == "r"
        {
          flags.contains(.shift) ? sculpt.reduceDetail() : sculpt.addDetail()
          return
        }

        if handleKey(key, shift: flags.contains(.shift)) { return }
        super.keyDown(with: event)
      }
    #else
      // MARK: touch and pencil

      private var touches: [UITouch] = []
      private var strokeTouch: UITouch?
      private var strokeBegan = Date.distantPast
      private var tapStarted: (count: Int, time: Date, moved: Bool)?
      private var pinch: (center: CGPoint, distance: CGFloat)?
      private let pencilInteraction = UIPencilInteraction()

      override func didMoveToWindow()
      {
        super.didMoveToWindow()
        pencilInteraction.delegate = self
        if window != nil { DispatchQueue.main.async { [weak self] in self?.pauseScene(true) } } else { pauseScene(false) }
      }

      private func pressure(_ touch: UITouch) -> Float
      {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return Float(touch.force / touch.maximumPossibleForce)
      }

      private func twoFingers() -> (center: CGPoint, distance: CGFloat)?
      {
        guard touches.count >= 2 else { return nil }
        let a = touches[0].location(in: self), b = touches[1].location(in: self)
        return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), hypot(a.x - b.x, a.y - b.y))
      }

      override func touchesBegan(_ began: Set<UITouch>, with _: UIEvent?)
      {
        for touch in began
        {
          touches.append(touch)

          // a pencil always sculpts, and once one shows up fingers only steer
          if touch.type == .pencil
          {
            sculpt.fingersSculpt = false
            guard strokeTouch == nil else { continue }
            let p = touch.location(in: self)
            last = p
            if sculpt.begin(pointer(p, pressure: pressure(touch)))
            {
              strokeTouch = touch
              strokeBegan = Date()
              hasCursor = true
            }
            else
            {
              navigating = .orbit
            }

            continue
          }
        }

        let fingers = touches.filter { $0.type != .pencil }
        if tapStarted == nil || fingers.count > tapStarted!.count { tapStarted = (fingers.count, tapStarted?.time ?? Date(), false) }

        if fingers.count >= 2
        {
          // a second finger landing just after the first turns its stroke into a pinch
          if let stroke = strokeTouch, stroke.type != .pencil
          {
            if Date().timeIntervalSince(strokeBegan) < 0.3 { sculpt.cancel() } else { sculpt.end() }
            strokeTouch = nil
          }

          navigating = nil
          pinch = twoFingers()
          return
        }

        guard fingers.count == 1, strokeTouch == nil, let finger = fingers.first, began.contains(finger) else { return }
        let p = finger.location(in: self)
        last = p
        if sculpt.fingersSculpt, sculpt.begin(pointer(p))
        {
          strokeTouch = finger
          strokeBegan = Date()
          hasCursor = true
        }
        else
        {
          navigating = .orbit
        }
      }

      override func touchesMoved(_ moved: Set<UITouch>, with event: UIEvent?)
      {
        if let stroke = strokeTouch, moved.contains(stroke)
        {
          for touch in event?.coalescedTouches(for: stroke) ?? [stroke]
          {
            sculpt.move(pointer(touch.location(in: self), pressure: pressure(touch)))
          }
        }

        if var started = tapStarted, !started.moved
        {
          started.moved = moved.contains { hypot($0.location(in: self).x - $0.previousLocation(in: self).x,
                                                 $0.location(in: self).y - $0.previousLocation(in: self).y) > 6 }
          tapStarted = started
        }

        if let before = pinch, let now = twoFingers()
        {
          camera.pan(dx: Float(now.center.x - before.center.x), dy: Float(now.center.y - before.center.y), height: Float(bounds.height))
          if now.distance > 1, before.distance > 1 { camera.zoom(Float(before.distance / now.distance)) }
          pinch = now
          return
        }

        if let navigating, let touch = moved.first(where: { $0 !== strokeTouch })
        {
          let p = touch.location(in: self)
          navigate(navigating, by: CGPoint(x: p.x - last.x, y: p.y - last.y))
          last = p
        }
      }

      override func touchesEnded(_ ended: Set<UITouch>, with _: UIEvent?)
      {
        finish(ended, cancelled: false)
      }

      override func touchesCancelled(_ cancelled: Set<UITouch>, with _: UIEvent?)
      {
        finish(cancelled, cancelled: true)
      }

      private func finish(_ lifted: Set<UITouch>, cancelled: Bool)
      {
        if let stroke = strokeTouch, lifted.contains(stroke)
        {
          cancelled ? sculpt.cancel() : sculpt.end()
          strokeTouch = nil
          hasCursor = false
        }

        touches.removeAll { lifted.contains($0) }
        if touches.count < 2 { pinch = nil }

        // two fingers tapped undo and three redo
        if touches.isEmpty
        {
          if let tap = tapStarted, !tap.moved, Date().timeIntervalSince(tap.time) < 0.3
          {
            if tap.count == 2 { sculpt.undo() }
            if tap.count == 3 { sculpt.redo() }
          }

          tapStarted = nil
          navigating = nil
        }
        else if let finger = touches.first
        {
          last = finger.location(in: self)
          if strokeTouch == nil, pinch == nil { navigating = .orbit }
        }
      }

      @objc private func hovered(_ recognizer: UIHoverGestureRecognizer)
      {
        switch recognizer.state
        {
          case .began, .changed:
            hasCursor = true
            sculpt.hover(pointer(recognizer.location(in: self)))
          default:
            hasCursor = false
        }
      }
    #endif

    /// the meshes that can be added to sculpt, under the pointer. the new mesh is selected, so it is sculpted next
    func showAdd()
    {
      guard let entries = sculpt.layout?.viewport?.entries(.sculptAdd), !entries.isEmpty else { return }

      #if os(macOS)
        let p = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        MenuPanel.show(MenuEntry.menu(entries), at: p, in: self)
      #else
        MenuEntry.present(entries, from: self, at: CGPoint(x: bounds.midX, y: bounds.midY))
      #endif
    }

    /// the keys sculpting answers to, true when one was used
    func handleKey(_ key: Character, shift: Bool) -> Bool
    {
      if let brush = SculptBrush.allCases.first(where: { $0.key == key }), !shift
      {
        sculpt.brush = brush
        return true
      }

      switch key
      {
        case "[": shift ? (sculpt.strength = max(sculpt.strength - 0.05, 0)) : (sculpt.radius = max(sculpt.radius / 1.15, 2))
        case "]": shift ? (sculpt.strength = min(sculpt.strength + 0.05, 1)) : (sculpt.radius = min(sculpt.radius * 1.15, 600))
        case "{": sculpt.strength = max(sculpt.strength - 0.05, 0)
        case "}": sculpt.strength = min(sculpt.strength + 0.05, 1)
        case "x": sculpt.mirror[0].toggle()
        case "y": sculpt.mirror[1].toggle()
        case "z": sculpt.mirror[2].toggle()
        case "1": sculpt.shading = .clay
        case "2": sculpt.shading = .studio
        case "3": sculpt.shading = .painterly
        case "f", ".": frameAll()
        case "=", "+": camera.zoom(0.85)
        case "-", "_": camera.zoom(1 / 0.85)
        case "a": shift ? showAdd() : sculpt.insertShape()
        case "l": sculpt.lazy = sculpt.lazy > 0 ? 0 : 0.5
        default: return false
      }

      return true
    }
  }

  /// hosts the sculpt viewport in the workspace
  struct SculptCanvas: View
  {
    let sculpt: Sculpt

    var body: some View
    {
      NativeView(make: { [sculpt] in SculptView(sculpt: sculpt) },
                 update: { [sculpt] view in view.sculpt = sculpt },
                 size: { ViewSize($0.width ?? 800, $0.height ?? 600) })
    }
  }
}

extension Kraken.SculptView: Kraken.Dismantling {}

#if !os(macOS)
  extension Kraken.SculptView: UIPencilInteractionDelegate
  {
    /// a double tap on the pencil flips the brush between adding and taking away
    func pencilInteractionDidTap(_: UIPencilInteraction)
    {
      sculpt.invert.toggle()
    }
  }
#endif
