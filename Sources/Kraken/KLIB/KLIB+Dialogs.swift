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
import UniformTypeIdentifiers
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

extension Kraken
{
  /// the open, save and confirm dialogs scenes need, the native kind on each platform.
  @MainActor
  enum Dialogs
  {
    static let sceneTypes = ["usd", "usda", "usdc", "usdz"].compactMap { UTType(filenameExtension: $0) }
    static let writableTypes = ["usda", "usd", "usdc"].compactMap { UTType(filenameExtension: $0) }

    enum Choice
    {
      case save, discard, cancel
    }

    /// asks whether to save edits before they'd be lost.
    static func confirmDiscard(_ name: String, then answer: @escaping @MainActor (Choice) -> Void)
    {
      let message = "Save changes to \(name) before closing?"
      #if os(macOS)
        // the prompt can come from a scene opened in the finder, kraken has to be in front for it to be seen
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal()
        {
          case .alertFirstButtonReturn: answer(.save)
          case .alertSecondButtonReturn: answer(.discard)
          default: answer(.cancel)
        }
      #else
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in answer(.save) })
        alert.addAction(UIAlertAction(title: "Don't Save", style: .destructive) { _ in answer(.discard) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(.cancel) })
        present(alert)
      #endif
    }

    /// picks a scene to open, on ios a folder too so the scene's layers and textures open with it
    static func openScene(near folder: URL?, then open: @escaping @MainActor (URL) -> Void)
    {
      #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = sceneTypes
        panel.allowsMultipleSelection = false
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
      #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: sceneTypes + [.folder], asCopy: false)
        picker.directoryURL = folder
        Picker.shared.run(picker)
        { url in
          Access.hold(url)
          guard url.hasDirectoryPath else { return askForFolder(of: url, then: open) }
          let scenes = Access.scenes(in: url)
          switch scenes.count
          {
            case 0: alert("No USD scenes in \(url.lastPathComponent)")
            case 1: open(scenes[0])
            default: chooseScene(scenes, then: open)
          }
        }
      #endif
    }

    /// opens a scene handed over by the files app or another app, asking for its folder the way a picked one does
    static func openHanded(_ url: URL, then open: @escaping @MainActor (URL) -> Void)
    {
      #if os(macOS)
        open(url)
      #else
        Access.hold(url)
        askForFolder(of: url, then: open)
      #endif
    }

    /// picks an image to sculpt and paint from
    static func openImage(then open: @escaping @MainActor (URL) -> Void)
    {
      #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
      #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        Picker.shared.run(picker) { url in open(url) }
      #endif
    }

    /// picks where to save a new scene, ios keeps new scenes in the app's documents
    static func saveScene(named name: String, near folder: URL?, then save: @escaping @MainActor (URL) -> Void)
    {
      #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = writableTypes
        panel.nameFieldStringValue = name
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(url)
      #else
        let documents = URL.documentsDirectory
        let base = (name as NSString).deletingPathExtension
        var url = documents.appendingPathComponent(base + ".usda")
        var copy = 1
        while FileManager.default.fileExists(atPath: url.path)
        {
          copy += 1
          url = documents.appendingPathComponent("\(base) \(copy).usda")
        }

        save(url)
      #endif
    }

    #if !os(macOS)
      /// the window kraken shows in.
      static var window: UIWindow?
      {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
      }

      /// shows a controller over whatever is on screen.
      static func present(_ controller: UIViewController)
      {
        guard let root = window?.rootViewController else { return }
        let top = root.topmostPresented

        // the picker is still leaving when it hands back a pick and uikit drops what's presented over it, so this waits
        if let leaving = top.presentedViewController, leaving.isBeingDismissed, let coordinator = leaving.transitionCoordinator
        {
          coordinator.animate(alongsideTransition: nil) { _ in MainActor.assumeIsolated { present(controller) } }
          return
        }

        top.present(controller, animated: true)
      }

      static func alert(_ title: String)
      {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
      }

      /// asks for a scene's folder first so the layers it references can be read, unless it is a usdz or the folder is readable
      private static func askForFolder(of url: URL, then open: @escaping @MainActor (URL) -> Void)
      {
        let folder = url.deletingLastPathComponent()
        guard url.pathExtension.lowercased() != "usdz", !Access.readable(folder) else { return open(url) }

        let alert = UIAlertController(title: "Open the scene's folder?",
                                      message: "\(url.lastPathComponent) can only bring in the files it references once Kraken can read \(folder.lastPathComponent).",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Choose Folder", style: .default)
        { _ in
          let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
          picker.directoryURL = folder
          Picker.shared.run(picker, cancelled: { open(url) })
          { picked in
            Access.hold(picked, keeping: true)
            let inside = picked.appendingPathComponent(url.lastPathComponent)
            open(FileManager.default.fileExists(atPath: inside.path) ? inside : url)
          }
        })
        alert.addAction(UIAlertAction(title: "Open Alone", style: .cancel) { _ in open(url) })
        present(alert)
      }

      private static func chooseScene(_ scenes: [URL], then open: @escaping @MainActor (URL) -> Void)
      {
        let sheet = UIAlertController(title: "Open Scene", message: nil, preferredStyle: .actionSheet)
        for scene in scenes
        {
          sheet.addAction(UIAlertAction(title: scene.lastPathComponent, style: .default) { _ in open(scene) })
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sheet.view
        present(sheet)
      }

      /// keeps the document picker's delegate alive while it's up.
      private final class Picker: NSObject, UIDocumentPickerDelegate
      {
        static let shared = Picker()
        private var picked: (@MainActor (URL) -> Void)?
        private var cancelled: (@MainActor () -> Void)?

        func run(_ picker: UIDocumentPickerViewController, cancelled: (@MainActor () -> Void)? = nil,
                 then picked: @escaping @MainActor (URL) -> Void)
        {
          self.picked = picked
          self.cancelled = cancelled
          picker.delegate = self
          Dialogs.present(picker)
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
        {
          guard let url = urls.first else { return }
          MainActor.assumeIsolated { picked?(url) }
          picked = nil
          cancelled = nil
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController)
        {
          MainActor.assumeIsolated { cancelled?() }
          picked = nil
          cancelled = nil
        }
      }

      /// holds a picked file or folder open while the app needs it, and lets go of the previous one
      private enum Access
      {
        @MainActor private static var held: [URL] = []

        /// keeping holds a scene's folder alongside the scene picked before it, otherwise the last pick is let go
        @MainActor static func hold(_ url: URL, keeping: Bool = false)
        {
          if !keeping
          {
            for old in held { old.stopAccessingSecurityScopedResource() }
            held.removeAll()
          }

          if url.startAccessingSecurityScopedResource() { held.append(url) }
        }

        /// whether kraken may list a folder, which it can for its own documents and folders it was given
        static func readable(_ folder: URL) -> Bool
        {
          (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) != nil
        }

        /// the scenes at the top of a folder, the one named after it first.
        static func scenes(in folder: URL) -> [URL]
        {
          let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
          let extensions: Set<String> = ["usd", "usda", "usdc", "usdz"]
          return names.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
              let named = { (url: URL) in url.deletingPathExtension().lastPathComponent == folder.lastPathComponent }
              return named(lhs) != named(rhs) ? named(lhs) : lhs.lastPathComponent < rhs.lastPathComponent
            }
        }
      }
    #endif
  }
}
