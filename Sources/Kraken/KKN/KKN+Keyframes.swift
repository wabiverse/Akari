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
import HdAkari
import HydraKit
import SwiftCrossUI
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension Kraken
{
  /// Something that can be keyed, either a prim attribute or a prim's whole transform.
  struct KeyTarget: Hashable, Sendable
  {
    static let transform = "~transform"

    var path: String
    var name: String

    var id: String
    {
      path + "." + name
    }

    var isTransform: Bool
    {
      name == Self.transform
    }
  }

  /// Whether a property is animated, and whether it has a key on the current frame.
  enum KeyState: Comparable
  {
    case none, animated, keyed
  }

  /// Keyframe editing. With the pointer over a property, I inserts a key at the current frame,
  /// Alt-I deletes it and Shift-Alt-I clears all of them. Right click shows the same in a menu.
  ///
  /// Editing an animated property without keying it only lasts until the frame changes,
  /// unless Auto Keying is on.
  @MainActor
  final class Keyframes: ObservableObject
  {
    @Published var autoKey = false
    /// Bumped after every key edit so views showing keys reload them.
    @Published var revision = 0
    /// The keyable field under the pointer, set by the native number and color fields on hover.
    static var hovered: KeyTarget?

    weak var layout: Layout?
    weak var timeline: Timeline?
    /// Unkeyed edits to animated properties, held in the session layer until the frame changes.
    private var held = Set<KeyTarget>()
    private var frame = Double.nan
    private var lastReload = Date.distantPast
    #if os(macOS)
      private var monitor: Any?
    #endif

    init(layout: Layout)
    {
      self.layout = layout
      #if os(macOS)
        install()
      #endif
    }

    var time: Double
    {
      layout?.hydra.currentTimeCode ?? 0
    }

    // MARK: Keys

    func insert(_ target: KeyTarget)
    {
      held.remove(target)
      edit("Inserted Keyframe")
      { stage, time in
        target.isTransform ? SceneEdit.keyTransform(stage, target.path, time)
          : SceneEdit.insertKey(stage, target.path, target.name, time)
      }
    }

    func delete(_ target: KeyTarget)
    {
      held.remove(target)
      edit("Deleted Keyframe")
      { stage, time in
        target.isTransform ? SceneEdit.deleteTransformKey(stage, target.path, time)
          : SceneEdit.deleteKey(stage, target.path, target.name, time)
      }
    }

    func clear(_ target: KeyTarget)
    {
      held.remove(target)
      edit("Cleared Keyframes")
      { stage, time in
        target.isTransform ? SceneEdit.clearTransformKeys(stage, target.path, time)
          : SceneEdit.clearKeys(stage, target.path, target.name, time)
      }
    }

    /// Inserts a key on the current frame, or deletes the one already there.
    func toggle(_ target: KeyTarget, keyed: Bool)
    {
      keyed ? delete(target) : insert(target)
    }

    /// Keys the transforms of `paths` (I in the viewport).
    func insertTransforms(_ paths: [String])
    {
      guard !paths.isEmpty else { return }
      for path in paths { held.remove(KeyTarget(path: path, name: KeyTarget.transform)) }
      edit("Inserted Keyframe")
      { stage, time in
        paths.reduce(false) { SceneEdit.keyTransform(stage, $1, time) || $0 }
      }
    }

    /// Deletes the transform keys of `paths` on the current frame (Alt-I in the viewport).
    func deleteTransforms(_ paths: [String])
    {
      guard !paths.isEmpty else { return }
      edit("Deleted Keyframe")
      { stage, time in
        paths.reduce(false) { SceneEdit.deleteTransformKey(stage, $1, time) || $0 }
      }
    }

    /// Runs an undoable key edit on the frame queue, then refreshes everything that shows keys.
    func edit(_ status: String, _ work: @escaping @Sendable (UsdStage, Double) -> Bool)
    {
      guard let layout else { return }
      layout.checkpoint()
      let time = time
      layout.onStage
      { [weak self] stage in
        let done = work(stage, time)
        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          self.layout?.status = done ? status : "Nothing to key"
          self.changed(reload: true)
        }
      }
    }

    func changed(reload: Bool)
    {
      revision += 1
      if reload { layout?.inspector.reload() }
      layout?.refresh()
    }

    // MARK: Edits

    /// Handles an inspector edit to an animated property, or any property while Auto Keying is on.
    /// Returns false when the inspector should write the value itself.
    func write(_ path: String, _ name: Tf.Token, _ numbers: [Double], type: Sdf.ValueTypeNameType, animated: Bool) -> Bool
    {
      guard animated || autoKey, let layout else { return false }
      let auto = autoKey, time = time
      if !auto { held.insert(KeyTarget(path: path, name: name.string)) }
      layout.onStage
      { [weak self] stage in
        if animated { SceneEdit.setSessionValue(stage, path, name, numbers) }
        else { SceneEdit.setValue(stage, path, name, numbers, type: Sdf.getValueType(for: type)) }
        if auto { SceneEdit.insertKey(stage, path, name.string, time) }
        DispatchQueue.main.async { [weak self] in self?.changed(reload: auto) }
      }

      return true
    }

    /// Drops unkeyed edits when the frame changes and reloads the inspector, only its animated values while playing.
    func frameChanged(playing: Bool)
    {
      let now = time
      guard now != frame else { return }
      frame = now
      let releases = !held.isEmpty
      let attributes = held.filter { !$0.isTransform }
      held.removeAll()
      // While playing, only the animated values are reread, for the keyed fields to show live.
      if playing, !releases
      {
        layout?.inspector.reloadAnimated()
        return
      }

      lastReload = Date()
      layout?.onStage
      { [weak self] stage in
        for target in attributes { SceneEdit.clearSessionValue(stage, target.path, target.name) }
        let moved = SceneEdit.releaseTransforms(stage)
        DispatchQueue.main.async
        { [weak self] in
          self?.layout?.inspector.reload()
          if !moved.isEmpty { self?.layout?.refresh() }
        }
      }
    }

    /// Moves to the selection's next or previous keyed frame.
    func jumpToKey(forward: Bool)
    {
      guard let layout else { return }
      let paths = layout.selection, now = time
      layout.onStage
      { [weak self] stage in
        let times = Set(SceneEdit.channels(stage, paths).flatMap(\.times)).sorted()
        let next = forward ? times.first { $0 > now + 1e-6 } : times.last { $0 < now - 1e-6 }
        DispatchQueue.main.async
        { [weak self] in
          guard let next else { self?.layout?.status = "No more keyframes"; return }
          self?.timeline?.seek(to: Int(next.rounded()))
        }
      }
    }

    #if os(macOS)
      // MARK: Hotkeys

      private func install()
      {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown])
        { [weak self] event in
          let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
          return consumed ? nil : event
        }
      }

      private func handle(_ event: NSEvent) -> Bool
      {
        guard !(event.window?.firstResponder is NSText) else { return false }
        // Left and right step one frame, up and down jump between keys.
        if event.type == .keyDown, event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
           (123 ... 126).contains(event.keyCode)
        {
          switch event.keyCode
          {
            case 123, 124: timeline?.step(by: event.keyCode == 124 ? 1 : -1)
            default: jumpToKey(forward: event.keyCode == 126)
          }
          return true
        }

        guard let target = Self.hovered else { return false }
        switch event.type
        {
          case .keyDown:
            guard event.keyCode == 34 else { return false }
            let flags = event.modifierFlags.intersection([.option, .shift, .command, .control])
            if flags.isEmpty { insert(target) }
            else if flags == .option { delete(target) }
            else if flags == [.option, .shift] { clear(target) }
            else { return false }
            return true
          case .rightMouseDown:
            menu(for: target, event)
            return true
          default:
            return false
        }
      }

      private func menu(for target: KeyTarget, _ event: NSEvent)
      {
        let menu = NSMenu()
        func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags, _ run: @escaping @MainActor () -> Void)
        {
          let action = MenuAction(run)
          let entry = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
          entry.keyEquivalentModifierMask = modifiers
          entry.target = action
          entry.representedObject = action
          menu.addItem(entry)
        }

        item("Insert Keyframe", "i", []) { [weak self] in self?.insert(target) }
        item("Delete Keyframe", "i", .option) { [weak self] in self?.delete(target) }
        item("Clear Keyframes", "i", [.option, .shift]) { [weak self] in self?.clear(target) }
        guard let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
      }
    #endif
  }

  #if os(macOS)
    /// The target of a menu item, retained by the item.
    @MainActor
    final class MenuAction: NSObject
    {
      let run: @MainActor () -> Void

      init(_ run: @escaping @MainActor () -> Void)
      {
        self.run = run
      }

      @objc func fire()
      {
        run()
      }
    }
  #endif

  /// The key decorator shape, a diamond or a dot for properties that aren't animated.
  struct KeyDiamond: Shape
  {
    var dot = false

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let c = bounds.center
      let r = (dot ? 0.18 : 0.42) * min(bounds.width, bounds.height)
      return Path()
        .move(to: SIMD2(c.x, c.y - r))
        .addLine(to: SIMD2(c.x + r, c.y))
        .addLine(to: SIMD2(c.x, c.y + r))
        .addLine(to: SIMD2(c.x - r, c.y))
        .addLine(to: SIMD2(c.x, c.y - r))
    }
  }

  /// A property row with a key decorator. The decorator is yellow on a keyed frame, green between keys,
  /// and a dot when the property isn't animated. Clicking it inserts or deletes the key.
  @MainActor
  struct KeyedRow<Control: View>: View
  {
    let label: String
    let target: KeyTarget?
    @State private var inspector: Inspector
    let control: Control

    init(_ label: String, _ target: KeyTarget?, inspector: Inspector, @ViewBuilder control: () -> Control)
    {
      self.label = label
      self.target = target
      _inspector = State(wrappedValue: inspector)
      self.control = control()
    }

    static var keyed: Color { Color(red: 0.87, green: 0.76, blue: 0.24) }
    static var animated: Color { Color(red: 0.42, green: 0.74, blue: 0.40) }

    var body: some View
    {
      let state = target.map { inspector.keyState($0) } ?? .none
      HStack(spacing: 4)
      {
        Properties.row(label) { control }
        if let target
        {
          Group
          {
            switch state
            {
              case .keyed: KeyDiamond().fill(Self.keyed)
              case .animated: KeyDiamond().fill(Self.animated)
              case .none: KeyDiamond(dot: true).fill(Properties.label)
            }
          }
          .frame(width: 14, height: 14)
          .onTapGesture { inspector.keyframes?.toggle(target, keyed: state == .keyed) }
        }
      }
    }
  }

}
