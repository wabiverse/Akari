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
#else
  import UIKit
#endif

extension Kraken
{
  /// a menu command, described once and shown by whichever menu fits the platform and the place.
  struct MenuEntry
  {
    /// a key a command answers to, shown beside it.
    struct Key
    {
      struct Modifiers: OptionSet
      {
        let rawValue: Int

        static let shift = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
      }

      var character: String
      var modifiers: Modifiers = []

      var display: String
      {
        let marks = [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { modifiers.contains($0.0) }.map(\.1).joined() + character.uppercased()
      }
    }

    var title = ""
    var shortcut = ""
    var key: Key?
    var checked: Bool?
    var isSeparator = false
    var isHeader = false
    var children: [MenuEntry] = []
    var action: () -> Void = {}
    /// a system symbol shown beside the title, empty for none
    var symbol = ""

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

    /// a command with the key it answers to, empty for none.
    init(_ title: String, _ character: String = "", _ modifiers: Key.Modifiers = [], action: @escaping () -> Void)
    {
      self.title = title
      key = character.isEmpty ? nil : Key(character: character, modifiers: modifiers)
      self.action = action
    }

    /// a title over the commands that follow, not a command itself.
    static func header(_ title: String) -> MenuEntry
    {
      var entry = MenuEntry(title: title)
      entry.isHeader = true
      return entry
    }

    static func submenu(_ title: String, _ children: [MenuEntry]) -> MenuEntry
    {
      var entry = MenuEntry(title: title)
      entry.children = children
      return entry
    }

    var isSubmenu: Bool { !children.isEmpty }

    /// the shortcut as shown beside the title.
    var shortcutText: String
    {
      shortcut.isEmpty ? key?.display ?? "" : shortcut
    }
  }
}

#if os(macOS)
  extension Kraken
  {
    /// a menu item that runs a closure, retained by the item.
    final class MenuAction: NSMenuItem
    {
      private let run: () -> Void

      init(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], run: @escaping () -> Void)
      {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
      }

      @available(*, unavailable)
      required init(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      @objc private func fire()
      {
        run()
      }
    }
  }

  extension Kraken.MenuEntry
  {
    private var modifierFlags: NSEvent.ModifierFlags
    {
      var flags: NSEvent.ModifierFlags = []
      let modifiers = key?.modifiers ?? []
      if modifiers.contains(.shift) { flags.insert(.shift) }
      if modifiers.contains(.option) { flags.insert(.option) }
      if modifiers.contains(.control) { flags.insert(.control) }
      if modifiers.contains(.command) { flags.insert(.command) }
      return flags
    }

    var menuItem: NSMenuItem
    {
      if isSeparator { return .separator() }
      if isHeader
      {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
      }

      if isSubmenu
      {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = Self.menu(children, title: title)
        return item
      }

      let item = Kraken.MenuAction(title, key?.character ?? "", modifierFlags, run: action)
      item.state = checked == true ? .on : .off
      if !symbol.isEmpty { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
      return item
    }

    static func menu(_ entries: [Kraken.MenuEntry], title: String = "") -> NSMenu
    {
      let menu = NSMenu(title: title)
      menu.autoenablesItems = false
      entries.forEach { menu.addItem($0.menuItem) }
      return menu
    }
  }
#else
  @MainActor
  extension Kraken.MenuEntry
  {
    /// the entries as a UIKit menu, headers start a titled inline section.
    static func menu(_ entries: [Kraken.MenuEntry], title: String = "") -> UIMenu
    {
      var sections: [(title: String, items: [UIMenuElement])] = [("", [])]
      for entry in entries
      {
        if entry.isHeader { sections.append((entry.title, [])) }
        else if entry.isSeparator { sections.append(("", [])) }
        else if let element = entry.menuElement { sections[sections.count - 1].items.append(element) }
      }

      let groups = sections.filter { !$0.items.isEmpty }
      guard groups.count > 1 else { return UIMenu(title: title, children: groups.first?.items ?? []) }
      return UIMenu(title: title, children: groups.map { UIMenu(title: $0.title, options: .displayInline, children: $0.items) })
    }

    private var menuElement: UIMenuElement?
    {
      if isSubmenu { return Self.menu(children, title: title) }

      // menus are only built and picked on the main thread.
      nonisolated(unsafe) let run = action
      return UIAction(title: title, image: symbol.isEmpty ? nil : UIImage(systemName: symbol), state: checked == true ? .on : .off) { _ in run() }
    }

    /// shows the entries from a point in `view`, a popover sheet that steps into submenus.
    static func present(_ entries: [Kraken.MenuEntry], from view: UIView, at point: CGPoint, title: String? = nil)
    {
      guard let presenter = view.window?.rootViewController?.topmostPresented else { return }
      let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
      for entry in entries where !entry.isSeparator && !entry.isHeader
      {
        let mark = entry.checked == true ? "✓ " : ""
        sheet.addAction(UIAlertAction(title: mark + entry.title + (entry.isSubmenu ? " ›" : ""), style: .default)
        { _ in
          if entry.isSubmenu { present(entry.children, from: view, at: point, title: entry.title) }
          else { entry.action() }
        })
      }

      sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      sheet.popoverPresentationController?.sourceView = view
      sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: .zero)
      presenter.present(sheet, animated: true)
    }
  }

  extension UIViewController
  {
    /// the controller on top of everything this one presents, passing over one on its way out.
    var topmostPresented: UIViewController
    {
      guard let presented = presentedViewController, !presented.isBeingDismissed else { return self }
      return presented.topmostPresented
    }
  }
#endif

extension Kraken
{
  /// an icon button that opens a native menu of entries read fresh each time it opens
  @MainActor
  struct MenuButton: View
  {
    /// the icon and title are read on each update, values captured when the button was made would show forever
    let symbol: @MainActor () -> String
    let title: @MainActor () -> String
    var size = FormFactor.hitTarget
    var clear = false
    let entries: @MainActor () -> [MenuEntry]

    init(symbol: @autoclosure @escaping @MainActor () -> String = "", title: @autoclosure @escaping @MainActor () -> String = "",
         size: Double = FormFactor.hitTarget, clear: Bool = false, entries: @escaping @MainActor () -> [MenuEntry])
    {
      self.symbol = symbol
      self.title = title
      self.size = size
      self.clear = clear
      self.entries = entries
    }

    /// wide enough for the icon and the title beside it, with a little room either side.
    var width: Double
    {
      Self.width(title: title(), size: size)
    }

    static func width(title: String, size: Double) -> Double
    {
      guard !title.isEmpty else { return size }
      let text = (title as NSString).size(withAttributes: [.font: PlatformFont.systemFont(ofSize: 14, weight: .semibold)])
      return (size + Double(text.width) + 14).rounded(.up)
    }

    var body: some View
    {
      NativeView(make: { MenuButtonView() },
                 update: { [symbol, title, size, clear, entries] view in
                   view.configure(symbol: symbol(), title: title(), corner: clear ? 0 : size * 0.3, entries: entries)
                 },
                 size: { [title, size] _ in ViewSize(Self.width(title: title(), size: size), size) })
    }
  }

  #if os(macOS)
    final class MenuButtonView: NSButton
    {
      private var entries: @MainActor () -> [MenuEntry] = { [] }

      func configure(symbol: String, title: String, corner: Double, entries: @escaping @MainActor () -> [MenuEntry])
      {
        self.entries = entries
        image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        self.title = title
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        bezelStyle = .regularSquare
        isBordered = false
        contentTintColor = NSColor(white: 0.9, alpha: 1)
        target = self
        action = #selector(open)
      }

      @objc private func open()
      {
        Kraken.MenuEntry.menu(entries()).popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height + 4), in: self)
      }
    }
  #else
    final class MenuButtonView: UIButton
    {
      private var entries: @MainActor () -> [MenuEntry] = { [] }
      private var shown: (symbol: String, title: String, corner: Double)?

      func configure(symbol: String, title: String, corner: Double, entries: @escaping @MainActor () -> [MenuEntry])
      {
        self.entries = entries
        guard shown?.symbol != symbol || shown?.title != title || shown?.corner != corner else { return }
        shown = (symbol, title, corner)
        var config = UIButton.Configuration.plain()
        if !symbol.isEmpty
        {
          config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        }

        config.title = title.isEmpty ? nil : title
        config.imagePadding = 6
        config.baseForegroundColor = UIColor(white: 0.9, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        config.background.backgroundColor = corner > 0 ? UIColor(white: 0.16, alpha: 0.94) : .clear
        config.background.cornerRadius = corner
        config.cornerStyle = .fixed
        config.titleLineBreakMode = .byClipping
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer
        { attributes in
          var attributes = attributes
          attributes.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
          return attributes
        }
        configuration = config
        showsMenuAsPrimaryAction = true
        menu = UIMenu(children: [UIDeferredMenuElement.uncached
          { [weak self] done in
            MainActor.assumeIsolated
            {
              done(self.map { Kraken.MenuEntry.menu($0.entries()).children } ?? [])
            }
          }])
      }
    }
  #endif
}
