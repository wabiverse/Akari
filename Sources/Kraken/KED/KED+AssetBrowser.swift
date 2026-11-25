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
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#else
  import UIKit
#endif

#if os(macOS)
  extension NSPasteboard.PasteboardType
  {
    /// a library asset dragged out of the asset browser, as json
    static let krakenAsset = NSPasteboard.PasteboardType("org.wabi.kraken.asset")
  }
#endif

extension Kraken
{
  /// the asset browser area: the libraries' catalogs, and their assets as rendered tiles to drag into the viewport.
  @MainActor
  struct AssetBrowser: View
  {
    let layout: Layout
    @State private var library = AssetLibrary.shared
    @State private var shelf: AssetShelf

    init(layout: Layout, shelf: AssetShelf)
    {
      self.layout = layout
      _shelf = State(wrappedValue: shelf)
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        HStack(spacing: 8)
        {
          Text(shelf.title)
            .font(Properties.font)
            .foregroundColor(Properties.text)
          Text(library.scanning ? "Scanning…" : "\(shelf.shown.count) of \(shelf.all.count)")
            .font(Properties.font)
            .foregroundColor(Color(white: 0.55))
          Spacer()
          #if os(macOS)
            NativeTextField(text: Binding(get: { shelf.search }, set: { shelf.search = $0 }), width: 140)
          #else
            TextField("Search", text: Binding(get: { shelf.search }, set: { shelf.search = $0 }))
              .font(Properties.font)
              .frame(width: 140)
          #endif
          #if os(macOS)
            HeaderButton(title: "Add Folder…") { Self.chooseFolder() }
          #endif
          HeaderButton(title: "Rescan") { library.rescan() }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Properties.menu)
        NativeView(make: { [layout, shelf] in AssetBrowserView(layout: layout, shelf: shelf) },
                   size: { ViewSize($0.width ?? 600, $0.height ?? 200) })
      }
    }

    #if os(macOS)
      private static func chooseFolder()
      {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Library"
        panel.message = "Choose a folder of USD assets to show in the asset browser"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AssetLibrary.shared.add(folder: url)
      }
    #endif
  }

  @MainActor
  struct HeaderButton: View
  {
    let title: String
    let tap: () -> Void
    @State private var hovered = false

    init(title: String, tap: @escaping () -> Void)
    {
      self.title = title
      self.tap = tap
    }

    var body: some View
    {
      Text(title)
        .font(Properties.font)
        .foregroundColor(Properties.text)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Properties.fieldHover : Properties.field))
        .onHover { hovered = $0 }
        .onTapGesture { tap() }
    }
  }

  /// draws the catalog tree and the asset tiles, and starts the drags that carry an asset into the viewport.
  final class AssetBrowserView: CanvasView
  {
    private let layout: Layout
    private let library = AssetLibrary.shared
    private let shelf: AssetShelf
    private var timer: Timer?
    private var drawn = -1
    private var drawnFilter = ""
    private var collapsed: Set<[String]> = []
    private var selected: String?
    private var hovered: CGPoint?
    private var tileOffset: CGFloat = 0
    private var catalogOffset: CGFloat = 0
    private var press: (point: CGPoint, tile: Int?, row: Int?, offset: CGFloat, dragging: Bool, scrolling: Bool)?
    #if os(macOS)
      private var tracking: NSTrackingArea?
    #endif

    private static let touch = FormFactor.isTouch
    private static let catalogWidth: CGFloat = touch ? 200 : 170
    private static let rowHeight: CGFloat = touch ? 34 : 20
    private static let tileWidth: CGFloat = touch ? 120 : 104
    private static let tileHeight: CGFloat = touch ? 142 : 122
    private static let gap: CGFloat = 6
    private static let background = PlatformColor(white: 0.157, alpha: 1)
    private static let side = PlatformColor(white: 0.135, alpha: 1)
    private static let tileColor = PlatformColor(white: 0.2, alpha: 1)
    private static let hoverColor = PlatformColor(white: 0.25, alpha: 1)
    private static let selectedColor = PlatformColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 1)
    private static let ink = PlatformColor(white: 0.88, alpha: 1)
    private static let dim = PlatformColor(white: 0.55, alpha: 1)
    private static let font = PlatformFont.systemFont(ofSize: touch ? 13 : 11)
    private static let small = PlatformFont.systemFont(ofSize: touch ? 11 : 9)

    init(layout: Layout, shelf: AssetShelf)
    {
      self.layout = layout
      self.shelf = shelf
      super.init()

      // tiles scrolled past the top would otherwise draw over the header above the canvas
      clipsToBounds = true
      let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }

      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }

    func stop()
    {
      timer?.invalidate()
      timer = nil
    }

    private func tick()
    {
      let filter = shelf.search + "|" + shelf.catalog.joined(separator: "/")
      guard library.revision != drawn || filter != drawnFilter else { return }
      drawn = library.revision
      if filter != drawnFilter { tileOffset = 0 }
      drawnFilter = filter
      invalidate()
    }

    // MARK: layout

    /// the catalog rows that show, the children of collapsed catalogs hidden
    private var rows: [AssetShelf.CatalogRow]
    {
      shelf.catalogs.filter
      { row in
        !(1 ..< max(row.path.count, 1)).contains { collapsed.contains(Array(row.path.prefix($0))) }
      }
    }

    private var tileArea: CGRect
    {
      CGRect(x: Self.catalogWidth, y: 0, width: max(bounds.width - Self.catalogWidth, 0), height: bounds.height)
    }

    private var columns: Int
    {
      max(Int((tileArea.width - Self.gap) / (Self.tileWidth + Self.gap)), 1)
    }

    private func tileRect(_ i: Int) -> CGRect
    {
      let column = i % columns, row = i / columns
      return CGRect(x: tileArea.minX + Self.gap + CGFloat(column) * (Self.tileWidth + Self.gap),
                    y: Self.gap + CGFloat(row) * (Self.tileHeight + Self.gap) - tileOffset,
                    width: Self.tileWidth, height: Self.tileHeight)
    }

    private func tile(at p: CGPoint) -> Int?
    {
      guard p.x >= tileArea.minX else { return nil }
      let count = shelf.shown.count
      return (0 ..< count).first { tileRect($0).contains(p) }
    }

    private func row(at p: CGPoint) -> Int?
    {
      guard p.x < Self.catalogWidth else { return nil }
      let i = Int((p.y + catalogOffset - 4) / Self.rowHeight)
      return i >= 0 && i <= rows.count ? i : nil
    }

    private func clampOffsets()
    {
      let tileRows = (shelf.shown.count + columns - 1) / columns
      let content = Self.gap + CGFloat(tileRows) * (Self.tileHeight + Self.gap)
      tileOffset = max(0, min(tileOffset, content - bounds.height))
      let catalogContent = CGFloat(rows.count + 1) * Self.rowHeight + 8
      catalogOffset = max(0, min(catalogOffset, catalogContent - bounds.height))
    }

    // MARK: pointer

    #if os(macOS)
      override func scrollWheel(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 24)
        if p.x < Self.catalogWidth { catalogOffset -= delta } else { tileOffset -= delta }
        clampOffsets()
        invalidate()
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
      }

      override func mouseMoved(with event: NSEvent)
      {
        hovered = convert(event.locationInWindow, from: nil)
        invalidate()
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = nil
        invalidate()
      }
    #endif

    override func pointerDown(at point: CGPoint)
    {
      press = (point, tile(at: point), row(at: point), point.x < Self.catalogWidth ? catalogOffset : tileOffset, false, false)
    }

    override func pointerDragged(to point: CGPoint)
    {
      guard var press else { return }
      defer { self.press = press }
      let moved = hypot(point.x - press.point.x, point.y - press.point.y) > 5
      guard moved, !press.dragging else
      {
        if press.scrolling { scrollBy(press, point) }
        return
      }

      #if os(macOS)
        if let i = press.tile, i < shelf.shown.count
        {
          press.dragging = true
          startDrag(shelf.shown[i], from: tileRect(i))
          return
        }
      #endif

      // on glass a drag scrolls whichever side it's on
      press.scrolling = true
      scrollBy(press, point)
    }

    private func scrollBy(_ press: (point: CGPoint, tile: Int?, row: Int?, offset: CGFloat, dragging: Bool, scrolling: Bool),
                          _ point: CGPoint)
    {
      if press.point.x < Self.catalogWidth { catalogOffset = press.offset - (point.y - press.point.y) }
      else { tileOffset = press.offset - (point.y - press.point.y) }
      clampOffsets()
      invalidate()
    }

    override func pointerUp(at _: CGPoint)
    {
      defer { press = nil }
      guard let press, !press.dragging, !press.scrolling else { return }
      if let i = press.tile, i < shelf.shown.count
      {
        selected = shelf.shown[i].id
      }
      else if let r = press.row
      {
        if r == 0 { shelf.catalog = [] }
        else
        {
          let row = rows[r - 1]
          let arrow = CGFloat(row.path.count - 1) * 12 + 8
          if row.hasChildren, press.point.x < arrow + 14
          {
            if collapsed.contains(row.path) { collapsed.remove(row.path) } else { collapsed.insert(row.path) }
          }
          else
          {
            shelf.catalog = row.path
          }
        }
      }

      clampOffsets()
      invalidate()
    }

    override func pointerCancelled()
    {
      press = nil
    }

    override func pointerDoubleTapped(at point: CGPoint)
    {
      guard let i = tile(at: point), i < shelf.shown.count else { return }
      let asset = shelf.shown[i]
      selected = asset.id
      layout.use(asset)
      invalidate()
    }

    // MARK: drawing

    override func draw(_: CGRect)
    {
      Self.background.setFill()
      bounds.fill()
      drawTiles()
      drawCatalogs()
    }

    private func drawCatalogs()
    {
      Self.side.setFill()
      CGRect(x: 0, y: 0, width: Self.catalogWidth, height: bounds.height).fill()
      let entries: [(title: String, depth: Int, count: Int, children: Bool, path: [String])] =
        [("All", 0, shelf.all.count, false, [])]
          + rows.map { ($0.path.last ?? "", $0.path.count, $0.count, $0.hasChildren, $0.path) }
      for (i, entry) in entries.enumerated()
      {
        let y = 4 + CGFloat(i) * Self.rowHeight - catalogOffset
        guard y > -Self.rowHeight, y < bounds.height else { continue }
        let rect = CGRect(x: 4, y: y, width: Self.catalogWidth - 8, height: Self.rowHeight - 2)
        let chosen = entry.path == shelf.catalog
        if chosen || (hovered.map(rect.contains) ?? false)
        {
          (chosen ? Self.selectedColor : Self.hoverColor).setFill()
          PlatformBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }

        let x = 8 + CGFloat(max(entry.depth - 1, 0)) * 12
        if entry.children
        {
          let open = !collapsed.contains(entry.path)
          let arrow = PlatformBezierPath()
          let c = CGPoint(x: x + 4, y: rect.midY)
          if open
          {
            arrow.move(to: CGPoint(x: c.x - 3.5, y: c.y - 2))
            arrow.line(to: CGPoint(x: c.x + 3.5, y: c.y - 2))
            arrow.line(to: CGPoint(x: c.x, y: c.y + 2.5))
          }
          else
          {
            arrow.move(to: CGPoint(x: c.x - 2, y: c.y - 3.5))
            arrow.line(to: CGPoint(x: c.x - 2, y: c.y + 3.5))
            arrow.line(to: CGPoint(x: c.x + 2.5, y: c.y))
          }

          arrow.close()
          Self.dim.setFill()
          arrow.fill()
        }

        let title = entry.title as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Self.ink]
        let height = title.size(withAttributes: attributes).height
        title.draw(in: CGRect(x: x + 14, y: rect.midY - height / 2, width: rect.maxX - x - 44, height: height),
                   withAttributes: attributes)
        let count = "\(entry.count)" as NSString
        let countAttributes: [NSAttributedString.Key: Any] = [.font: Self.small, .foregroundColor: Self.dim]
        let size = count.size(withAttributes: countAttributes)
        count.draw(at: CGPoint(x: rect.maxX - size.width - 6, y: rect.midY - size.height / 2), withAttributes: countAttributes)
      }
    }

    private func drawTiles()
    {
      let shown = shelf.shown
      if shown.isEmpty
      {
        let message = (library.scanning ? "Scanning libraries…" : library.assets.isEmpty
          ? "No assets yet, add a folder of USD assets" : shelf.all.isEmpty ? "No \(shelf.title.lowercased()) in the libraries" : "Nothing matches") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Self.dim]
        let size = message.size(withAttributes: attributes)
        message.draw(at: CGPoint(x: tileArea.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        return
      }

      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      paragraph.lineBreakMode = .byTruncatingTail
      let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Self.ink, .paragraphStyle: paragraph]
      let captionAttributes: [NSAttributedString.Key: Any] = [.font: Self.small, .foregroundColor: Self.dim, .paragraphStyle: paragraph]
      for (i, asset) in shown.enumerated()
      {
        let rect = tileRect(i)
        guard rect.maxY > 0, rect.minY < bounds.height else { continue }
        let chosen = asset.id == selected
        let hover = hovered.map(rect.contains) ?? false
        (chosen ? Self.selectedColor : hover ? Self.hoverColor : Self.tileColor).setFill()
        PlatformBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let side = rect.width - 12
        let picture = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: side, height: side)
        if let image = AssetThumbnails.shared.image(asset)
        {
          withSavedState
          {
            PlatformBezierPath(roundedRect: picture, xRadius: 4, yRadius: 4).addClip()
            #if os(macOS)
              image.draw(in: picture, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            #else
              image.draw(in: picture)
            #endif
          }
        }
        else
        {
          PlatformColor(white: 0.13, alpha: 1).setFill()
          PlatformBezierPath(roundedRect: picture, xRadius: 4, yRadius: 4).fill()
          let glyph = (asset.kind == .material ? "●" : "▣") as NSString
          let glyphAttributes: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 28), .foregroundColor: Self.dim,
                                                                .paragraphStyle: paragraph]
          glyph.draw(in: CGRect(x: picture.minX, y: picture.midY - 18, width: picture.width, height: 36), withAttributes: glyphAttributes)
        }

        (asset.name as NSString).draw(in: CGRect(x: rect.minX + 3, y: picture.maxY + 2, width: rect.width - 6, height: 15),
                                      withAttributes: attributes)
        let caption = asset.kind == .material ? "Material" : asset.modelKind.isEmpty ? "Scene" : asset.modelKind.capitalized
        (caption as NSString).draw(in: CGRect(x: rect.minX + 3, y: picture.maxY + 16, width: rect.width - 6, height: 12),
                                   withAttributes: captionAttributes)
      }
    }
  }
}

#if os(macOS)
  extension Kraken.AssetBrowserView: NSDraggingSource
  {
    /// hands the asset to a drag the viewport takes, its thumbnail following the pointer
    fileprivate func startDrag(_ asset: Kraken.LibraryAsset, from rect: CGRect)
    {
      guard let event = NSApp.currentEvent, let data = try? JSONEncoder().encode(asset) else { return }
      let item = NSPasteboardItem()
      item.setData(data, forType: .krakenAsset)
      let dragging = NSDraggingItem(pasteboardWriter: item)
      let image = Kraken.AssetThumbnails.shared.image(asset) ?? NSImage(size: NSSize(width: 64, height: 64))
      let side: CGFloat = 72
      dragging.setDraggingFrame(CGRect(x: rect.midX - side / 2, y: rect.minY + 6, width: side, height: side), contents: image)
      beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation
    {
      .copy
    }
  }

  extension Kraken.AssetBrowserView: Kraken.Dismantling
  {
    func dismantle()
    {
      stop()
    }
  }
#else
  extension Kraken.AssetBrowserView: Kraken.Dismantling
  {
    func dismantle()
    {
      stop()
    }
  }
#endif
