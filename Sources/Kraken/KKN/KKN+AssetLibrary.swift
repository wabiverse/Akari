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

import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published

extension Kraken
{
  /// how an asset sits where it's dropped, read from its `akari:placement` asset info.
  enum AssetPlacement: String, Codable, Sendable
  {
    /// stands upright on whatever is under it, the floor below when dropped on a wall
    case floor
    /// hangs with its back on the surface and its front along the surface normal
    case wall
    /// its up axis follows the surface normal
    case surface
  }

  /// one asset in a library, a model placed by reference or a material bound by reference.
  struct LibraryAsset: Codable, Sendable, Hashable, Identifiable
  {
    enum Kind: String, Codable, Sendable
    {
      case model, material
    }

    var name: String
    /// the layer the asset lives in, absolute
    var file: String
    /// the prim in that layer, empty for the layer's default prim
    var prim: String
    var kind: Kind
    /// its model kind, component or assembly or empty
    var modelKind = ""
    var catalog: [String] = []
    var placement = AssetPlacement.floor
    /// an image to show it by, absolute
    var thumbnail: String?
    var isZUp = false
    var metersPerUnit = 1.0
    /// its bounds in its own space, min then max
    var bounds: [Double] = []
    /// the variants of its shading variant set, which a material of the same name selects
    var shadingVariants: [String] = []
    var library = ""
    /// when the layer was last written, so cached thumbnails follow edits
    var modified = 0.0

    var id: String { file + "<" + prim + ">" }

    var catalogPath: String { catalog.joined(separator: "/") }

    /// the prim name a placement or material reference is given
    var primName: String
    {
      let last = prim.split(separator: "/").last.map(String.init) ?? ""
      return last.isEmpty ? URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent : last
    }

    var lo: SIMD3<Double>
    {
      bounds.count == 6 ? SIMD3(bounds[0], bounds[1], bounds[2]) : SIMD3(repeating: -0.5)
    }

    var hi: SIMD3<Double>
    {
      bounds.count == 6 ? SIMD3(bounds[3], bounds[4], bounds[5]) : SIMD3(repeating: 0.5)
    }

    /// whether placing it marks the new prim instanceable, components are and assemblies hold their own instances
    var instanceable: Bool { kind == .model && modelKind == "component" }
  }

  /// reads assets out of usd layers, their kind, catalog, placement and preview from asset info.
  enum AssetScan
  {
    nonisolated static let extensions: Set<String> = ["usd", "usda", "usdc", "usdz"]

    /// every asset in the layers under `root`, its folders the catalog of what doesn't name one
    nonisolated static func scan(_ root: URL, library: String) -> [LibraryAsset]
    {
      guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { return [] }
      var files: [URL] = []
      for case let url as URL in walker
      {
        // thumbnails and textures sit beside assets, they hold no layers
        if ["thumbnails", "textures", "maps"].contains(url.lastPathComponent.lowercased())
        {
          walker.skipDescendants()
          continue
        }

        if extensions.contains(url.pathExtension.lowercased()) { files.append(url) }
      }

      let rootDepth = root.standardizedFileURL.pathComponents.count
      return entries(files).sorted { $0.path < $1.path }.flatMap
      { url -> [LibraryAsset] in
        let folders = Array(url.standardizedFileURL.deletingLastPathComponent().pathComponents.dropFirst(rootDepth))
        return describe(url, library: library, folders: folders)
      }
    }

    /// the layers an asset opens by, its interface file, or the layer named after its folder when there is one
    nonisolated static func entries(_ files: [URL]) -> [URL]
    {
      let parts: Set<String> = ["payload", "geo", "geom", "geometry", "mtl", "material", "materials", "look", "looks",
                                "proxy", "render", "sim", "rig", "anim", "class", "classes"]
      let byFolder = Dictionary(grouping: files) { $0.deletingLastPathComponent().standardizedFileURL.path }
      return byFolder.values.flatMap
      { group -> [URL] in
        let folder = group[0].deletingLastPathComponent().lastPathComponent.lowercased()
        if let own = group.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == folder }) { return [own] }
        return group.filter
        { url in
          let stem = url.deletingPathExtension().lastPathComponent.lowercased()
          let tail = stem.split(separator: "_").last.map(String.init) ?? stem
          return !parts.contains(stem) && !parts.contains(tail) && !stem.hasPrefix("lod")
        }
      }
    }

    /// the assets of one layer, the whole layer as one asset when nothing in it says it's an asset
    nonisolated static func describe(_ url: URL, library: String = "", folders: [String] = []) -> [LibraryAsset]
    {
      guard KrakenArgs.usdProblem(url.path) == nil else { return [] }

      // payloads stay unloaded, a kit's geometry is only read once an asset is placed or rendered
      let stage = UsdStage.open(url.path, load: .none)
      let modified = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)?
        .timeIntervalSince1970 ?? 0
      let base = LibraryAsset(name: "", file: url.path, prim: "", kind: .model,
                              isZUp: UsdGeom.getUpAxis(for: stage) == .z,
                              metersPerUnit: UsdGeom.getMetersPerUnit(for: stage), library: library, modified: modified)
      var purposes = Pixar.TfTokenVector()
      purposes.push_back(.default_)
      purposes.push_back(.render)
      var boxes = Pixar.UsdGeomBBoxCache(Pixar.UsdTimeCode.Default(), purposes, true, false)
      let home = stage.GetDefaultPrim()
      var found: [LibraryAsset] = []

      func visit(_ prim: UsdPrim, depth: Int)
      {
        for child in OutlinerScan.children(prim)
        {
          // class and source prims a layer keeps for itself
          if child.name.string.hasPrefix("__") || child.IsAbstract() { continue }
          var kind = Tf.Token()
          _ = Pixar.UsdModelAPI(child).GetKind(&kind)
          let model = kind.string
          if model == "component" || model == "assembly"
          {
            found.append(asset(child, base, stage, model: model, folders: folders, boxes: &boxes, home: home))
            continue
          }

          if child.isA(.material)
          {
            found.append(asset(child, base, stage, model: "", folders: folders, boxes: &boxes, home: home))
            continue
          }

          // groups, scopes and plain transforms hold assets, anything drawn is part of an asset
          if depth < 4, !child.isA(.gprim), !child.isA(.pointInstancer) { visit(child, depth: depth + 1) }
        }
      }

      visit(stage.GetPseudoRoot(), depth: 0)

      // a file without models that draws anything is one asset with its looks inside, only a file of nothing but looks offers them one by one
      let root = home.isValid ? home : OutlinerScan.children(stage.GetPseudoRoot())
        .first { $0.isA(.imageable) && !$0.name.string.hasPrefix("__") }
      if let root, root.isValid, !found.contains(where: { $0.kind == .model }), found.isEmpty || draws(root)
      {
        return [asset(root, base, stage, model: "", folders: folders, boxes: &boxes, home: home)]
      }

      return found
    }

    /// whether anything under the prim draws, geometry or a payload that brings some in
    nonisolated private static func draws(_ prim: UsdPrim, depth: Int = 0) -> Bool
    {
      if prim.isA(.gprim) || prim.isA(.pointInstancer) || prim.HasAuthoredPayloads() { return true }
      guard depth < 12 else { return false }
      return OutlinerScan.children(prim).contains { !$0.isA(.material) && draws($0, depth: depth + 1) }
    }

    nonisolated private static func asset(_ prim: UsdPrim, _ base: LibraryAsset, _ stage: UsdStage, model: String, folders: [String],
                                          boxes: inout Pixar.UsdGeomBBoxCache, home: UsdPrim) -> LibraryAsset
    {
      var asset = base
      let path = prim.GetPath().string
      asset.prim = home.isValid && home.GetPath().string == path ? "" : path
      asset.kind = prim.isA(.material) ? .material : .model
      asset.modelKind = model
      let named = info(prim, "name")
      let cleaned = readable(prim.name.string)
      asset.name = named.isEmpty ? cleaned.name : named
      let catalog = info(prim, "akari:catalog")
      let top = base.library.isEmpty ? [] : [base.library]
      if !catalog.isEmpty
      {
        asset.catalog = top + catalog.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      }
      else
      {
        // the folders an asset sits in, without the ones every asset of a kit sits in and its own folder
        let stem = URL(fileURLWithPath: base.file).deletingPathExtension().lastPathComponent.lowercased()
        let kept = folders.filter { !noiseFolders.contains($0.lowercased()) && $0.lowercased() != stem }.map(readable(folder:))
        asset.catalog = top + kept
        if asset.kind == .model, named.isEmpty, let group = cleaned.group { asset.catalog.append(group) }
        if asset.catalog.count == top.count { asset.catalog.append(asset.kind == .material ? "Materials" : "Unassigned") }
      }

      asset.placement = AssetPlacement(rawValue: info(prim, "akari:placement").lowercased()) ?? .floor
      let image = info(prim, "previews:thumbnails:default:defaultImage")
      if !image.isEmpty { asset.thumbnail = anchored(image, to: base.file) }
      if asset.kind == .model
      {
        let range = boxes.ComputeUntransformedBound(prim).ComputeAlignedRange()
        if !range.IsEmpty()
        {
          #if compiler(>=6.4) && canImport(Usd)
            asset.bounds = SceneEdit.numbers(range.GetMinConsuming()) + SceneEdit.numbers(range.GetMaxConsuming())
          #else
            asset.bounds = SceneEdit.numbers(range.GetMin()) + SceneEdit.numbers(range.GetMax())
          #endif
        }

        asset.shadingVariants = SceneEdit.variantSets(stage, path)
          .first { shadingSet($0.name) }?.variants ?? []
      }

      return asset
    }

    /// folders that say what a file is rather than what it shows
    nonisolated static let noiseFolders: Set<String> = ["3d_assets", "assets", "asset", "models", "model", "materials",
                                                        "material", "geometry", "geo", "usd", "source", "export", "exports"]

    /// the word a kit starts a model's name with, and the catalog it files it under
    nonisolated static let groups: [String: String] = ["bldg": "Buildings", "building": "Buildings", "prop": "Props",
                                                       "veh": "Vehicles", "vehicle": "Vehicles", "char": "Characters",
                                                       "env": "Environment", "fol": "Plants", "plant": "Plants",
                                                       "tree": "Plants", "fx": "Effects", "light": "Lights",
                                                       "furn": "Furniture", "asset": "Sets", "set": "Sets"]

    /// words of a name, split at underscores and where lower case turns upper, `CyberpunkDJBooth` as cyberpunk dj booth
    nonisolated static func words(_ name: String) -> [String]
    {
      var out: [String] = []
      for token in name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
      {
        var word = ""
        let characters = Array(token)
        for (i, c) in characters.enumerated()
        {
          let previous = i > 0 ? characters[i - 1] : " "
          let next = i + 1 < characters.count ? characters[i + 1] : " "
          let breaks = c.isUppercase && (previous.isLowercase || (previous.isUppercase && next.isLowercase))
          if breaks, !word.isEmpty
          {
            out.append(word)
            word = ""
          }

          word.append(c)
        }

        if !word.isEmpty { out.append(word) }
      }

      return out
    }

    nonisolated static func readable(folder: String) -> String
    {
      words(folder).joined(separator: " ")
    }

    /// a prim name made readable, a kit's code prefixes like `KB3D_SHG_` left off and its group word taken out
    nonisolated static func readable(_ name: String) -> (name: String, group: String?)
    {
      var tokens = name.split(separator: "_").map(String.init)

      // leading codes are short tokens in capitals and digits, kept when nothing else would be left
      while tokens.count > 1, let first = tokens.first, first.count <= 5, first == first.uppercased(),
            first.contains(where: \.isLetter), tokens.dropFirst().contains(where: { $0.contains(where: \.isLowercase) })
      {
        tokens.removeFirst()
      }

      var parts = words(tokens.joined(separator: "_"))
      var group: String?
      if parts.count > 1, let found = groups[parts[0].lowercased()]
      {
        group = found
        parts.removeFirst()
      }

      let joined = parts.joined(separator: " ")
      return (joined.isEmpty ? name : joined, group)
    }

    /// whether a variant set swaps an asset's look, the way a shading or material variant does
    nonisolated static func shadingSet(_ name: String) -> Bool
    {
      let lower = name.lowercased()
      return lower.contains("shading") || lower.contains("material") || lower.contains("look")
    }

    /// a string entry of the prim's asset info, a colon in the key reaching into nested dictionaries
    nonisolated static func info(_ prim: UsdPrim, _ key: String) -> String
    {
      String(Pixar.HdAkariDescribeValue(prim.GetAssetInfoByKey(Tf.Token(key))))
    }

    /// an asset path from asset info, absolute against the layer it came from
    nonisolated private static func anchored(_ path: String, to file: String) -> String
    {
      if path.hasPrefix("/") { return path }
      return URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path
    }
  }

  /// the libraries the asset browser shows, scanned off the main thread.
  @MainActor
  final class AssetLibrary: ObservableObject
  {
    static let shared = AssetLibrary()

    @Published private(set) var assets: [LibraryAsset] = []
    @Published private(set) var scanning = false
    /// bumped when assets or their thumbnails change, for views drawing them
    private(set) var revision = 0

    private static let foldersKey = "KrakenAssetLibraries"

    /// the sample library beside the sources in a development build, then the user's own folders
    var roots: [(url: URL, name: String)]
    {
      var roots: [(URL, String)] = []
      let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let sample = repo.appendingPathComponent("Scenes/AssetLibrary")
      if FileManager.default.fileExists(atPath: sample.path) { roots.append((sample, "Sample Library")) }
      let support = URL.applicationSupportDirectory.appendingPathComponent("Kraken/Assets")
      if FileManager.default.fileExists(atPath: support.path) { roots.append((support, "My Assets")) }
      let env = ProcessInfo.processInfo.environment["KRAKEN_ASSET_LIBRARY"] ?? ""
      for path in env.split(separator: ":") + (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []).map({ Substring($0) })
      {
        let url = URL(fileURLWithPath: String(path))
        roots.append((url, AssetScan.readable(folder: url.lastPathComponent)))
      }

      return roots
    }

    private init()
    {
      rescan()
    }

    func rescan()
    {
      guard !scanning else { return }
      AssetThumbnails.shared.retryFailed()
      scanning = true
      let roots = roots
      DispatchQueue.global(qos: .userInitiated).async
      {
        var found: [LibraryAsset] = []
        for root in roots { found += AssetScan.scan(root.url, library: root.name) }
        let assets = found
        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          self.scanning = false
          self.assets = assets
          self.revision += 1
          AssetThumbnails.shared.prepare(assets)
          Console.info("asset browser found \(assets.count) assets in \(roots.count) libraries")
        }
      }
    }

    /// keeps a folder as a library from now on
    func add(folder: URL)
    {
      var folders = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []
      guard !folders.contains(folder.path) else { return }
      folders.append(folder.path)
      UserDefaults.standard.set(folders, forKey: Self.foldersKey)
      rescan()
    }

    func asset(id: String) -> LibraryAsset?
    {
      assets.first { $0.id == id }
    }

    func changed()
    {
      revision += 1
    }
  }

  /// one asset browser panel's view of the libraries: its kind of asset, the catalog it shows and its search.
  @MainActor
  final class AssetShelf: ObservableObject
  {
    static let objects = AssetShelf(kind: .model, title: "Objects")
    static let materials = AssetShelf(kind: .material, title: "Materials")

    let kind: LibraryAsset.Kind
    let title: String
    /// the catalog shown, empty for every asset of the shelf's kind
    @Published var catalog: [String] = []
    @Published var search = ""

    private init(kind: LibraryAsset.Kind, title: String)
    {
      self.kind = kind
      self.title = title
    }

    /// one row of the catalog tree
    struct CatalogRow: Equatable
    {
      var path: [String]
      var count: Int
      var hasChildren: Bool
    }

    /// an asset's catalog as the shelf files it, a material shelf leaving off the materials catalog its materials sit in
    func path(_ asset: LibraryAsset) -> [String]
    {
      kind == .material ? asset.catalog.filter { $0 != "Materials" } : asset.catalog
    }

    var all: [LibraryAsset]
    {
      AssetLibrary.shared.assets.filter { $0.kind == kind }
    }

    /// what the panel shows, under the catalog and matching the search
    var shown: [LibraryAsset]
    {
      let words = search.lowercased().split(separator: " ").map(String.init)
      return all.filter
      { asset in
        path(asset).starts(with: catalog)
          && words.allSatisfy { asset.name.lowercased().contains($0) || asset.catalogPath.lowercased().contains($0) }
      }
      .sorted { (path($0).joined(separator: "/"), $0.name) < (path($1).joined(separator: "/"), $1.name) }
    }

    /// every catalog and its parents, in tree order with how many assets sit at or under each
    var catalogs: [CatalogRow]
    {
      var counts: [[String]: Int] = [:]
      for asset in all
      {
        let path = path(asset)
        for depth in stride(from: 1, through: path.count, by: 1) { counts[Array(path.prefix(depth)), default: 0] += 1 }
      }

      let paths = counts.keys.sorted { $0.joined(separator: "\u{1}") < $1.joined(separator: "\u{1}") }
      return paths.map
      { path in
        CatalogRow(path: path, count: counts[path] ?? 0,
                   hasChildren: paths.contains { $0.count == path.count + 1 && $0.starts(with: path) })
      }
    }
  }
}
