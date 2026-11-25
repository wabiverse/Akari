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
#else
  import UIKit
#endif

extension Kraken
{
  /// the panels the touch layout opens under the viewport, or beside it on a wide screen.
  enum TouchPanel: CaseIterable
  {
    case scene, properties

    var title: String
    {
      switch self
      {
        case .scene: "Scene"
        case .properties: "Properties"
      }
    }

    /// the desktop's own icons, the scene's from its properties tab and a new one for the panel of them.
    var icon: TabIcon.Kind
    {
      switch self
      {
        case .scene: .scene
        case .properties: .properties
      }
    }
  }

  /// the measurements and colors the touch layout shares.
  enum Touch
  {
    static let button = 44.0
    static let small = 36.0
    static let bar = 52.0
    static let dock = 58.0
    static let rail = 68.0
    static let ruler = 34.0
    static let sideWidth = 372.0
    /// the share of a tall screen an open panel takes.
    static let panelShare = 0.4
    static let chrome = Color(white: 0.1)
    static let well = Color(white: 0.16, opacity: 0.94)
    static let divider = Color(white: 0.06)
    static let ink = Color(white: 0.92)

    /// a scene's file name and the font size that fits `width`, shrinking before the name is cut in the middle
    @MainActor
    static func fittedTitle(_ name: String, width: Double) -> (text: String, size: Double)
    {
      func fits(_ text: String, _ size: Double) -> Bool
      {
        let font = PlatformFont.systemFont(ofSize: size, weight: .semibold)
        return Double((text as NSString).size(withAttributes: [.font: font]).width) + 2 <= width
      }

      let stem = (name as NSString).deletingPathExtension
      for text in [name, stem]
      {
        for size in [14.0, 13] where fits(text, size)
        {
          return (text, size)
        }
      }

      let letters = Array(stem)
      for keep in stride(from: letters.count - 1, through: 2, by: -1)
      {
        let head = (keep + 1) / 2
        let text = String(letters.prefix(head)) + "…" + String(letters.suffix(keep - head))
        if fits(text, 13) { return (text, 13) }
      }

      return ("…", 13)
    }
  }

  #if !os(macOS)
    /// an empty view behind the layout that reports the window's safe area each time it settles on a new one.
    final class SafeAreaWatcher: UIView
    {
      var changed: (CGSize) -> Void = { _ in }
      private var last = CGSize.zero

      override init(frame: CGRect)
      {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = false
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      override func layoutSubviews()
      {
        super.layoutSubviews()
        report()
      }

      override func safeAreaInsetsDidChange()
      {
        super.safeAreaInsetsDidChange()
        report()
      }

      private func report()
      {
        guard let size = window?.safeAreaLayoutGuide.layoutFrame.size, size != last else { return }
        last = size

        // after this layout pass, SwiftCrossUI is mid update while the window turns.
        DispatchQueue.main.async { [changed] in changed(size) }
      }
    }
  #endif

  /// a rounded icon button sized for a finger.
  @MainActor
  struct TouchButton: View
  {
    let symbol: String
    var active = false
    var size = Touch.button
    let action: () -> Void

    init(_ symbol: String, active: Bool = false, size: Double = Touch.button, action: @escaping () -> Void)
    {
      self.symbol = symbol
      self.active = active
      self.size = size
      self.action = action
    }

    var body: some View
    {
      SymbolIcon(symbol, size: size * 0.4, white: active ? 1 : 0.86)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.3).fill(active ? Properties.accent : Touch.well))
        .onTapGesture { action() }
    }
  }

  /// a dock tab with an icon over its name, a menu tab lays a clear menu button over itself
  @MainActor
  struct DockTab<Icon: View>: View
  {
    let title: String
    var active = false
    let icon: Icon
    /// the rail width at the side, an even share of the bar along the bottom
    var width = Touch.rail
    var action: () -> Void = {}
    var menu: (@MainActor () -> [MenuEntry])?

    private var face: some View
    {
      VStack(spacing: 4)
      {
        icon.frame(width: 26, height: 24)
        Text(title)
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(active ? Properties.text : Properties.label)
      }
      .frame(width: width, height: Touch.dock - 10)
      .background(RoundedRectangle(cornerRadius: 12).fill(active ? Color(white: 0.22) : Color.clear))
    }

    var body: some View
    {
      if let menu
      {
        face.overlay { MenuButton(size: Touch.dock - 10, clear: true, entries: menu).frame(width: width) }
      }
      else
      {
        face.onTapGesture { action() }
      }
    }
  }

  /// playback, keys and the frame ruler, sized for fingers.
  @MainActor
  struct TouchTransport: View
  {
    @State private var timeline: Timeline
    @State private var job: RenderJob
    @State private var keyframes: Keyframes
    let layout: Layout
    /// one row beside the ruler on a wide screen, the ruler under the buttons on a tall one.
    let wide: Bool

    init(timeline: Timeline, job: RenderJob, layout: Layout, wide: Bool)
    {
      _timeline = State(wrappedValue: timeline)
      _job = State(wrappedValue: job)
      _keyframes = State(wrappedValue: layout.keyframes)
      self.layout = layout
      self.wide = wide
    }

    private var buttons: some View
    {
      HStack(spacing: 6)
      {
        TouchButton("backward.end.fill", size: Touch.small) { timeline.jump(toEnd: false) }
        TouchButton("backward.fill", size: Touch.small) { keyframes.jumpToKey(forward: false) }
        TouchButton(timeline.isPlaying ? "pause.fill" : "play.fill", active: timeline.isPlaying, size: Touch.small)
        {
          timeline.toggle()
        }
        TouchButton("forward.fill", size: Touch.small) { keyframes.jumpToKey(forward: true) }
        TouchButton("forward.end.fill", size: Touch.small) { timeline.jump(toEnd: true) }
        Spacer().frame(width: 6)
        TouchButton("plus.diamond", size: Touch.small) { keyframes.insertTransforms(layout.selection) }
        TouchButton("minus.diamond", size: Touch.small) { keyframes.deleteTransforms(layout.selection) }
        TouchButton("record.circle", active: keyframes.autoKey, size: Touch.small) { keyframes.autoKey.toggle() }
      }
    }

    private var ruler: some View
    {
      TimelineRuler(frame: timeline.frame, start: job.frameStart, end: job.frameEnd) { timeline.seek(to: $0) }
        .frame(height: Touch.ruler)
        .cornerRadius(8)
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        if wide
        {
          HStack(spacing: 10)
          {
            buttons
            ruler
          }
        }
        else
        {
          VStack(spacing: 6)
          {
            HStack(spacing: 0)
            {
              Spacer()
              buttons
              Spacer()
            }
            ruler
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Touch.chrome)
    }
  }
}

extension Kraken.Workspace
{
  /// the touch layout, the viewport fills the screen with tools over it, playback along the bottom and panels in the dock
  var touchBody: some View
  {
    GeometryReader
    { proxy in
      // after a rotation the window is laid out at the whole screen, so the layout takes the smaller of it and the safe area
      let safe = layout.safeArea ?? proxy.size
      let size = ViewSize(min(proxy.size.width, safe.width), min(proxy.size.height, safe.height))
      Group
      {
        if size.width > size.height
        {
          wideTouchLayout(size)
        }
        else
        {
          tallTouchLayout(size)
        }
      }
      .frame(width: size.width, height: size.height)
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .background(Touch.divider)
    .overlay { aboutLayer }
    .onAppear { watchScreen() }
  }

  /// paints the strips under the status bar and home indicator and follows the safe area after the screen turns
  private func watchScreen()
  {
    #if !os(macOS)
      guard let root = Kraken.Dialogs.window?.rootViewController?.view else { return }
      root.backgroundColor = UIColor(white: 0.1, alpha: 1)
      guard !root.subviews.contains(where: { $0 is Kraken.SafeAreaWatcher }) else { return }
      let watcher = Kraken.SafeAreaWatcher(frame: root.bounds)
      let layout = layout
      watcher.changed = { layout.safeArea = ViewSize(Double($0.width), Double($0.height)) }
      root.insertSubview(watcher, at: 0)
    #endif
  }

  // the shared views this layout is built from.
  private typealias Touch = Kraken.Touch
  private typealias TouchButton = Kraken.TouchButton
  private typealias MenuButton = Kraken.MenuButton
  private typealias Properties = Kraken.Properties
  private typealias SymbolIcon = Kraken.SymbolIcon
  private typealias LayoutToolbar = Kraken.LayoutToolbar
  private typealias ViewportOverlay = Kraken.ViewportOverlay
  private typealias RenderResult = Kraken.RenderResult
  private typealias PrimOutliner = Kraken.PrimOutliner
  private typealias HUD = Kraken.HUD

  private func tallTouchLayout(_ size: ViewSize) -> some View
  {
    VStack(spacing: 0)
    {
      touchTopBar(width: size.width, wide: false)
      touchViewport

      // sculpting has no use for playback, so the viewport takes its room
      if layout.tab != .sculpting { Kraken.TouchTransport(timeline: timeline, job: renderJob, layout: layout, wide: false) }
      if let panel
      {
        panelView(panel, width: size.width)
          .frame(height: (size.height * Touch.panelShare).rounded())
      }

      // the tabs share the whole width evenly like a tab bar
      HStack(spacing: 0)
      {
        dockItems(width: (Double(size.width) / Double(Self.dockTabCount)).rounded(.down))
      }
      .frame(height: Touch.dock)
      .background(Touch.chrome)
    }
  }

  private func wideTouchLayout(_ size: ViewSize) -> some View
  {
    VStack(spacing: 0)
    {
      touchTopBar(width: size.width, wide: true)
      HStack(spacing: 0)
      {
        touchViewport
        if let panel
        {
          panelView(panel, width: Touch.sideWidth)
            .frame(width: Touch.sideWidth)
        }

        VStack(spacing: 4)
        {
          dockItems(width: Touch.rail)
          Spacer()
        }
        .padding(.top, 6)
        .frame(width: Touch.rail + 4)
        .background(Touch.chrome)
      }

      if layout.tab != .sculpting { Kraken.TouchTransport(timeline: timeline, job: renderJob, layout: layout, wide: true) }
    }
  }

  // MARK: bars

  /// the top bar, on an upright phone the mode shows as its icon so the scene name gets the width
  private func touchTopBar(width: Double, wide: Bool) -> some View
  {
    // read from the layout each update, the button keeps the closures it was first made with
    let mode = MenuButton(symbol: layout.modeSymbol,
                          title: wide ? (layout.tab == .sculpting ? "Sculpt" : layout.mode == .edit ? "Edit" : "Object") : "")
    {
      // the sculpt viewport stands in for the layout one, so its modes are listed here too
      layout.viewport?.entries(.mode) ?? {
        var object = Kraken.MenuEntry(title: "Object Mode") { layout.open(.layout) }
        object.symbol = Kraken.Layout.objectSymbol
        var editing = Kraken.MenuEntry(title: "Edit Mode") { layout.open(.modeling) }
        editing.symbol = Kraken.Layout.editSymbol
        var sculpt = Kraken.MenuEntry(title: "Sculpt Mode", checked: true) {}
        sculpt.symbol = Kraken.Layout.sculptSymbol
        return [object, editing, sculpt]
      }()
    }

    let spacing = 8, padding = 10
    let taken = Touch.button * 3 + mode.width + Double(padding * 2 + spacing * 4)
    let title = Touch.fittedTitle(scene.wrappedValue.title, width: max(width - taken, 0))
    return HStack(spacing: spacing)
    {
      MenuButton(symbol: "line.3.horizontal") { appMenu }
      mode
      Text(title.text)
        .font(.system(size: title.size, weight: .semibold))
        .foregroundColor(Properties.text)
        .lineLimit(1)
        .frame(minWidth: 0.0, maxWidth: .infinity)
      TouchButton("arrow.uturn.backward") { layout.undo() }
      TouchButton("arrow.uturn.forward") { layout.redo() }
    }
    .padding(.horizontal, padding)
    .frame(height: Touch.bar)
    .background(Touch.chrome)
  }

  /// file, edit, render, view and help in one menu, the desktop's top bar folded up.
  private var appMenu: [Kraken.MenuEntry]
  {
    Kraken.TopMenu.allCases.map
    { menu in
      let entries = menu == .view ? touchViewEntries : entries(for: menu)
      return .submenu(menu.rawValue, entries.filter { $0.title != "Quit Akari" })
    }
  }

  /// the view menu without the desktop's areas, which the touch layout doesn't have.
  private var touchViewEntries: [Kraken.MenuEntry]
  {
    [Kraken.MenuEntry(title: "Camera", checked: renderJob.lookingThrough) { renderJob.toggleCameraView() },
     Kraken.MenuEntry(title: "Statistics", checked: showsStatistics) { showsStatistics.toggle() },
     Kraken.MenuEntry(title: "Toolbar", checked: layout.showsToolbar) { layout.showsToolbar.toggle() }]
  }

  /// the panels plus the add and render tabs
  private static let dockTabCount = Kraken.TouchPanel.allCases.count + 2

  private func dockItems(width: Double) -> some View
  {
    let renderJob = renderJob
    let iconSize = 22.0
    func panelTab(_ item: Kraken.TouchPanel) -> some View
    {
      Kraken.DockTab(title: item.title, active: panel == item,
                     icon: Kraken.TabIcon(kind: item.icon, background: panel == item ? 0.22 : 0.1, size: iconSize), width: width)
      {
        panel = panel == item ? nil : item
      }
    }

    return Group
    {
      panelTab(.scene)
      panelTab(.properties)

      Kraken.DockTab(title: "Add",
                     icon: SymbolIcon("plus", size: 14, white: 1)
                       .frame(width: 26, height: 26)
                       .background(RoundedRectangle(cornerRadius: 13).fill(Properties.accent)),
                     width: width,
                     menu: { layout.viewport?.entries(.add).filter { !$0.isHeader } ?? [] })

      Kraken.DockTab(title: "Render", active: renderJob.showsResult,
                     icon: Kraken.TabIcon(kind: .render, background: renderJob.showsResult ? 0.22 : 0.1, size: iconSize),
                     width: width,
                     menu: {
                       entries(for: .render) + [.separator,
                                                Kraken.MenuEntry(title: "View Render", checked: renderJob.showsResult)
                                                { renderJob.toggleResult() }]
                     })
    }
  }

  // MARK: viewport

  /// the viewport with tools down its left, view and selection controls down its right and selection modes along its top
  private var touchViewport: some View
  {
    layoutViewport
      .overlay
      {
        // the sculpt viewport lies over the scene's, which pauses while it shows
        if layout.tab == .sculpting { sculptViewport }
      }
  }

  /// the sculpt viewport with its brushes down the left, the look and view down the right and size and strength below
  private var sculptViewport: some View
  {
    let sculpt = layout.sculpt
    return GeometryReader
    { proxy in
      // the brush bar takes the width the viewport really has, beside the shelf rather than under it
      let shelf = layout.showsToolbar ? Kraken.SculptToolShelf.width : 0
      Kraken.SculptCanvas(sculpt: sculpt)
        .overlay(alignment: .leading) { Kraken.SculptToolShelf(layout: layout) }
        .overlay(alignment: .bottomTrailing)
        {
          Kraken.SculptBrushBar(sculpt: sculpt, width: max(proxy.size.width - shelf, 0))
            .frame(width: max(proxy.size.width - shelf, 0))
        }
        .overlay(alignment: .topTrailing) { sculptControls }
    }
  }

  /// the look, the shapes to add, remeshing and framing, down the sculpt viewport's right
  private var sculptControls: some View
  {
    let sculpt = layout.sculpt
    return VStack(spacing: 8)
    {
      MenuButton(symbol: sculpt.shading.symbol)
      {
        Kraken.SculptShading.allCases.map
        { shading in
          Kraken.MenuEntry(title: shading.rawValue, checked: sculpt.shading == shading) { sculpt.shading = shading }
        }
      }
      MenuButton(symbol: "plus.square.on.square")
      {
        Kraken.SculptShape.allCases.map
        { shape in
          Kraken.MenuEntry(title: "Add \(shape.rawValue)")
          {
            sculpt.shape = shape
            sculpt.insertShape()
          }
        }
      }
      Kraken.SculptRemeshButton(sculpt: sculpt)
      TouchButton("viewfinder") { sculpt.viewport?.frameAll() }
    }
    .padding(10)
  }

  private var layoutViewport: some View
  {
    viewportCanvas
      .overlay(alignment: .topLeading)
      {
        if showsStatistics { ViewportOverlay(driver: driver) }
      }
      .overlay(alignment: .leading) { LayoutToolbar(layout: layout) }
      .overlay(alignment: .topTrailing) { viewportControls }
      .overlay(alignment: .top)
      {
        if layout.mode == .edit { selectModes }
      }
      .overlay
      {
        if renderJob.showsResult { RenderResult(job: renderJob) }
      }
  }

  private var viewportControls: some View
  {
    let layout = layout
    return VStack(spacing: 8)
    {
      MenuButton(symbol: "circle.lefthalf.filled") { shadingEntries }
      MenuButton(symbol: "eye") { layout.viewport?.entries(.view) ?? [] }
      MenuButton(symbol: "cursorarrow.rays") { selectEntries }

      // the mode is read when the button updates and when the menu opens, not when the button was made
      MenuButton(symbol: layout.mode == .edit ? "hammer" : "slider.horizontal.below.square.and.square.filled")
      {
        layout.viewport?.entries(layout.mode == .edit ? .mesh : .object) ?? []
      }
      TouchButton("square.grid.3x3", active: layout.snaps) { layout.snaps.toggle() }
    }
    .padding(10)
  }

  /// the shading modes with the x-ray and overlay toggles.
  private var shadingEntries: [Kraken.MenuEntry]
  {
    let layout = layout
    return (layout.viewport?.entries(.shading) ?? []) + [
      .separator,
      Kraken.MenuEntry(title: "X-Ray", checked: layout.xray) { layout.xray.toggle() },
      Kraken.MenuEntry(title: "Overlays", checked: layout.overlays) { layout.overlays.toggle() },
    ]
  }

  /// the select menu, with the toggle that makes taps add to the selection.
  private var selectEntries: [Kraken.MenuEntry]
  {
    let layout = layout
    return [Kraken.MenuEntry(title: "Add to Selection", checked: layout.extendsSelection) { layout.extendsSelection.toggle() },
            .separator] + (layout.viewport?.entries(.select) ?? [])
  }

  private var selectModes: some View
  {
    HStack(spacing: 4)
    {
      ForEach([("Vertex", Kraken.SelectMode.vertex, "circle.grid.2x2"), ("Edge", .edge, "line.diagonal"),
               ("Face", .face, "square.fill")], id: \.0)
      { item in
        TouchButton(item.2, active: layout.selectMode == item.1, size: Touch.small) { layout.setSelectMode(item.1) }
      }
    }
    .padding(4)
    .background(RoundedRectangle(cornerRadius: 14).fill(Touch.chrome))
    .padding(.top, 10)
  }

  // MARK: panels

  private func panelView(_ panel: Kraken.TouchPanel, width: Double) -> some View
  {
    VStack(spacing: 0)
    {
      HStack(spacing: 8)
      {
        Kraken.TabIcon(kind: panel.icon, background: 0.188, size: 16)
        Text(panel.title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(Properties.text)
        Spacer()
        TouchButton("xmark", size: 32) { self.panel = nil }
      }
      .padding(.horizontal, 12)
      .frame(height: 44)

      switch panel
      {
        case .scene:
          PrimOutliner(layout: layout)
        case .properties:
          if layout.tab == .sculpting
          {
            Kraken.SculptProperties(layout: layout, width: Int(width) - 30)
              .frame(width: width, alignment: .leading)
          }
          else
          {
            HUD(state: settings, job: renderJob, inspector: layout.inspector, width: Int(width) - 30)
              .frame(width: width, alignment: .leading)
          }
      }
    }
    .background(Properties.region)
  }
}
