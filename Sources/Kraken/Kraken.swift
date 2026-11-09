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
import HydraKit
import SwiftCrossUI

#if os(Android)
  import AndroidBackend
#elseif os(Linux)
  import GtkBackend
#elseif os(Windows)
  import WinUIBackend
#elseif os(macOS)
  import AppKitBackend
#else
  import UIKitBackend
#endif

// Kraken, the universal realtime creation suite, rendered by Akari.
#if !os(macOS)
  // only macOS currently supports headless renders
  // TODO: figure out platform differences...
  @main
#endif
struct Kraken: App
{
  typealias Backend = PlatformBackend

  let hydra: Hydra.RenderEngine
  let engine: Akari.RenderEngine

  let driver: any Akari.HydraFrameDriver
  let settings: HUDState
  let layout: Layout
  let renderJob: RenderJob
  let timeline: Timeline
  let isHeadlessRender: Bool

  @State var scene: Kraken.SceneFile

  init()
  {
    AppUtils.raiseOpenFileLimit()

    Pixar.Bundler.shared.setup(.resources)

    AppUtils.registerAkariPlugin()

    let render = AppUtils.renderArguments()
    #if os(macOS)
      isHeadlessRender = render.backgroundWorker
    #else
      isHeadlessRender = false
    #endif

    engine = Akari.RenderEngine(settings: RenderSettings(quality: render.quality ?? .high))
    registerAkariRenderer(engine: engine)

    let newScene: (stage: UsdStage, fileURL: URL?) = AppUtils.openOrCreateStage()

    engine.labfx.setStageUpAxis(isZUp: UsdGeom.getUpAxis(for: newScene.stage) == .z)
    engine.labfx.setStageMetersPerUnit(UsdGeom.getMetersPerUnit(for: newScene.stage))

    let lattice = AppUtils.latticeMotionFile().flatMap { LatticeBulbDriver(motionFile: $0) }

    hydra = Hydra.RenderEngine(stage: newScene.stage,
                               selectionColor: Pixar.GfVec4f(1.0, Float(0xA0) / 255, Float(0x28) / 255, 1.0),
                               selectionOutlineWidth: 8,
                               rendererPluginId: Tf.Token(Akari.rendererPluginId))
    AppUtils.frameStartView(hydra)
    let frameDriver = Akari.FrameDriver(hydra: hydra, akari: engine)
    driver = frameDriver

    engine.adoptColorManagement(of: newScene.stage)

    let cameraView = Akari.CameraView(hydra: hydra, akari: engine)
    frameDriver.cameraView = cameraView

    let playback = Akari.Playback(hydra: hydra, akari: engine)
    frameDriver.playback = playback
    if let lattice
    {
      lattice.inner = frameDriver
      lattice.time = { (playback.frame - playback.range.lowerBound) / playback.frameRate }
      hydra.frameDelegate = lattice
    }

    let newRenderJob = RenderJob(renderer: Akari.FinalRender(hydra: hydra, akari: engine),
                                 cameraView: cameraView,
                                 playback: playback,
                                 defaultPath: RenderJob.defaultOutputPath(for: newScene.fileURL),
                                 arguments: render)
    renderJob = newRenderJob

    timeline = Timeline(playback: playback)
    if !isHeadlessRender
    {
      let probeTimes = Akari.Playback.probeBakeTimes(newScene.stage)
      Task { @MainActor in await playback.prebakeProbes(at: probeTimes) }
    }

    settings = HUDState(engine: engine, hydra: hydra)
    layout = Layout(engine: engine, hydra: hydra, driver: frameDriver)
    scene = Kraken.SceneFile(fileURL: newScene.fileURL)

    print("[akari] first light - renderer = \(Akari.rendererPluginId)")
  }

  var body: some Scene
  {
    WindowGroup("\(scene.title) ∙ Kraken (Akari v\(Akari.version))")
    {
      Workspace(engine: engine,
                hydra: hydra,
                driver: driver,
                settings: settings,
                layout: layout,
                renderJob: renderJob,
                timeline: timeline,
                scene: $scene)
        .environment(\.colorScheme, .dark)
    }
    .defaultLaunchBehavior(isHeadlessRender ? .suppressed : .presented)
  }
}
