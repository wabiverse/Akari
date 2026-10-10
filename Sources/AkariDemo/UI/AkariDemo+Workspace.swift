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

extension AkariDemo
{
  /// The window's layout.
  @MainActor
  struct Workspace: View
  {
    let engine: Akari.RenderEngine
    let hydra: Hydra.RenderEngine
    let driver: any Akari.HydraFrameDriver
    let sceneName: String

    @State private var settings: AkariDemo.HUDState
    @State private var openMenu: TopMenu?
    @State private var showsProperties = true
    @State private var showsStatistics = true
    @State private var showsAbout = false

    init(engine: Akari.RenderEngine,
         hydra: Hydra.RenderEngine,
         driver: any Akari.HydraFrameDriver,
         settings: AkariDemo.HUDState,
         sceneName: String)
    {
      self.engine = engine
      self.hydra = hydra
      self.driver = driver
      self.sceneName = sceneName
      _settings = State(wrappedValue: settings)
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        topBar
        Rectangle()
          .fill(Color(white: 0.09))
          .frame(height: 1)
        HStack(spacing: 0)
        {
          Hydra.Viewport(engine: hydra)
            .frame(minWidth: 560, minHeight: 600)
            .overlay(alignment: .topLeading)
            {
              if showsStatistics { ViewportOverlay(driver: driver) }
            }
            .overlay(alignment: .topTrailing) { OutlineButton(engine: engine, hydra: hydra).padding(16) }
          if showsProperties
          {
            Rectangle()
              .fill(Color(white: 0.09))
              .frame(width: 1)
            HUD(state: settings)
          }
        }
        .overlay(alignment: .topLeading) { menuLayer }
        .overlay { aboutLayer }
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
        Spacer()
        Text("Scene")
          .font(Properties.font)
          .foregroundColor(Properties.label)
        Text(sceneName)
          .font(Properties.font)
          .foregroundColor(Properties.text)
          .padding(.horizontal, 8)
          .frame(height: 20)
          .background(RoundedRectangle(cornerRadius: 4).fill(Properties.menu))
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

    @ViewBuilder
    private var aboutLayer: some View
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

    private func entries(for menu: TopMenu) -> [MenuEntry]
    {
      switch menu
      {
        case .file:
          return [MenuEntry(title: "Quit Akari", shortcut: "⌘Q") { Self.quit() }]
        case .render:
          let settings = settings
          let qualities: [MenuEntry] = RenderQuality.allCases.map
          { q in
            MenuEntry(title: "\(q) Quality", checked: settings.quality == q)
            {
              settings.applyPreset(q)
              settings.apply()
            }
          }
          let upscalers: [MenuEntry] = Upscaler.allCases.map
          { u in
            MenuEntry(title: "\(u) Upscaler", checked: settings.upscaler == u)
            {
              settings.upscaler = u
              settings.apply()
            }
          }
          return qualities + [MenuEntry.separator] + upscalers
        case .view:
          return [
            MenuEntry(title: "Properties", checked: showsProperties) { showsProperties.toggle() },
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

  /// The top bar's menus.
  enum TopMenu: String, CaseIterable
  {
    case file = "File"
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
        case .render: 54
        case .view: 42
        case .help: 42
      }
    }

    /// Where its dropdown opens, under its title.
    var x: Int
    {
      Self.allCases.prefix { $0 != self }
        .reduce(Self.barPadding + Self.logoWidth + Self.spacing) { $0 + $1.width + Self.spacing }
    }
  }

  struct MenuEntry
  {
    var title = ""
    var shortcut = ""
    var checked: Bool?
    var isSeparator = false
    var action: () -> Void = {}

    static var separator: MenuEntry
    {
      MenuEntry(isSeparator: true)
    }

    init(title: String = "", shortcut: String = "", checked: Bool? = nil, isSeparator: Bool = false,
         action: @escaping () -> Void = {})
    {
      self.title = title
      self.shortcut = shortcut
      self.checked = checked
      self.isSeparator = isSeparator
      self.action = action
    }
  }

  @MainActor
  struct MenuTitle: View
  {
    let title: String
    let width: Int
    let open: Bool
    let tap: () -> Void

    @State private var hovered = false

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

  /// A dropdown of menu entries,
  /// each closing it once it runs.
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

    @State private var hovered = false

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
            Text(entry.shortcut)
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
