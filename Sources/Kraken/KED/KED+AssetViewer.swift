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
import AkariHydra
import AkariRender
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published
#if !os(macOS)
  import MetalKit
  import UIKit
#endif

extension Kraken
{
  /// a lit set the asset viewer stands an artifact in, a usd layer in the app's studios folder
  struct Studio: Hashable
  {
    var name: String
    var file: String

    /// every studio frames a subject this many meters across standing on its origin
    static let subjectSize = 0.4

    /// the studios shipped with the app, the copy stand first
    static let all: [Studio] = {
      guard let folder = Bundle.akariResource("Studios", in: "Akari_Kraken") else { return [] }
      let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension == "usda" }
        .map { Studio(name: $0.deletingPathExtension().lastPathComponent, file: $0.path) }
        .sorted { ($0.name == "Copy Stand" ? 0 : 1, $0.name) < ($1.name == "Copy Stand" ? 0 : 1, $1.name) }
    }()
  }

  /// the studios' preview pictures from their asset info, read off the main thread since a studio can be a heavy rig
  @MainActor
  final class StudioPreviews: ObservableObject
  {
    static let shared = StudioPreviews()

    @Published private(set) var urls: [String: URL] = [:]

    private init()
    {
      let studios = Studio.all
      DispatchQueue.global(qos: .userInitiated).async
      {
        var found: [String: URL] = [:]
        for studio in studios
        {
          let stage = UsdStage.open(studio.file, load: .none)
          let image = AssetScan.info(stage.GetDefaultPrim(), "previews:thumbnails:default:defaultImage")
          if !image.isEmpty { found[studio.name] = URL(fileURLWithPath: AssetScan.anchored(image, to: studio.file)) }
        }

        let urls = found
        DispatchQueue.main.async { self.urls = urls }
      }
    }
  }

  /// the studios as pictures to pick from, the one assets stand in marked, picking one opens it
  @MainActor
  struct StudioStrip: View
  {
    @State private var viewer: AssetViewer
    @State private var previews = StudioPreviews.shared

    init(viewer: AssetViewer)
    {
      _viewer = State(wrappedValue: viewer)
    }

    var body: some View
    {
      // the studios scroll sideways at a size their pictures and names read at, however narrow the panel
      ScrollView(.horizontal)
      {
        HStack(spacing: 6)
        {
          ForEach(Studio.all, id: \.self) { studio in card(studio) }
        }
        .padding(.horizontal, 12)
      }
      .frame(height: 92)
    }

    private func card(_ studio: Studio) -> some View
    {
      let chosen = studio == viewer.studio
      let viewer = viewer
      return VStack(spacing: 4)
      {
        picture(studio)
          .frame(width: 96, height: 60)
          .cornerRadius(7)
        Text(studio.name)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(chosen ? Properties.text : Properties.label)
          .frame(width: 96, height: 14)
      }
      .padding(4)
      .frame(width: 104, height: 86)
      .background(RoundedRectangle(cornerRadius: 10).fill(chosen ? Properties.accent : Color.clear))
      .onTapGesture
      {
        viewer.use(studio)
        viewer.open()
      }
    }

    @ViewBuilder
    private func picture(_ studio: Studio) -> some View
    {
      if let url = previews.urls[studio.name]
      {
        Image(url)
          .resizable()
      }
      else
      {
        Rectangle()
          .fill(Color(white: 0.12))
      }
    }

    private typealias Properties = Kraken.Properties
  }

  /// shows one library asset at a time in a studio on its own akari engine over the viewport, the scene left as it was
  @MainActor
  final class AssetViewer: ObservableObject
  {
    @Published private(set) var hydra: Hydra.RenderEngine?
    @Published private(set) var asset: LibraryAsset?
    @Published private(set) var studio: Studio
    /// showing over the viewport, an empty studio until an asset is tapped
    @Published private(set) var isOpen = false

    /// the viewport's width over its height, for framing
    var aspect = 1.0

    private let host: Hydra.RenderEngine
    /// the scene's engine, whose settings the viewer draws with
    private let scene: Akari.RenderEngine
    private var engine: Akari.RenderEngine?
    private var driver: Akari.FrameDriver?

    private static let studioKey = "KrakenViewerStudio"
    nonisolated static let subjectPath = "/Subject"

    init(host: Hydra.RenderEngine, scene: Akari.RenderEngine)
    {
      self.host = host
      self.scene = scene
      let chosen = UserDefaults.standard.string(forKey: Self.studioKey)
      studio = Studio.all.first { $0.name == chosen } ?? Studio.all.first ?? Studio(name: "", file: "")
    }

    /// stands the asset in the studio, opening the viewer if it isn't showing
    func show(_ asset: LibraryAsset)
    {
      self.asset = asset
      open()
    }

    /// shows the studio over the viewport, with whatever asset is in it
    func open()
    {
      #if !os(macOS)
        if !isOpen { pauseScene(true) }
      #endif
      isOpen = true
      guard let hydra else { return start() }

      let asset = asset, aspect = aspect
      hydra.performOnFrameQueue
      {
        if let asset { Self.place(asset, on: hydra.stage) } else { _ = hydra.stage.RemovePrim(Sdf.Path(Self.subjectPath)) }
        Self.frame(hydra, asset, aspect: aspect)
      }
    }

    /// looks at the asset from the start again
    func reframe()
    {
      guard let hydra else { return }
      let asset = asset, aspect = aspect
      hydra.performOnFrameQueue { Self.frame(hydra, asset, aspect: aspect) }
    }

    func use(_ studio: Studio)
    {
      guard studio != self.studio else { return }
      self.studio = studio
      UserDefaults.standard.set(studio.name, forKey: Self.studioKey)
      guard let hydra, let engine else { return }
      nonisolated(unsafe) let lit = engine
      hydra.performOnFrameQueue { Self.light(hydra.stage, in: studio, engine: lit) }
    }

    /// back to the scene, just as it was
    func close()
    {
      guard isOpen else { return }
      isOpen = false
      asset = nil
      #if !os(macOS)
        pauseScene(false)
      #endif
    }

    private func start()
    {
      guard engine == nil else { return }

      // drawn like the viewport it stands in for, without the haze the studio lights would veil the artifact in
      var settings = scene.settings
      settings.features.subtract([.volumetrics])

      // an artifact is always seen rendered in its studio, never solid and never under the viewport's grid
      settings.shading = .rendered
      settings.overlays = false
      nonisolated(unsafe) let engine = Akari.RenderEngine(settings: settings)
      self.engine = engine
      let host = host, studio = studio
      host.performOnFrameQueue
      { [weak self] in
        let stage = UsdStage.createInMemory("viewer.usda")
        _ = UsdGeom.setUpAxis(for: stage, to: .z)
        _ = UsdGeom.setMetersPerUnit(for: stage, to: 1)
        engine.labfx.setStageUpAxis(isZUp: true)
        engine.labfx.setStageMetersPerUnit(1)
        Self.light(stage, in: studio, engine: engine)
        let hydra = withAkariRenderer(engine)
        {
          Hydra.RenderEngine(stage: stage, rendererPluginId: Tf.Token(Akari.rendererPluginId), sharing: host)
        }

        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          let driver = Akari.FrameDriver(hydra: hydra, akari: engine)
          driver.outlinesSelection = false
          self.driver = driver
          self.hydra = hydra
          if self.isOpen { self.open() }
        }
      }
    }

    // MARK: stage

    /// the studio as the layer under the viewer's, its exposure and view transform on the engine
    private nonisolated static func light(_ stage: UsdStage, in studio: Studio, engine: Akari.RenderEngine)
    {
      let root = stage.getRootLayer().pointee
      while root.GetNumSubLayerPaths() > 0
      {
        root.RemoveSubLayerPath(0)
      }

      root.InsertSubLayerPath(std.string(studio.file), 0)
      let set = UsdStage.open(studio.file, load: .none)
      engine.adoptColorManagement(of: set)
      realScale = AssetScan.info(set.GetDefaultPrim(), "akari:subjectScale") == "real"
    }

    /// the studio stands subjects at their own size, set and read on the frame queue
    private nonisolated(unsafe) static var realScale = false

    /// the asset referenced in, through its akari sidecar when it has one, turned z up and fitted standing on the origin
    private nonisolated static func place(_ asset: LibraryAsset, on stage: UsdStage)
    {
      let path = Sdf.Path(subjectPath)
      _ = stage.RemovePrim(path)
      let prim = stage.DefinePrim(path, .xform)
      var references = prim.getReferences()
      if asset.prim.isEmpty { references.addReference(assetPath: asset.file) }
      else { references.addReference(assetPath: asset.file, primPath: Sdf.Path(asset.prim)) }

      // the fit replaces whatever transform the asset's root carries, as its bounds leave that transform out
      let fit = fitting(asset)
      let xformable = Pixar.UsdGeomXformable(prim)
      _ = xformable.ClearXformOpOrder()
      _ = xformable.addXformOp(type: .transform, precision: .double)
        .Set(SceneEdit.matrix(Layout.array(fit.matrix)), Pixar.UsdTimeCode.Default())
    }

    /// the asset's bounds turned z up, in its own units
    private nonisolated static func upright(_ asset: LibraryAsset) -> (lo: SIMD3<Double>, hi: SIMD3<Double>)
    {
      let b = asset.bounds.count == 6 ? asset.bounds : [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5].map { $0 / asset.metersPerUnit }
      if asset.isZUp { return (SIMD3(b[0], b[1], b[2]), SIMD3(b[3], b[4], b[5])) }
      return (SIMD3(b[0], -b[5], b[1]), SIMD3(b[3], -b[2], b[4]))
    }

    /// what stands the asset on the origin at the studio's subject size, and how big it then is in meters
    private nonisolated static func fitting(_ asset: LibraryAsset) -> (matrix: simd_double4x4, size: SIMD3<Double>)
    {
      let (lo, hi) = upright(asset)
      let meters = (hi - lo) * asset.metersPerUnit
      let fit = realScale ? 1 : Studio.subjectSize / max(meters.max(), 1e-6)
      let s = asset.metersPerUnit * fit
      let center = (lo + hi) * 0.5

      // a y up asset turns a quarter about x to stand z up
      let turn = asset.isZUp ? matrix_identity_double4x4
        : simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)))
      var place = matrix_identity_double4x4
      place.columns.3 = SIMD4(-center.x * s, -center.y * s, -lo.z * s + 0.002, 1)
      let scale = simd_double4x4(diagonal: SIMD4(s, s, s, 1))
      return (place * scale * turn, meters * fit)
    }

    /// a three quarter view from a little above, the whole artifact in frame whichever way the viewport is turned
    private nonisolated static func frame(_ hydra: Hydra.RenderEngine, _ asset: LibraryAsset?, aspect: Double)
    {
      let size = asset.map { fitting($0).size } ?? SIMD3(repeating: Studio.subjectSize)
      let radius = 0.5 * simd_length(size)
      let focal = 50.0, aperture = 15.2908
      let vertical = atan(aperture * 0.5 / focal)
      let horizontal = atan(tan(vertical) * min(aspect, 1))
      hydra.stopFlick()
      hydra.viewCamera.gfCamera.focalLength = Float(focal)
      hydra.viewCamera.standardFocalLength = focal
      hydra.viewCamera.rotation = Pixar.GfVec3d(-20, 29, 0)
      hydra.viewCamera.focus = Pixar.GfVec3d(0, 0, size.z * 0.5)
      hydra.viewCamera.distance = radius / sin(min(vertical, horizontal)) * 1.12
    }

    /// the asset's size in its own space, as a curator would read it
    static func dimensions(_ asset: LibraryAsset) -> String
    {
      let (lo, hi) = upright(asset)
      let m = (hi - lo) * asset.metersPerUnit
      let centimeters = m.max() < 1
      let values = [m.x, m.y, m.z].map { String(format: centimeters ? "%.1f" : "%.2f", centimeters ? $0 * 100 : $0) }
      return values.joined(separator: " × ") + (centimeters ? " cm" : " m")
    }

    #if !os(macOS)
      /// the views drawing when the viewer opened, the scene's viewport among them, paused so the gpu is the viewer's
      private var paused: [MTKView] = []

      private func pauseScene(_ pause: Bool)
      {
        if pause, let window = Dialogs.window
        {
          paused = Self.drawing(in: window).filter { !$0.isPaused }
          for view in paused
          {
            view.isPaused = true
          }
        }
        else if !pause
        {
          for view in paused
          {
            view.isPaused = false
          }

          paused = []
        }
      }

      private static func drawing(in view: UIView) -> [MTKView]
      {
        ((view as? MTKView).map { [$0] } ?? []) + view.subviews.flatMap { drawing(in: $0) }
      }
    #endif
  }

  /// the viewer over the viewport, the artifact's card, its studio and the way back to the scene
  @MainActor
  struct AssetViewerView: View
  {
    @State private var viewer: AssetViewer
    let layout: Layout

    init(viewer: AssetViewer, layout: Layout)
    {
      _viewer = State(wrappedValue: viewer)
      self.layout = layout
    }

    var body: some View
    {
      if viewer.isOpen
      {
        stage(viewer.asset)
          .overlay(alignment: .topLeading)
          {
            if let asset = viewer.asset { card(asset) }
          }
          .overlay(alignment: .topTrailing) { controls(viewer.asset) }
          .overlay(alignment: .bottom)
          {
            if viewer.asset == nil { hint }
          }
      }
    }

    /// what an empty studio waits for
    private var hint: some View
    {
      Text("Tap an asset to view it in \(viewer.studio.name)")
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(Properties.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Touch.well))
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func stage(_ asset: LibraryAsset?) -> some View
    {
      if let hydra = viewer.hydra
      {
        #if os(macOS)
          Hydra.Viewport(engine: hydra)
        #else
          Hydra.Viewport(engine: hydra)
            .overlay { NativeView(make: { [viewer] in AssetViewerTouch(viewer: viewer) }) }
        #endif
      }
      else
      {
        Rectangle()
          .fill(Color(white: 0.06))
          .overlay
          {
            Text("Opening \(asset?.name ?? viewer.studio.name)…")
              .font(.system(size: 13, weight: .medium))
              .foregroundColor(Properties.label)
          }
      }
    }

    private func card(_ asset: LibraryAsset) -> some View
    {
      VStack(alignment: .leading, spacing: 3)
      {
        Text(asset.name)
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(Properties.text)
        Text(AssetViewer.dimensions(asset))
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(Properties.label)
        if !asset.catalogPath.isEmpty
        {
          Text(asset.catalogPath)
            .font(.system(size: 12))
            .foregroundColor(Properties.label)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(RoundedRectangle(cornerRadius: 12).fill(Touch.well))
      .padding(10)
    }

    private func controls(_ asset: LibraryAsset?) -> some View
    {
      let viewer = viewer, layout = layout
      return VStack(spacing: 8)
      {
        TouchButton("xmark") { viewer.close() }
        MenuButton(symbol: "light.max")
        {
          Studio.all.map { studio in MenuEntry(title: studio.name, checked: studio == viewer.studio) { viewer.use(studio) } }
        }
        if let asset
        {
          TouchButton("plus")
          {
            viewer.close()
            layout.use(asset)
          }
        }
      }
      .padding(10)
    }

    private typealias Touch = Kraken.Touch
    private typealias TouchButton = Kraken.TouchButton
    private typealias MenuButton = Kraken.MenuButton
    private typealias MenuEntry = Kraken.MenuEntry
    private typealias Properties = Kraken.Properties
  }

  #if !os(macOS)
    /// turns the viewer's camera with one finger, pans with two, pinches closer and double taps to look again from the start
    final class AssetViewerTouch: UIView
    {
      private let viewer: AssetViewer

      init(viewer: AssetViewer)
      {
        self.viewer = viewer
        super.init(frame: .zero)
        backgroundColor = .clear

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbited(_:)))
        orbit.maximumNumberOfTouches = 1
        addGestureRecognizer(orbit)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let again = UITapGestureRecognizer(target: self, action: #selector(reframed))
        again.numberOfTapsRequired = 2
        addGestureRecognizer(again)
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      override func layoutSubviews()
      {
        super.layoutSubviews()
        guard bounds.height > 0 else { return }
        let aspect = Double(bounds.width / bounds.height)
        guard abs(aspect - viewer.aspect) > 0.01 else { return }
        viewer.aspect = aspect
        viewer.reframe()
      }

      @objc private func orbited(_ gesture: UIPanGestureRecognizer)
      {
        guard let hydra = viewer.hydra else { return }
        switch gesture.state
        {
          case .began, .changed:
            hydra.stopFlick()
            let d = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            hydra.orbit(deltaYaw: Double(d.x) * 0.4, deltaPitch: Double(d.y) * 0.4)
          case .ended:
            let velocity = gesture.velocity(in: self)
            hydra.flick(deltaYaw: Double(velocity.x) / 60 * 0.4, deltaPitch: Double(velocity.y) / 60 * 0.4)
          default:
            break
        }
      }

      @objc private func panned(_ gesture: UIPanGestureRecognizer)
      {
        guard let hydra = viewer.hydra, gesture.state == .changed || gesture.state == .began else { return }
        let d = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        hydra.pan(deltaX: Double(d.x), deltaY: Double(d.y), viewHeight: Double(bounds.height))
      }

      @objc private func pinched(_ gesture: UIPinchGestureRecognizer)
      {
        guard let hydra = viewer.hydra, gesture.state == .changed || gesture.state == .began, gesture.scale > 0 else { return }
        hydra.dolly(by: Double(1 / gesture.scale) - 1)
        gesture.scale = 1
      }

      @objc private func reframed()
      {
        viewer.reframe()
      }
    }
  #endif
}

#if !os(macOS)
  extension Kraken.AssetViewerTouch: UIGestureRecognizerDelegate
  {
    /// two fingers pan and pinch at once
    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
    {
      other is UIPinchGestureRecognizer || (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
    }
  }
#endif
