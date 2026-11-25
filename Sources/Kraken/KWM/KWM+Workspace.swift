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
#endif

extension Kraken
{
  /// the window's layout.
  @MainActor
  struct Workspace: View
  {
    static let sidebarDefault = Double(Properties.width + 30)
    /// the properties' controls don't fit in a narrower sidebar, so it collapses instead.
    static let sidebarMinimum = Double(Properties.width + 30)
    static let timelineMinimum = 24.0
    static let outlinerMinimum = 48.0

    /// how far an edge has to be dragged past an area's minimum size before the area collapses.
    static let collapseDistance = 80.0

    /// how close an area is to collapsing, from 0 at its minimum size to 1 once it collapses.
    static func overshoot(_ size: Double, minimum: Double) -> Double
    {
      min(max((minimum - size) / collapseDistance, 0), 1)
    }

    /// the size an area is drawn at, between its minimum and `max`, or 0 once collapsed.
    static func shown(_ size: Double, minimum: Double, max: Double) -> Double
    {
      overshoot(size, minimum: minimum) >= 1 ? 0 : min(Swift.max(size, minimum), max)
    }

    /// the size an area keeps when a drag ends, so the next drag starts from its edge.
    static func settled(_ size: Double, minimum: Double) -> Double
    {
      overshoot(size, minimum: minimum) >= 1 ? minimum - collapseDistance : max(size, minimum)
    }

    let engine: Akari.RenderEngine
    let hydra: Hydra.RenderEngine
    let driver: any Akari.HydraFrameDriver
    let scene: Binding<Kraken.SceneFile>
    let timeline: Kraken.Timeline

    @State var settings: Kraken.HUDState
    @State var renderJob: Kraken.RenderJob
    @State var showsTimeline = true
    @State var showsPlaybackMenu = false
    @State var openMenu: TopMenu?
    @State var showsProperties = true
    /// area sizes as their edges are dragged. below an area's minimum, it's on its way to collapsing.
    @State var sidebarWidth = Kraken.Workspace.sidebarDefault
    @State var outlinerHeight = Kraken.PrimOutliner.height
    @State var timelineBody = Double(Kraken.TimelineView.rulerHeight)
    @State var showsAssets = true
    @State var assetsHeight = Kraken.Workspace.assetsDefault
    static let assetsDefault = 200.0
    static let assetsMinimum = 120.0
    @State var showsObjects = true
    @State var objectsWidth = Kraken.Workspace.objectsDefault
    static let objectsDefault = 330.0
    static let objectsMinimum = 240.0

    /// the window's content size. areas are capped to it so they can't push the window past the screen.
    private static var room: (width: Double, height: Double)
    {
      #if os(macOS)
        if let size = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentLayoutRect.size
        {
          return (Double(size.width), Double(size.height))
        }
      #endif
      return (1600, 1000)
    }

    /// leaves room for the viewport header and the timeline controls.
    private static var sidebarMaximum: Double
    {
      max(room.width - 790, sidebarMinimum)
    }

    /// leaves the viewport at least 160 points, plus the bars around it.
    private static var timelineMaximum: Double
    {
      max(room.height - 290, timelineMinimum)
    }

    /// leaves the properties panel at least 160 points.
    private static var outlinerMaximum: Double
    {
      max(room.height - 230, outlinerMinimum)
    }

    private var timelineShown: Double
    {
      Self.shown(timelineBody, minimum: Self.timelineMinimum, max: Self.timelineMaximum)
    }

    private var sidebarShown: Double
    {
      Self.shown(sidebarWidth, minimum: Self.sidebarMinimum, max: Self.sidebarMaximum)
    }

    private var outlinerShown: Double
    {
      Self.shown(outlinerHeight, minimum: Self.outlinerMinimum, max: Self.outlinerMaximum)
    }

    @State var showsStatistics = true
    @State var showsAbout = false
    @State var layout: Kraken.Layout
    /// the panel the touch layout shows under or beside the viewport, none for the viewport alone.
    @State var panel: Kraken.TouchPanel?

    init(engine: Akari.RenderEngine,
         hydra: Hydra.RenderEngine,
         driver: any Akari.HydraFrameDriver,
         settings: Kraken.HUDState,
         layout: Kraken.Layout,
         renderJob: Kraken.RenderJob,
         timeline: Kraken.Timeline,
         scene: Binding<Kraken.SceneFile>)
    {
      self.engine = engine
      self.hydra = hydra
      self.driver = driver
      self.scene = scene
      _settings = State(wrappedValue: settings)
      _renderJob = State(wrappedValue: renderJob)
      self.timeline = timeline
      layout.sceneURL = scene.wrappedValue.fileURL
      let playback = timeline.playback
      layout.adoptStage =
      { url, probeTimes in
        scene.wrappedValue = Kraken.SceneFile(fileURL: url)
        renderJob.path = Kraken.RenderJob.defaultOutputPath(for: url)
        renderJob.adoptStage()
        hydra.performOnFrameQueue { playback.adoptStage() }
        Task { @MainActor in await playback.prebakeProbes(at: probeTimes) }
      }

      layout.toggleCamera = { [renderJob] in renderJob.toggleCameraView() }

      layout.keyframes.timeline = timeline
      timeline.onFrame = { [weak layout] playing in layout?.keyframes.frameChanged(playing: playing) }
      _layout = State(wrappedValue: layout)
    }

    var body: some View
    {
      if FormFactor.isTouch { followingScenes(touchBody) } else { followingScenes(desktopBody) }
    }

    /// starts a render asked for at launch, and opens scenes handed to the app.
    private func followingScenes(_ content: some View) -> some View
    {
      content
        .onAppear
        {
          renderJob.startPendingJob()
          startSculptingIfAsked()
        }
        .onOpenURL
        { url in
          guard url.isFileURL else { return }

          // leaves the open event and comes to the front first, a save prompt behind the finder used to block every later open
          DispatchQueue.main.async
          {
            #if os(macOS)
              NSApp.activate()
              NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            #endif

            // a scene from the files app needs its folder too, or its references stay out of reach
            Kraken.Dialogs.openHanded(url) { layout.replaceStage(with: $0, asking: true) }
          }
        }
    }

    /// opens the sculpting tab in the look the launch asked for, once
    private func startSculptingIfAsked()
    {
      let args = Kraken.parseArgs()
      guard args.sculptShading != nil, layout.tab != .sculpting else { return }

      layout.open(.sculpting)
      if let look = args.sculptShading.flatMap({ name in Kraken.SculptShading.allCases.first { $0.rawValue.lowercased() == name.lowercased() } })
      {
        layout.sculpt.shading = look
      }
    }

    /// the hydra viewport with the passepartout and the tools drawn over it, shared by both layouts.
    var viewportCanvas: some View
    {
      Hydra.Viewport(engine: hydra)
        .frame(minWidth: FormFactor.isTouch ? 160 : 240, minHeight: 160)
        .overlay
        {
          if renderJob.showsPassepartout { Passepartout(aspect: renderJob.aspect) }
        }
        .overlay { layoutOverlay }
    }

    /// the desktop layout: menus along the top, the viewport and timeline, the outliner and properties beside them.
    private var desktopBody: some View
    {
      VStack(spacing: 0)
      {
        topBar
        Rectangle()
          .fill(Color(white: 0.09))
          .frame(height: 1)
        HStack(spacing: 0)
        {
          VStack(spacing: 0)
          {
            HStack(spacing: 0)
            {
              if showsObjects, layout.tab == .assets
              {
                let shown = Self.shown(objectsWidth, minimum: Self.objectsMinimum, max: Self.sidebarMaximum)
                if shown > 0
                {
                  AssetBrowser(layout: layout, shelf: AssetShelf.objects)
                    .frame(width: shown)
                    .area("objects")
                }
                AreaEdge(axis: .vertical, collapses: "objects", direction: .left)
                { dx in
                  objectsWidth = min(max(objectsWidth + dx, -200), Self.sidebarMaximum)
                  return Self.overshoot(objectsWidth, minimum: Self.objectsMinimum)
                }
                reset: { objectsWidth = Self.objectsDefault }
                ended: { objectsWidth = Self.settled(objectsWidth, minimum: Self.objectsMinimum) }
              }
              VStack(spacing: 0)
              {
                LayoutHeader(layout: layout)
                if layout.tab == .sculpting
                {
                  Rectangle()
                    .fill(Color(white: 0.09))
                    .frame(height: 1)
                  SculptHeader(sculpt: layout.sculpt)
                }

                Rectangle()
                  .fill(Color(white: 0.09))
                  .frame(height: 1)
                viewportCanvas
                  .overlay(alignment: .topLeading)
                  {
                    if showsStatistics, layout.tab != .sculpting { ViewportOverlay(driver: driver) }
                  }
                  .overlay(alignment: .topLeading)
                  {
                    if layout.tab != .sculpting { LayoutToolbar(layout: layout) }
                  }
                  .overlay(alignment: .topTrailing)
                  {
                    if layout.tab != .sculpting { OutlineButton(engine: engine, hydra: hydra).padding(16) }
                  }
                  .overlay
                  {
                    if renderJob.showsResult { RenderResult(job: renderJob) }
                  }
                  .overlay
                  {
                    // the sculpt viewport lies over the scene's, which pauses while it shows
                    if layout.tab == .sculpting
                    {
                      let sculpt = layout.sculpt
                      SculptCanvas(sculpt: sculpt)
                        .overlay(alignment: .topLeading) { SculptInfo(layout: layout) }
                        .overlay(alignment: .topLeading) { SculptToolShelf(layout: layout) }
                    }
                  }
                if layout.tab == .sculpting { SculptShelf(sculpt: layout.sculpt) }
              }
              .area()
            }
            if showsAssets, layout.tab == .assets
            {
              AreaEdge(axis: .horizontal, collapses: "assets", direction: .down)
              { dy in
                assetsHeight = min(max(assetsHeight - dy, -200), Self.timelineMaximum)
                return Self.overshoot(assetsHeight, minimum: Self.assetsMinimum)
              }
              reset: { assetsHeight = Self.assetsDefault }
              ended: { assetsHeight = Self.settled(assetsHeight, minimum: Self.assetsMinimum) }
              let shown = Self.shown(assetsHeight, minimum: Self.assetsMinimum, max: Self.timelineMaximum)
              if shown > 0
              {
                AssetBrowser(layout: layout, shelf: AssetShelf.materials)
                  .frame(height: shown)
                  .area("assets")
              }
            }
            if showsTimeline
            {
              AreaEdge(axis: .horizontal, collapses: "timeline", direction: .down)
              { dy in
                timelineBody = min(max(timelineBody - dy, -200), Self.timelineMaximum)
                return Self.overshoot(timelineBody, minimum: Self.timelineMinimum)
              }
              reset: { timelineBody = Double(TimelineView.rulerHeight) }
              ended: { timelineBody = Self.settled(timelineBody, minimum: Self.timelineMinimum) }
              TimelineView(timeline: timeline, job: renderJob, layout: layout, bodyHeight: timelineShown,
                           editorChanged: { dope in if dope, timelineBody < 160
                           {
                             #if os(macOS)
                              timelineBody = Double(DopeSheetView.height)
                             #else
                              timelineBody = Double(220)
                             #endif
                           }
              })
              { showsPlaybackMenu.toggle() }
              .area("timeline")
            }
          }

          if showsProperties
          {
            AreaEdge(axis: .vertical, collapses: "sidebar", direction: .right)
            { dx in
              sidebarWidth = min(max(sidebarWidth - dx, 0), Self.sidebarMaximum)
              return Self.overshoot(sidebarWidth, minimum: Self.sidebarMinimum)
            }
            reset: { sidebarWidth = Self.sidebarDefault; outlinerHeight = PrimOutliner.height }
            ended: { sidebarWidth = Self.settled(sidebarWidth, minimum: Self.sidebarMinimum) }
            if sidebarShown > 0
            {
              VStack(alignment: .leading, spacing: 0)
              {
                let outliner = outlinerShown
                if outliner > 0
                {
                  PrimOutliner(layout: layout)
                    .frame(width: sidebarShown, height: outliner)
                    .area("outliner")
                }
                AreaEdge(axis: .horizontal, collapses: "outliner", direction: .up)
                { dy in
                  outlinerHeight = min(max(outlinerHeight + dy, -200), Self.outlinerMaximum)
                  return Self.overshoot(outlinerHeight, minimum: Self.outlinerMinimum)
                }
                reset: { outlinerHeight = PrimOutliner.height }
                ended: { outlinerHeight = Self.settled(outlinerHeight, minimum: Self.outlinerMinimum) }
                .frame(width: sidebarShown)
                Group
                {
                  if layout.tab == .sculpting
                  {
                    SculptProperties(layout: layout, width: Int(sidebarShown) - 30)
                  }
                  else
                  {
                    HUD(state: settings, job: renderJob, inspector: layout.inspector, width: Int(sidebarShown) - 30)
                  }
                }
                .frame(width: sidebarShown, alignment: .leading)
                .area()
              }
              .area("sidebar")
            }
          }
        }
        .padding(3)
        .background(Color(white: 0.09))
        .overlay(alignment: .topLeading) { menuLayer }
        .overlay(alignment: .bottomLeading) { playbackMenuLayer }
        .overlay { aboutLayer }
        Rectangle()
          .fill(Color(white: 0.09))
          .frame(height: 1)
        StatusBar(layout: layout)
      }
    }

    private var topBar: some View
    {
      HStack(spacing: TopMenu.spacing)
      {
        if let logo = Self.logo
        {
          Image(logo)
            .resizable()
            .frame(width: 12, height: 18)
            .frame(width: Double(TopMenu.logoWidth), height: Double(26))
        }

        ForEach(TopMenu.allCases, id: \.self)
        { menu in
          MenuTitle(title: menu.rawValue, width: menu.width, open: openMenu == menu)
          {
            openMenu = openMenu == menu ? nil : menu
          }
        }

        Rectangle()
          .fill(Color.clear)
          .frame(width: 12, height: 1)
        ForEach(Kraken.Layout.Tab.allCases, id: \.self)
        { tab in
          WorkspaceTab(title: tab.rawValue, selected: layout.tab == tab) { layout.open(tab) }
        }

        Spacer()
        Text("Scene")
          .font(Properties.font)
          .foregroundColor(Properties.label)
        Text(scene.wrappedValue.name)
          .font(Properties.font)
          .foregroundColor(Properties.text)
          .padding(.horizontal, 8)
          .frame(height: 20)
          .background(RoundedRectangle(cornerRadius: 4).fill(Properties.menu))
        ReloadButton(reload: { renderJob.reloadStage() }, status: { renderJob.reloadStatus })
      }
      .padding(.horizontal, TopMenu.barPadding)
      .frame(height: 28)
      .background(Properties.popup)
    }

    @ViewBuilder
    private var menuLayer: some View
    {
      if let menu = openMenu
      {
        ZStack(alignment: .topLeading)
        {
          Rectangle()
            .fill(Color.clear)
            .onTapGesture { openMenu = nil }
          MenuList(entries: entries(for: menu)) { openMenu = nil }
            .padding(.leading, menu.x)
        }
      }
    }
    
    private var layoutOverlay: some View
    {
      LayoutOverlay(layout: layout,
                    isPicking: { [settings] in settings.pickingFocus },
                    isMenuOpen: { openMenu != nil || showsPlaybackMenu },
                    toggleCamera: { [renderJob] in renderJob.toggleCameraView() })
    }

    /// the playback menu opens just above the timeline's header.
    private var playbackMenuInset: Double
    {
      Double(TimelineView.headerHeight) + timelineShown - 4
    }

    @ViewBuilder
    private var playbackMenuLayer: some View
    {
      if showsPlaybackMenu
      {
        ZStack(alignment: .bottomLeading)
        {
          Rectangle()
            .fill(Color.clear)
            .onTapGesture { showsPlaybackMenu = false }
          MenuList(entries: [
            MenuEntry(title: "Mute Audio", checked: timeline.playback.isMuted)
            {
              timeline.playback.isMuted.toggle()
            },
          ]) { showsPlaybackMenu = false }
            .padding(.leading, 6)
            .padding(.bottom, Int(playbackMenuInset))
        }
      }
    }

    @ViewBuilder
    var aboutLayer: some View
    {
      if showsAbout
      {
        ZStack
        {
          Rectangle()
            .fill(Color(white: 0, opacity: 0.35))
            .onTapGesture { showsAbout = false }
          VStack(spacing: 6)
          {
            if let logo = Self.logo
            {
              Image(logo)
                .resizable()
                .frame(width: 32, height: 48)
            }

            Text("Kraken ∙ Akari 灯り")
              .font(.system(size: 14, weight: .semibold))
              .foregroundColor(Properties.text)
            Text("v\(Akari.version)")
              .font(Properties.font)
              .foregroundColor(Properties.label)
            Text("© 2026 Wabi Foundation")
              .font(.system(size: 10))
              .foregroundColor(Color(white: 0.55))
          }
          .padding(24)
          .background(RoundedRectangle(cornerRadius: 6).fill(Properties.panel))
          .onTapGesture { showsAbout = false }
        }
      }
    }

    func entries(for menu: TopMenu) -> [MenuEntry]
    {
      switch menu
      {
        case .file:
          let layout = layout
          var entries = [MenuEntry(title: "New", shortcut: "⌘N") { layout.newScene() },
                         MenuEntry(title: "Open…", shortcut: "⌘O") { layout.openScene() },
                         MenuEntry.separator,
                         MenuEntry(title: "Save", shortcut: "⌘S") { layout.save() }]
          #if os(macOS)
            entries.append(MenuEntry(title: "Save As…", shortcut: "⇧⌘S") { layout.askSaveAs() })
            entries.append(MenuEntry.separator)
            entries.append(MenuEntry(title: "Run Script…") { Kraken.ScriptHost.choose(layout: layout) })
          #endif
          return entries + [MenuEntry.separator, MenuEntry(title: "Quit Akari", shortcut: "⌘Q") { Self.quit() }]
        case .edit:
          let layout = layout
          return [MenuEntry(title: "Undo", shortcut: "⌘Z") { layout.undo() },
                  MenuEntry(title: "Redo", shortcut: "⇧⌘Z") { layout.redo() }]
        case .render:
          let settings = settings
          let renderJob = renderJob
          let renders: [MenuEntry] = [
            MenuEntry(title: "Render Image", shortcut: "F12") { renderJob.renderImage() },
            MenuEntry(title: "Render Animation", shortcut: "⌃F12") { renderJob.renderAnimation() },
            MenuEntry(title: "View Render", shortcut: "F11", checked: renderJob.showsResult) { renderJob.toggleResult() },
            MenuEntry.separator,
          ]
          let qualities: [MenuEntry] = RenderQuality.allCases.map
          { q in
            MenuEntry(title: "\(q) Quality", checked: settings.current.quality == q)
            {
              settings.applyPreset(q)
            }
          }

          let upscalers: [MenuEntry] = Upscaler.allCases.map
          { u in
            MenuEntry(title: "\(u) Upscaler", checked: settings.current.upscaler == u)
            {
              settings.edit { $0.upscaler = u }
            }
          }

          return renders + qualities + [MenuEntry.separator] + upscalers
        case .view:
          return [
            MenuEntry(title: "Camera", shortcut: "Numpad 0", checked: renderJob.lookingThrough)
            {
              renderJob.toggleCameraView()
            },
            MenuEntry.separator,
            MenuEntry(title: "Properties", checked: showsProperties) { showsProperties.toggle() },
            MenuEntry(title: "Timeline", checked: showsTimeline) { showsTimeline.toggle() },
            MenuEntry(title: "Object Assets", checked: showsObjects)
            {
              showsObjects.toggle()
              if showsObjects, objectsWidth < Self.objectsMinimum { objectsWidth = Self.objectsDefault }
            },
            MenuEntry(title: "Material Assets", checked: showsAssets)
            {
              showsAssets.toggle()
              if showsAssets, assetsHeight < Self.assetsMinimum { assetsHeight = Self.assetsDefault }
            },
            MenuEntry(title: "Statistics", checked: showsStatistics) { showsStatistics.toggle() },
          ]
        case .help:
          return [MenuEntry(title: "About Akari") { showsAbout = true }]
      }
    }

    private static func quit()
    {
      #if os(macOS)
        NSApplication.shared.terminate(nil)
      #endif
    }

    static let logo: URL? = Bundle.akari.url(forResource: "WabiLogo", withExtension: "png")
  }

  /// the top bar's menus.
  enum TopMenu: String, CaseIterable
  {
    case file = "File"
    case edit = "Edit"
    case render = "Render"
    case view = "View"
    case help = "Help"

    static let barPadding = 8
    static let logoWidth = 28
    static let spacing = 2

    var width: Int
    {
      switch self
      {
        case .file: 38
        case .edit: 38
        case .render: 54
        case .view: 42
        case .help: 42
      }
    }

    /// where its dropdown opens, under its title.
    var x: Int
    {
      Self.allCases.prefix { $0 != self }
        .reduce(Self.barPadding + Self.logoWidth + Self.spacing) { $0 + $1.width + Self.spacing }
    }
  }

  @MainActor
  struct MenuTitle: View
  {
    let title: String
    let width: Int
    let open: Bool
    let tap: () -> Void

    @State var hovered = false

    init(title: String, width: Int, open: Bool, tap: @escaping () -> Void)
    {
      self.title = title
      self.width = width
      self.open = open
      self.tap = tap
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        Text(title)
          .font(Properties.font)
          .foregroundColor(Properties.text)
          .frame(width: Double(width), height: Double(22))
          .background(RoundedRectangle(cornerRadius: 4)
            .fill(open || hovered ? Color(white: 0.28) : Color.clear))
          .onHover { hovered = $0 }
          .onTapGesture { tap() }
      }
    }
  }

  /// a workspace tab along the top bar: layout, modeling, shading or sculpting.
  @MainActor
  struct WorkspaceTab: View
  {
    let title: String
    let selected: Bool
    let tap: () -> Void

    @State var hovered = false

    init(title: String, selected: Bool, tap: @escaping () -> Void)
    {
      self.title = title
      self.selected = selected
      self.tap = tap
    }

    var body: some View
    {
      Text(title)
        .font(Properties.font)
        .foregroundColor(selected ? Properties.text : Properties.label)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4)
          .fill(selected ? Color(white: 0.24) : hovered ? Color(white: 0.18) : Color.clear))
        .onHover { hovered = $0 }
        .onTapGesture { tap() }
    }
  }

  /// a dropdown of menu entries, each closing it once it runs
  @MainActor
  struct MenuList: View
  {
    let entries: [MenuEntry]
    let dismiss: () -> Void

    init(entries: [MenuEntry], dismiss: @escaping () -> Void)
    {
      self.entries = entries
      self.dismiss = dismiss
    }

    var body: some View
    {
      VStack(alignment: .leading, spacing: 0)
      {
        ForEach(Array(entries.indices), id: \.self)
        { i in
          MenuRow(entry: entries[i], dismiss: dismiss)
        }
      }
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 5).fill(Properties.popup))
    }
  }

  @MainActor
  struct MenuRow: View
  {
    let entry: MenuEntry
    let dismiss: () -> Void

    @State var hovered = false

    private static let width = 200

    init(entry: MenuEntry, dismiss: @escaping () -> Void)
    {
      self.entry = entry
      self.dismiss = dismiss
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        if entry.isSeparator
        {
          Rectangle()
            .fill(Color(white: 0.24))
            .frame(width: Double(Self.width - 12), height: Double(1))
            .padding(.vertical, 4)
        }
        else
        {
          HStack(spacing: 6)
          {
            VStack(spacing: 0)
            {
              if entry.checked == true
              {
                CheckMark()
                  .stroke(Properties.text, style: StrokeStyle(width: 1.4))
                  .frame(width: 8, height: 7)
              }
            }
            .frame(width: 12)
            Text(entry.title)
              .font(Properties.font)
              .foregroundColor(Properties.text)
              .frame(minWidth: 0.0, maxWidth: .infinity, alignment: .leading)
            Text(entry.shortcutText)
              .font(Properties.font)
              .foregroundColor(Color(white: 0.55))
          }
          .padding(.horizontal, 6)
          .frame(width: Double(Self.width), height: Double(22))
          .background(RoundedRectangle(cornerRadius: 3).fill(hovered ? Properties.accent : Color.clear))
          .onHover { hovered = $0 }
          .onTapGesture
          {
            entry.action()
            dismiss()
          }
        }
      }
    }
  }
}
