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
import HydraKit
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

#if os(macOS)
  extension Kraken
  {
    /// The dope sheet shows the selection's animated properties down the side
    /// and their keys along the frames, keyboard shortcuts apply while the cursor
    /// is over it.
    struct NativeDopeSheet: NSViewRepresentable
    {
      let layout: Layout
      let timeline: Timeline
      let start: () -> Int
      let end: () -> Int

      func makeNSView(context _: Context) -> DopeSheetView
      {
        DopeSheetView(layout: layout, timeline: timeline)
      }

      func updateNSView(_ view: DopeSheetView, context _: Context)
      {
        view.range = (start(), max(end(), start()))
      }

      func sizeThatFits(_ proposal: ProposedViewSize, nsView _: DopeSheetView, context _: Context) -> ViewSize
      {
        ViewSize(proposal.width ?? 600, proposal.height ?? Double(DopeSheetView.height))
      }
    }

    final class DopeSheetView: NSView
    {
      static let height: CGFloat = 220
      static let channelWidth: CGFloat = 210
      static let rulerHeight: CGFloat = 20
      static let rowHeight: CGFloat = 20

      private enum Row
      {
        case summary
        case prim(String)
        case channel(Int)
      }

      private struct Key: Hashable
      {
        var channel: String
        var time: Double
      }

      private enum Modal
      {
        /// Moving keys with G or by dragging them. `duplicate` is set for Shift-D.
        case grab(anchor: CGFloat, duplicate: Bool, drag: Bool)
        /// Scaling keys around the current frame with S.
        case scale(anchor: CGFloat)
        case box(from: NSPoint, to: NSPoint, extend: Bool)
        case scrub
        case pan(last: NSPoint)
      }

      private weak var layout: Layout?
      private weak var timeline: Timeline?
      var range = (1, 250)
      {
        didSet { if visible == nil { frameAll() } }
      }

      private var channels: [SceneEdit.Channel] = []
      private var rows: [Row] = []
      private var selected = Set<Key>()
      private var selectedChannels = Set<String>()
      /// The frames in view, or nil to show the scene's range.
      private var visible: (lo: Double, hi: Double)?
      private var frameRange: (lo: Double, hi: Double)
      {
        visible ?? (Double(range.0), Double(range.1))
      }
      private var scrollRows: CGFloat = 0
      private var modal: Modal?
      private var mouse = NSPoint.zero
      private var boxArmed = false
      private var clipboard: [(path: String, name: String, time: Double)] = []
      private var shown = (selection: [String](), revision: -1, frame: -1.0)
      private var loading = false
      private var monitor: Any?
      private let ticker = Ticker()
      private let playhead = PlayheadView()

      init(layout: Layout, timeline: Timeline)
      {
        self.layout = layout
        self.timeline = timeline
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(playhead)
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

      override func acceptsFirstMouse(for _: NSEvent?) -> Bool
      {
        true
      }

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        ticker.run(window != nil) { [weak self] in self?.poll() }
        if window != nil, monitor == nil
        {
          monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .mouseMoved])
          { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
          }
        }
        else if window == nil, let monitor
        {
          NSEvent.removeMonitor(monitor)
          self.monitor = nil
        }
      }

      // MARK: data

      private var time: Double
      {
        layout?.hydra.currentTimeCode ?? 0
      }

      /// Reloads the channels when the selection or keys change, and redraws when the frame moves.
      private func poll()
      {
        guard let layout else { return }
        let now = (layout.selection, layout.keyframes.revision, time)
        if now.0 != shown.selection || now.1 != shown.revision
        {
          shown = now
          reload()
        }
        else if now.2 != shown.frame
        {
          shown.frame = now.2
          placePlayhead()
        }
      }

      private func reload()
      {
        guard let layout, !loading else { return }
        loading = true
        let paths = layout.selection
        layout.onStage
        { [weak self] stage in
          let found = SceneEdit.channels(stage, paths)
          DispatchQueue.main.async
          { [weak self] in
            guard let self else { return }
            self.loading = false
            self.channels = found
            self.rebuildRows()
            if self.shown.selection != layout.selection { self.reload() }
          }
        }
      }

      private func rebuildRows()
      {
        var next: [Row] = [.summary]
        var lastPath: String?
        for (i, channel) in channels.enumerated()
        {
          if channel.path != lastPath
          {
            next.append(.prim(channel.path))
            lastPath = channel.path
          }

          next.append(.channel(i))
        }

        rows = next
        let ids = Set(channels.map(\.id))
        selected = selected.filter { ids.contains($0.channel) }
        selectedChannels = selectedChannels.filter { ids.contains($0) }
        needsDisplay = true
      }

      /// The keys shown on a row. Summary and prim rows show their channels' keys combined.
      private func keys(_ row: Row) -> [Key]
      {
        switch row
        {
          case .summary: return channels.flatMap { c in c.times.map { Key(channel: c.id, time: $0) } }
          case let .prim(path): return channels.filter { $0.path == path }.flatMap { c in c.times.map { Key(channel: c.id, time: $0) } }
          case let .channel(i): return channels[i].times.map { Key(channel: channels[i].id, time: $0) }
        }
      }

      private func channel(_ id: String) -> SceneEdit.Channel?
      {
        channels.first { $0.id == id }
      }

      // MARK: geometry

      private var pixelsPerFrame: CGFloat
      {
        let v = frameRange
        return (bounds.width - Self.channelWidth) / CGFloat(max(v.hi - v.lo, 1e-3))
      }

      private func x(_ frame: Double) -> CGFloat
      {
        let v = frameRange
        return Self.channelWidth + CGFloat(frame - v.lo) * pixelsPerFrame
      }

      private func frame(at px: CGFloat) -> Double
      {
        let v = frameRange
        return v.lo + Double((px - Self.channelWidth) / max(pixelsPerFrame, 1e-6))
      }

      private func y(_ row: Int) -> CGFloat
      {
        Self.rulerHeight + (CGFloat(row) - scrollRows) * Self.rowHeight
      }

      private func row(at p: NSPoint) -> Int?
      {
        guard p.y >= Self.rulerHeight else { return nil }
        let r = Int(floor((p.y - Self.rulerHeight) / Self.rowHeight + scrollRows))
        return r >= 0 && r < rows.count ? r : nil
      }

      /// The nearest key within reach of `p`.
      private func key(at p: NSPoint) -> (row: Int, time: Double)?
      {
        guard p.x > Self.channelWidth, let r = row(at: p) else { return nil }
        let times = Set(keys(rows[r]).map(\.time))
        let best = times.min { abs(x($0) - p.x) < abs(x($1) - p.x) }
        guard let best, abs(x(best) - p.x) <= 6 else { return nil }
        return (r, best)
      }

      private func frameAll()
      {
        let times = channels.flatMap(\.times)
        let lo = min(times.min() ?? Double(range.0), Double(range.0))
        let hi = max(times.max() ?? Double(range.1), Double(range.1))
        let pad = max((hi - lo) * 0.04, 2)
        visible = (lo - pad, hi + pad)
        needsDisplay = true
      }

      private var inside: Bool
      {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
      }

      // MARK: mouse

      override func mouseDown(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if commitModal() { return }
        let shift = event.modifierFlags.contains(.shift)
        if p.y < Self.rulerHeight, p.x > Self.channelWidth
        {
          modal = .scrub
          scrub(p)
          return
        }

        if p.x <= Self.channelWidth
        {
          clickChannel(at: p, extend: shift)
          return
        }

        if boxArmed
        {
          boxArmed = false
          modal = .box(from: p, to: p, extend: shift)
          return
        }

        if let hit = key(at: p)
        {
          let hits = keys(rows[hit.row]).filter { $0.time == hit.time }
          let wasSelected = hits.allSatisfy { selected.contains($0) }
          if shift
          {
            if wasSelected { selected.subtract(hits) } else { selected.formUnion(hits) }
          }
          else if !wasSelected
          {
            selected = Set(hits)
          }

          if !shift, selected.contains(where: { hits.contains($0) })
          {
            modal = .grab(anchor: p.x, duplicate: false, drag: true)
          }
        }
        else
        {
          modal = .box(from: p, to: p, extend: shift)
        }

        needsDisplay = true
      }

      override func mouseDragged(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        switch modal
        {
          case .scrub: scrub(p)
          case let .box(from, _, extend): modal = .box(from: from, to: p, extend: extend)
          default: break
        }

        needsDisplay = true
      }

      override func mouseUp(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        switch modal
        {
          case .scrub:
            modal = nil
          case let .box(from, to, extend):
            modal = nil
            selectBox(from, to, extend: extend)
          case let .grab(anchor, duplicate, drag) where drag:
            modal = nil
            let delta = frameDelta(anchor)
            if delta != 0 { retime(delta: delta, duplicate: duplicate) }
          default:
            break
        }

        needsDisplay = true
      }

      override func rightMouseDown(with _: NSEvent)
      {
        cancelModal()
      }

      override func otherMouseDown(with event: NSEvent)
      {
        modal = .pan(last: convert(event.locationInWindow, from: nil))
      }

      override func otherMouseDragged(with event: NSEvent)
      {
        guard case let .pan(last) = modal else { return }
        let p = convert(event.locationInWindow, from: nil)
        pan(frames: -Double((p.x - last.x) / max(pixelsPerFrame, 1e-6)))
        scrollRows = max(0, min(CGFloat(max(rows.count - 2, 0)), scrollRows - (p.y - last.y) / Self.rowHeight))
        modal = .pan(last: p)
        needsDisplay = true
      }

      override func otherMouseUp(with _: NSEvent)
      {
        if case .pan = modal { modal = nil }
      }

      private func scrub(_ p: NSPoint)
      {
        timeline?.seek(to: Int(frame(at: p.x).rounded()))
        needsDisplay = true
      }

      private func clickChannel(at p: NSPoint, extend: Bool)
      {
        guard let r = row(at: p) else { return }
        let ids: Set<String> = switch rows[r]
        {
          case .summary: Set(channels.map(\.id))
          case let .prim(path): Set(channels.filter { $0.path == path }.map(\.id))
          case let .channel(i): [channels[i].id]
        }

        let all = Set(keys(rows[r]))
        if extend
        {
          if ids.isSubset(of: selectedChannels) { selectedChannels.subtract(ids); selected.subtract(all) }
          else { selectedChannels.formUnion(ids); selected.formUnion(all) }
        }
        else
        {
          selectedChannels = ids
          selected = all
        }

        needsDisplay = true
      }

      private func selectBox(_ a: NSPoint, _ b: NSPoint, extend: Bool)
      {
        let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        var hits = Set<Key>()
        for (r, row) in rows.enumerated()
        {
          let rowRect = NSRect(x: Self.channelWidth, y: y(r), width: bounds.width, height: Self.rowHeight)
          guard rowRect.intersects(rect) else { continue }
          for key in keys(row) where rect.insetBy(dx: -4, dy: 0).contains(NSPoint(x: x(key.time), y: rowRect.midY)) || (rect.width < 2 && abs(x(key.time) - rect.midX) < 5)
          {
            hits.insert(key)
          }
        }

        if extend { selected.formUnion(hits) } else { selected = hits }
      }

      // MARK: keys

      private func handle(_ event: NSEvent) -> Bool
      {
        switch event.type
        {
          case .mouseMoved:
            guard inside || modal != nil else { return false }
            mouse = convert(event.locationInWindow, from: nil)
            if modal != nil { needsDisplay = true }
            return false
          case .scrollWheel:
            guard inside else { return false }
            scroll(event)
            return true
          case .keyDown:
            guard inside || modal != nil, !(window?.firstResponder is NSText) else { return false }
            return handleKey(event)
          default:
            return false
        }
      }

      private func scroll(_ event: NSEvent)
      {
        let flags = event.modifierFlags
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if flags.contains(.shift)
        {
          scrollRows = max(0, min(CGFloat(max(rows.count - 2, 0)), scrollRows - dy / (precise ? Self.rowHeight : 1)))
        }
        else if flags.contains(.control) || flags.contains(.command) || abs(dx) > abs(dy)
        {
          let amount = abs(dx) > abs(dy) ? dx : dy
          pan(frames: -Double(amount / (precise ? max(pixelsPerFrame, 1e-6) : 0.1 * max(pixelsPerFrame, 1e-6))))
        }
        else
        {
          zoom(by: pow(0.995, Double(precise ? dy : dy * 10)), about: frame(at: mouse.x))
        }

        needsDisplay = true
      }

      private func pan(frames: Double)
      {
        let v = frameRange
        visible = (v.lo + frames, v.hi + frames)
      }

      private func zoom(by factor: Double, about pivot: Double)
      {
        let v = frameRange
        let lo = pivot - (pivot - v.lo) * factor, hi = pivot + (v.hi - pivot) * factor
        guard hi - lo > 4, hi - lo < 1e6 else { return }
        visible = (lo, hi)
      }

      private func handleKey(_ event: NSEvent) -> Bool
      {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift), alt = flags.contains(.option)
        let ctrl = flags.contains(.control) || flags.contains(.command)
        let code = Int(event.keyCode)
        let char = (event.charactersIgnoringModifiers ?? "").lowercased()

        if modal != nil
        {
          switch code
          {
            case 53: cancelModal()
            case 36, 76: _ = commitModal()
            default: return true
          }
          return true
        }

        switch (code, char)
        {
          case (_, "a") where alt:
            selected.removeAll()
            selectedChannels.removeAll()
          case (_, "a"):
            selected = Set(rows.indices.flatMap { keys(rows[$0]) })
          case (_, "i") where ctrl:
            let all = Set(keys(.summary))
            selected = all.subtracting(selected)
          case (_, "i"):
            insertKeys()
          case (_, "b"):
            boxArmed = true
          case (_, "g"):
            guard !selected.isEmpty else { return true }
            modal = .grab(anchor: mouse.x, duplicate: false, drag: false)
          case (_, "s"):
            guard !selected.isEmpty else { return true }
            modal = .scale(anchor: mouse.x)
          case (_, "d") where shift:
            guard !selected.isEmpty else { return true }
            modal = .grab(anchor: mouse.x, duplicate: true, drag: false)
          case (_, "x"), (51, _), (117, _):
            deleteKeys()
          case (_, "c") where ctrl:
            clipboard = selected.compactMap { key in channel(key.channel).map { ($0.path, $0.name, key.time) } }
            layout?.status = clipboard.isEmpty ? "Nothing to copy" : "Copied \(clipboard.count) keyframes"
          case (_, "v") where ctrl:
            pasteKeys()
          case (115, _):
            frameAll()
          default:
            return false
        }

        needsDisplay = true
        return true
      }

      private func frameDelta(_ anchor: CGFloat) -> Double
      {
        Double(((mouse.x - anchor) / max(pixelsPerFrame, 1e-6)).rounded())
      }

      private func scaleFactor(_ anchor: CGFloat) -> Double
      {
        let pivot = x(time)
        guard abs(anchor - pivot) > 1 else { return 1 }
        return Double((mouse.x - pivot) / (anchor - pivot))
      }

      /// Confirms a running move or scale. Returns false if none was running.
      private func commitModal() -> Bool
      {
        switch modal
        {
          case let .grab(anchor, duplicate, _):
            modal = nil
            let delta = frameDelta(anchor)
            if delta != 0 || duplicate { retime(delta: delta, duplicate: duplicate) }
            return true
          case let .scale(anchor):
            modal = nil
            let factor = scaleFactor(anchor)
            if abs(factor - 1) > 1e-6 { retime(delta: 0, scale: factor, pivot: time) }
            return true
          default:
            return false
        }
      }

      private func cancelModal()
      {
        boxArmed = false
        modal = nil
        needsDisplay = true
      }

      /// The selected keys, grouped by channel.
      private var selectedByChannel: [(path: String, name: String, times: [Double])]
      {
        Dictionary(grouping: selected, by: \.channel).compactMap
        { id, keys in
          channel(id).map { ($0.path, $0.name, keys.map(\.time).sorted()) }
        }
      }

      private func retime(delta: Double, scale: Double = 1, pivot: Double = 0, duplicate: Bool = false)
      {
        let groups = selectedByChannel
        guard !groups.isEmpty else { return }
        // Keep the moved keys selected.
        selected = Set(selected.map { Key(channel: $0.channel, time: (pivot + ($0.time - pivot) * scale + delta).rounded()) })
        layout?.keyframes.edit(duplicate ? "Duplicated Keyframes" : "Moved Keyframes")
        { stage, _ in
          groups.reduce(false)
          {
            SceneEdit.retimeKeys(stage, $1.path, $1.name, $1.times, delta: delta, scale: scale, pivot: pivot,
                                 duplicate: duplicate) || $0
          }
        }
      }

      private func deleteKeys()
      {
        let groups = selectedByChannel
        guard !groups.isEmpty else { return }
        selected.removeAll()
        layout?.keyframes.edit("Deleted Keyframes")
        { stage, _ in
          groups.reduce(false) { done, group in
            group.times.reduce(done) { SceneEdit.deleteKey(stage, group.path, group.name, $1) || $0 }
          }
        }
      }

      /// Keys the selected channels on the current frame (I), or every visible channel if none are selected.
      private func insertKeys()
      {
        let chosen = channels.filter { selectedChannels.isEmpty || selectedChannels.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let targets = chosen.map { ($0.path, $0.name) }
        layout?.keyframes.edit("Inserted Keyframes")
        { stage, time in
          var keyedTransforms = Set<String>()
          return targets.reduce(false)
          { done, target in
            // A prim with an unkeyed move gets its whole transform keyed where it was moved to.
            if target.1.hasPrefix("xformOp:"), SceneEdit.holdsTransform(target.0)
            {
              guard keyedTransforms.insert(target.0).inserted else { return done }
              return SceneEdit.keyTransform(stage, target.0, time) || done
            }

            return SceneEdit.insertKey(stage, target.0, target.1, time) || done
          }
        }
      }

      /// Pastes copied keys so the first one lands on the current frame (Ctrl-V).
      private func pasteKeys()
      {
        guard let first = clipboard.map(\.time).min() else { return }
        let offset = time - first
        let copied = clipboard
        layout?.keyframes.edit("Pasted Keyframes")
        { stage, _ in
          copied.reduce(false)
          { done, key in
            guard let value = SceneEdit.keyValue(stage, key.path, key.name, key.time) else { return done }
            return SceneEdit.setKey(stage, key.path, key.name, key.time + offset, value) || done
          }
        }
      }

      // MARK: drawing

      private static let background = NSColor(white: 0.157, alpha: 1)
      private static let channelBackground = NSColor(white: 0.19, alpha: 1)
      private static let primRow = NSColor(white: 0.23, alpha: 1)
      private static let summaryRow = NSColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 1)
      private static let stripe = NSColor(white: 1, alpha: 0.025)
      private static let selectedRow = NSColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 0.35)
      private static let grid = NSColor(white: 0.22, alpha: 1)
      private static let outside = NSColor(white: 0, alpha: 0.18)
      fileprivate static let accent = NSColor(srgbRed: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      private static let keyFill = NSColor(white: 0.85, alpha: 1)
      private static let keySelected = NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 1)
      private static let keyOutline = NSColor(white: 0.05, alpha: 1)
      private static let hold = NSColor(white: 0.5, alpha: 0.35)
      private static let label: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor(white: 0.78, alpha: 1),
      ]
      private static let bold: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor(white: 0.9, alpha: 1),
      ]
      private static let numbers: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor(white: 0.7, alpha: 1),
      ]
      fileprivate static let playhead: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white,
      ]

      /// Where a key is drawn while it's being moved or scaled.
      private func shownTime(_ key: Key) -> Double
      {
        guard selected.contains(key) else { return key.time }
        switch modal
        {
          case let .grab(anchor, duplicate, _) where !duplicate: return key.time + frameDelta(anchor)
          case let .scale(anchor): return (time + (key.time - time) * scaleFactor(anchor)).rounded()
          default: return key.time
        }
      }

      private func diamond(at p: NSPoint, size: CGFloat, fill: NSColor)
      {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.x, y: p.y - size))
        path.line(to: NSPoint(x: p.x + size, y: p.y))
        path.line(to: NSPoint(x: p.x, y: p.y + size))
        path.line(to: NSPoint(x: p.x - size, y: p.y))
        path.close()
        fill.setFill()
        path.fill()
        Self.keyOutline.setStroke()
        path.lineWidth = 1
        path.stroke()
      }

      private func title(of row: Row) -> (text: String, isBold: Bool)
      {
        switch row
        {
          case .summary: ("Summary", true)
          case let .prim(path): (path.split(separator: "/").last.map(String.init) ?? path, true)
          case let .channel(i): ("    " + Self.label(channels[i].name), false)
        }
      }

      /// An attribute name without its inputs or xformOp prefix.
      private static func label(_ name: String) -> String
      {
        for prefix in ["inputs:", "xformOp:"] where name.hasPrefix(prefix)
        {
          return String(name.dropFirst(prefix.count))
        }
        return name
      }

      override func draw(_: NSRect)
      {
        Self.background.setFill()
        bounds.fill()
        let width = bounds.width

        // Dim frames outside the scene's range.
        Self.outside.setFill()
        NSRect(x: Self.channelWidth, y: Self.rulerHeight, width: max(x(Double(range.0)) - Self.channelWidth, 0),
               height: bounds.height).fill()
        let endX = x(Double(range.1) + 1)
        if endX < width { NSRect(x: endX, y: Self.rulerHeight, width: width - endX, height: bounds.height).fill() }

        // Frame lines and numbers.
        let steps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000]
        let step = steps.first { CGFloat($0) * pixelsPerFrame >= 50 } ?? 10000
        var f = (Int(frame(at: Self.channelWidth).rounded(.up)) / step) * step
        while x(Double(f)) <= width
        {
          let px = x(Double(f)).rounded() + 0.5
          if px >= Self.channelWidth
          {
            Self.grid.setFill()
            NSRect(x: px - 0.5, y: Self.rulerHeight, width: 1, height: bounds.height).fill()
            let text = "\(f)" as NSString
            let size = text.size(withAttributes: Self.numbers)
            text.draw(at: NSPoint(x: px - size.width / 2, y: (Self.rulerHeight - size.height) / 2), withAttributes: Self.numbers)
          }
          f += step
        }

        // Row backgrounds and channel names.
        for (r, row) in rows.enumerated()
        {
          let top = y(r)
          guard top + Self.rowHeight >= Self.rulerHeight, top <= bounds.height else { continue }
          let band = NSRect(x: 0, y: top, width: width, height: Self.rowHeight)
          switch row
          {
            case .summary: Self.summaryRow.setFill(); band.fill()
            case .prim: Self.primRow.setFill(); band.fill()
            case .channel: if r % 2 == 0 { Self.stripe.setFill(); band.fill() }
          }

          if case let .channel(i) = row, selectedChannels.contains(channels[i].id)
          {
            Self.selectedRow.setFill()
            NSRect(x: 0, y: top, width: Self.channelWidth, height: Self.rowHeight).fill()
          }

          // Join keys that hold the same value as the next key.
          let rowKeys = keys(row)
          let times = Set(rowKeys.map { shownTime($0) }).sorted()
          if case .channel = row, times.count > 1
          {
            Self.hold.setFill()
            for (a, b) in zip(times, times.dropFirst()) where b - a <= 1.0001
            {
              NSRect(x: x(a), y: top + Self.rowHeight / 2 - 2, width: x(b) - x(a), height: 4).fill()
            }
          }

          var drawn = [Double: Bool]()
          for key in rowKeys
          {
            let t = shownTime(key)
            drawn[t] = (drawn[t] ?? false) || selected.contains(key)
          }

          var size: CGFloat = 5.5
          if case .channel = row { size = 5 }
          // Draw in time order. Dictionary order changes between draws, which makes overlapping keys flicker.
          for t in drawn.keys.sorted()
          {
            let isSelected = drawn[t] ?? false
            let px = x(t)
            guard px >= Self.channelWidth - 6, px <= width + 6 else { continue }
            diamond(at: NSPoint(x: px, y: top + Self.rowHeight / 2), size: size,
                    fill: isSelected ? Self.keySelected : Self.keyFill)
          }
        }

        // The channel list, drawn over the scrolled key area.
        Self.channelBackground.setFill()
        NSRect(x: 0, y: 0, width: Self.channelWidth, height: bounds.height).fill()
        for (r, row) in rows.enumerated()
        {
          let top = y(r)
          guard top + Self.rowHeight >= Self.rulerHeight, top <= bounds.height else { continue }
          switch row
          {
            case .summary: Self.summaryRow.setFill(); NSRect(x: 0, y: top, width: Self.channelWidth, height: Self.rowHeight).fill()
            case .prim: Self.primRow.setFill(); NSRect(x: 0, y: top, width: Self.channelWidth, height: Self.rowHeight).fill()
            case let .channel(i):
              if selectedChannels.contains(channels[i].id)
              {
                Self.selectedRow.setFill()
                NSRect(x: 0, y: top, width: Self.channelWidth, height: Self.rowHeight).fill()
              }
          }

          let (text, isBold) = title(of: row)
          let attributes = isBold ? Self.bold : Self.label
          let s = text as NSString
          let size = s.size(withAttributes: attributes)
          s.draw(in: NSRect(x: 8, y: top + (Self.rowHeight - size.height) / 2, width: Self.channelWidth - 12, height: size.height),
                 withAttributes: attributes)
        }

        if rows.count <= 1
        {
          let hint = (layout?.selection.isEmpty ?? true ? "Select objects to see their keyframes"
            : "No keyframes — hover a property and press I") as NSString
          let size = hint.size(withAttributes: Self.label)
          hint.draw(at: NSPoint(x: Self.channelWidth + 12, y: Self.rulerHeight + Self.rowHeight + 8 - size.height / 2),
                    withAttributes: Self.label)
        }

        // The ruler's corner. The playhead is a subview on top.
        Self.channelBackground.setFill()
        NSRect(x: 0, y: 0, width: Self.channelWidth, height: Self.rulerHeight).fill()
        placePlayhead()

        let mode = (layout?.keyframes.autoKey ?? false) ? "● Auto Keying" : ""
        if !mode.isEmpty
        {
          let s = mode as NSString
          s.draw(at: NSPoint(x: 8, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                           .foregroundColor: NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1)])
        }

        if case let .box(from, to, _) = modal
        {
          let rect = NSRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y))
          NSColor(white: 1, alpha: 0.08).setFill()
          rect.fill()
          NSColor(white: 1, alpha: 0.6).setStroke()
          let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
          outline.setLineDash([3, 3], count: 2, phase: 0)
          outline.stroke()
        }

        switch modal
        {
          case let .grab(anchor, _, _):
            status("Move: \(Int(frameDelta(anchor))) frames  ·  Click/Return confirm, Esc/Right Click cancel")
          case let .scale(anchor):
            status(String(format: "Scale: %.3f  ·  Click/Return confirm, Esc/Right Click cancel", scaleFactor(anchor)))
          default:
            break
        }
      }

      private func status(_ text: String)
      {
        let s = text as NSString
        let size = s.size(withAttributes: Self.bold)
        s.draw(at: NSPoint(x: bounds.width - size.width - 10, y: bounds.height - size.height - 6), withAttributes: Self.bold)
      }

      private func placePlayhead()
      {
        let px = x(time).rounded()
        playhead.isHidden = px < Self.channelWidth
        playhead.frame = NSRect(x: px - PlayheadView.width / 2, y: 0, width: PlayheadView.width, height: bounds.height)
        playhead.frameNumber = Int(time.rounded(.down))
      }

      /// The playhead line, with the frame number on the ruler.
      private final class PlayheadView: NSView
      {
        static let width: CGFloat = 64

        var frameNumber = 0
        {
          didSet { if frameNumber != oldValue { needsDisplay = true } }
        }

        override var isFlipped: Bool
        {
          true
        }

        override func hitTest(_: NSPoint) -> NSView?
        {
          nil
        }

        override func draw(_: NSRect)
        {
          DopeSheetView.accent.setFill()
          NSRect(x: bounds.midX - 1, y: DopeSheetView.rulerHeight, width: 2, height: bounds.height).fill()
          let label = "\(frameNumber)" as NSString
          let size = label.size(withAttributes: DopeSheetView.playhead)
          let tag = NSRect(x: bounds.midX - size.width / 2 - 6, y: 1, width: size.width + 12,
                           height: DopeSheetView.rulerHeight - 2)
          NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
          label.draw(at: NSPoint(x: tag.midX - size.width / 2, y: tag.midY - size.height / 2),
                     withAttributes: DopeSheetView.playhead)
        }
      }
    }
  }
#endif
