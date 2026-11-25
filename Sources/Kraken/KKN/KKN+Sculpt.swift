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
import simd
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published

extension Kraken
{
  /// how the sculpt viewport shades the surface
  enum SculptShading: String, CaseIterable, Sendable
  {
    case clay = "Clay"
    case studio = "Studio"
    case painterly = "Painterly"

    var symbol: String
    {
      switch self
      {
        case .clay: "circle.fill"
        case .studio: "light.max"
        case .painterly: "paintpalette.fill"
      }
    }
  }

  /// where pencil and tube strokes land
  enum SculptPlacement: String, CaseIterable, Sendable
  {
    case surface = "Surface"
    case view = "View Plane"
  }

  /// how fine the sculpt's voxels are
  enum SculptDetail: String, CaseIterable, Sendable
  {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "Ultra"

    /// the level a sculpt starts at, the resolution digital clay usually opens with
    static let standard = SculptDetail.medium

    /// voxels across the widest side of what is sculpted
    var across: Float
    {
      switch self
      {
        case .low: 64
        case .medium: 128
        case .high: 256
        case .ultra: 512
      }
    }

    /// the voxel size for a sculpt whose unit is half its widest side
    var voxel: Float
    {
      2 / across
    }

    static func nearest(_ voxel: Float) -> SculptDetail
    {
      allCases.min { abs($0.voxel - voxel) < abs($1.voxel - voxel) } ?? standard
    }
  }

  /// a pointer sample from the viewport with the camera it was seen through
  struct SculptPointer: Sendable
  {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
    var eye: SIMD3<Float>
    var forward: SIMD3<Float>
    /// world size of a pixel one unit in front of the eye, or anywhere for an orthographic view
    var pixelScale: Float
    var perspective: Bool
    var pressure: Float = 1
    var invert = false
    var smooth = false

    func pixelSize(at p: SIMD3<Float>) -> Float
    {
      perspective ? max(simd_dot(p - eye, forward), 1e-4) * pixelScale : pixelScale
    }

    /// where the ray meets the plane through `point` facing the camera
    func onPlane(through point: SIMD3<Float>) -> SIMD3<Float>
    {
      let denominator = simd_dot(direction, forward)
      guard abs(denominator) > 1e-6 else { return point }
      return origin + direction * (simd_dot(point - origin, forward) / denominator)
    }
  }

  /// one grease pencil stroke in the sculpt's space
  struct SculptPencilStroke: Sendable
  {
    var points: [SIMD3<Float>] = []
    var widths: [Float] = []
    var color = SIMD3<Float>(0.6, 0.05, 0.08)
    var opacity: Float = 1
  }

  /// one undoable sculpt change
  enum SculptStep
  {
    case volume([SIMD3<Int32>: SculptBrickState])
    case pencil([SculptPencilStroke])
    case whole(SculptVolume, [SculptPencilStroke])
  }

  /// the sculpting session, its tools and settings, the volume and its mesh, strokes and undo
  @MainActor
  final class Sculpt: ObservableObject
  {
    @Published var brush: SculptBrush = .clay
    {
      didSet { strength = strengths[brush] ?? brush.defaultStrength }
    }

    /// the brush radius in screen points
    @Published var radius = 48.0
    @Published var strength = SculptBrush.clay.defaultStrength
    {
      didSet { strengths[brush] = strength }
    }

    @Published var falloff: SculptFalloff = .smooth
    @Published var mirror = [true, false, false]
    @Published var invert = false
    @Published var lazy = 0.0
    @Published var pressureSize = true
    @Published var pressureStrength = true
    @Published var paintsWhileSculpting = false
    /// fingers sculpt until a pencil is seen, then they only steer the view
    @Published var fingersSculpt = true

    @Published var paint = SIMD3<Double>(0.93, 0.89, 0.86)
    @Published var gloss = 0.15

    @Published var shading: SculptShading = .studio
    @Published var lightAngle = 35.0
    @Published var lightHeight = 38.0
    @Published var rim = 0.55
    @Published var ambient = 0.22
    @Published var warmth = 0.45
    @Published var cavity = 0.6
    /// how much the lights shade the paint, low for paint projected from a picture that already holds its light
    @Published var lighting = 1.0
    @Published var clayColor = SIMD3<Double>(0.74, 0.62, 0.55)
    @Published var backgroundTop = SIMD3<Double>(0.05, 0.06, 0.08)
    @Published var backgroundBottom = SIMD3<Double>(0.26, 0.31, 0.37)

    /// the painterly look, stroke size in points
    @Published var strokeSize = 7.0
    @Published var strokeLength = 2.6
    @Published var strokeDensity = 0.75
    @Published var abstraction = 3.5
    @Published var canvasGrain = 0.35
    @Published var lostEdges = 0.5
    @Published var bands = 5.0

    @Published var pencilColor = SIMD3<Double>(0.62, 0.04, 0.09)
    @Published var pencilWidth = 6.0
    @Published var pencilOpacity = 1.0
    @Published var placement: SculptPlacement = .surface

    @Published var shape: SculptShape = .sphere
    @Published var combine: SculptCombine = .add
    @Published var detail: SculptDetail = .standard
    /// the voxel size the next remesh makes, in the sculpt's own units
    @Published var remeshVoxel = Double(SculptDetail.standard.voxel)
    /// true while a remesh resamples the volume, strokes and whole edits wait for it
    @Published var isRemeshing = false
    /// triangles in the sculpt surface itself, far more than the thinned copy the scene gets
    @Published var surfaceFaces = 0
    @Published var showsMask = true

    /// the image the sculpt follows, shown over the viewport and projected as paint
    @Published var reference: SculptReference?
    @Published var showsReference = true
    @Published var referenceOpacity = 0.35
    var referenceRevision = 0
    @Published var writesSplats = true
    /// the row of brushes along the bottom of the viewport
    @Published var showsShelf = true
    @Published var status = ""
    {
      didSet { layout?.status = status }
    }

    /// bumped when the viewport should frame the whole sculpt again
    var frameRequest = 0

    /// a view the viewport takes on its next frame instead of framing everything
    var requestedCamera: SculptCamera?
    /// the height in the scene viewport's own pixels the requested view was seen at, so a shorter viewport widens it to match
    var requestedHeight: Float?

    /// where the viewport last looked, kept here since the tab builds a new view every time it shows
    var viewCamera: SculptCamera?

    /// the camera the reference was last projected from, the viewport reads detail finer than the voxel paint back from the picture
    var projection: (camera: SculptCamera, aspect: Float)?

    /// the sculpt's root prim, nil until the first write gives it one
    @Published var primPath: String?
    /// the prim being opened, so an open that finishes after the selection moved on is dropped
    var opening: String?
    /// how big the sculpt's space is, so a detail level spans the same share of a small mesh and a large one
    var unit: Float = 1
    /// the turn that stands a z up scene upright for the viewport, which keeps y up
    var upright = matrix_identity_float4x4
    /// where the sculpt's own space sits in the viewport's upright world
    var frame = matrix_identity_float4x4
    /// the scene's other meshes around the sculpt, flat shaded triangles in the upright world
    var scene: [SculptVertex] = []
    var sceneRevision = 0

    var strengths: [SculptBrush: Double] = [:]
    var volume: SculptVolume
    var chunks: [SIMD3<Int32>: SculptChunk] = [:]
    var dirty: Set<SIMD3<Int32>> = []

    /// meshes the renderer has yet to take, nil for bricks whose surface went away
    var uploads: [SIMD3<Int32>: SculptChunk?] = [:]
    /// set when every mesh changed at once, the renderer starts over
    var meshReset = true

    var pencil: [SculptPencilStroke] = []
    var pencilRevision = 0

    /// bumped on every change the viewport shows
    var revision = 0

    /// where the brush ring sits on the surface and how wide it is
    typealias Ring = (center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float)

    /// the brush under the pointer, for the ring the viewport draws
    var cursor: Ring?

    /// the newest pointer of a stroke the worker is laying, the ring follows it ahead of the worker
    private var aim: SculptPointer?

    weak var layout: Layout?
    weak var viewport: SculptView?

    private var undoStack: [SculptStep] = []
    private var redoStack: [SculptStep] = []
    /// a pencil stroke in progress, drawn on the main thread
    private var stroke: Stroke?
    private var pending: [SculptPointer] = []

    /// lays volume strokes on a queue of its own, while one runs the volume is its alone
    let stroker = SculptStroker()
    private var volumeStroke = false
    private var writeTimer: Timer?

    /// a stroke in progress
    private struct Stroke
    {
      var brush: SculptBrush
      var invert: Bool
      var record: [SIMD3<Int32>: SculptBrickState] = [:]
      var touched: Set<SIMD3<Int32>> = []
      var anchor: SIMD3<Float>
      var last: SIMD3<Float>
      var steady: SIMD3<Float>
      var radius: Float
      var travelled: Float = 0
      /// where the last dab went, so tube segments join end to end
      var dabbed: SIMD3<Float>?
      var pencil: SculptPencilStroke?
      var began = Date()
    }

    init()
    {
      volume = SculptVolume(voxel: SculptDetail.standard.voxel)
      if let path = Kraken.parseArgs().sculptReference { loadReference(URL(fileURLWithPath: path)) }
      stroker.deliver =
      { [weak self] in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.absorb() } }
      }
    }

    var isStroking: Bool
    {
      stroke != nil || volumeStroke
    }

    /// waits for the stroke worker and takes in what it made, before the main thread touches the volume
    func settle()
    {
      guard !stroker.isIdle else { return absorb() }
      stroker.wait()
      absorb()
    }

    /// the face count as meshes arrive, published only once a stroke ends so panels don't rebuild mid stroke
    private var faceTally = 0

    /// the meshes, brush ring and undo step the stroke worker handed over
    func absorb()
    {
      var settled = !volumeStroke
      for news in stroker.collect()
      {
        for (k, mesh) in news.meshes
        {
          faceTally += (mesh?.indices.count ?? 0) / 3 - (chunks[k]?.indices.count ?? 0) / 3
          chunks[k] = mesh
          uploads.updateValue(mesh, forKey: k)
        }

        if !news.meshes.isEmpty { revision += 1 }
        if let ring = news.cursor { cursor = volumeStroke ? ringUnderPointer(ring) : ring }
        if news.done { settled = true }
        if let record = news.record
        {
          push(.volume(record))
          scheduleWrite()
        }
      }

      if settled, faceTally != surfaceFaces { surfaceFaces = faceTally }
    }

    var canUndo: Bool
    {
      !undoStack.isEmpty
    }

    /// the paint color brushes lay down, gloss in alpha
    var paintBytes: SIMD4<UInt8>
    {
      let c = simd_clamp(paint, .zero, SIMD3(repeating: 1)) * 255
      return SIMD4(UInt8(c.x.rounded()), UInt8(c.y.rounded()), UInt8(c.z.rounded()), UInt8((min(max(gloss, 0), 1) * 255).rounded()))
    }

    // MARK: setup

    /// meshes every brick on whichever queue made the volume, so the sculpt shows as it opens
    nonisolated static func meshAll(_ volume: SculptVolume) -> [SIMD3<Int32>: SculptChunk]
    {
      let keys = Array(volume.bricks.keys)
      var out: [SIMD3<Int32>: SculptChunk] = [:]
      out.reserveCapacity(keys.count)
      for (k, mesh) in zip(keys, SculptMesher.mesh(volume, keys)) { if let mesh { out[k] = mesh } }
      return out
    }

    func adopt(_ next: SculptVolume, pencil strokes: [SculptPencilStroke], path: String, unit: Float = 1,
               frame: simd_float4x4 = matrix_identity_float4x4, meshed: [SIMD3<Int32>: SculptChunk]? = nil)
    {
      settle()
      volume = next
      pencil = strokes
      primPath = path
      self.unit = unit
      self.frame = frame
      followVoxel()
      undoStack.removeAll()
      redoStack.removeAll()
      pencilRevision += 1
      guard let meshed else { return remeshAll() }

      chunks = meshed
      faceTally = meshed.values.reduce(0) { $0 + $1.indices.count / 3 }
      surfaceFaces = faceTally
      uploads.removeAll()
      meshReset = true
      dirty.removeAll()
      revision += 1
    }

    func remeshAll()
    {
      chunks.removeAll()
      faceTally = 0
      surfaceFaces = 0
      uploads.removeAll()
      meshReset = true
      dirty = Set(volume.bricks.keys)
      revision += 1
    }

    // MARK: strokes

    /// the brush a stroke uses, smoothing while shift is held
    private func activeBrush(_ pointer: SculptPointer) -> SculptBrush
    {
      pointer.smooth && brush != .pencil ? .smooth : brush
    }

    /// where a pencil or tube point lands, on the surface or on the plane facing the camera
    private func place(_ pointer: SculptPointer, near: SIMD3<Float>?) -> SIMD3<Float>?
    {
      if let hit = volume.raycast(origin: pointer.origin, direction: pointer.direction)
      {
        return placement == .surface ? hit + volume.normal(hit) * volume.voxel : hit
      }

      guard placement == .view || near != nil else { return nil }
      return pointer.onPlane(through: near ?? .zero)
    }

    /// starts a stroke, false when the pointer missed and the viewport should turn instead
    func begin(_ pointer: SculptPointer) -> Bool
    {
      // an empty viewport turns the view until a mesh is added or selected, and a remesh holds strokes off
      guard primPath != nil, !isRemeshing else { return false }

      let brush = activeBrush(pointer)
      let invert = pointer.invert != self.invert

      if brush == .pencil
      {
        if invert { return erasePencil(pointer) }
        guard let p = place(pointer, near: placement == .view ? cursor?.center ?? .zero : nil) else { return false }

        var line = SculptPencilStroke(color: SIMD3<Float>(pencilColor), opacity: Float(pencilOpacity))
        line.points.append(p)
        line.widths.append(pencilWidthAt(pointer, p))
        stroke = Stroke(brush: brush, invert: false, anchor: p, last: p, steady: p, radius: 0, pencil: line)
        pencilRevision += 1
        revision += 1
        return true
      }

      // the last stroke may still be finishing, and edits since may have changed any brick, so none counts as settled
      settle()
      volume.generation &+= 1

      let hit = volume.raycast(origin: pointer.origin, direction: pointer.direction)
      guard let start = hit ?? (brush == .tube && placement == .view ? pointer.onPlane(through: cursor?.center ?? .zero) : nil)
      else { return false }

      let settings = SculptStrokeSettings(brush: brush, invert: invert, radius: Float(radius), strength: Float(strength),
                                          falloff: falloff, mirror: mirror, lazy: Float(lazy), pressureSize: pressureSize,
                                          pressureStrength: pressureStrength, paint: paintBytes,
                                          paintsWhileSculpting: paintsWhileSculpting)
      redoStack.removeAll()
      volumeStroke = true
      aim = pointer
      stroker.start(volume, settings, pointer, at: start)
      return true
    }

    /// queues a pointer move, the next frame works through them
    func move(_ pointer: SculptPointer)
    {
      if volumeStroke
      {
        aim = pointer
        if let ring = cursor { cursor = ringUnderPointer(ring) }
        return stroker.move(pointer)
      }
      guard stroke != nil else
      {
        hover(pointer)
        return
      }

      pending.append(pointer)
    }

    /// shows the brush ring where the pointer rests
    func hover(_ pointer: SculptPointer)
    {
      // a stroke still finishing has the volume, the ring waits for it
      guard stroker.isIdle else { return }
      guard let hit = volume.raycast(origin: pointer.origin, direction: pointer.direction) else
      {
        cursor = nil
        return
      }

      // the ring moves through the view's own uniforms, no wider than the volume lets a brush reach
      let r = min(Float(radius) * pointer.pixelSize(at: hit), volume.widestBrush)
      cursor = (hit, volume.normal(hit), r)
    }

    /// the ring slid across its last surface to the pointer, so it keeps up between the worker's reports
    private func ringUnderPointer(_ ring: Ring) -> Ring
    {
      guard let aim else { return ring }

      let facing = simd_dot(aim.direction, ring.normal)
      guard abs(facing) > 0.05 else { return ring }

      // a grazing ray meets the plane far off the surface, the ring then waits where it was
      let p = aim.origin + aim.direction * (simd_dot(ring.center - aim.origin, ring.normal) / facing)
      guard simd_dot(p - aim.origin, aim.direction) > 0, simd_distance(p, ring.center) < ring.radius * 4 else { return ring }
      return (p, ring.normal, ring.radius)
    }

    /// finishes the stroke as one undo step
    func end()
    {
      aim = nil
      if volumeStroke
      {
        // the worker finishes the moves still queued, tidies up and hands back the undo step
        volumeStroke = false
        stroker.finish()
        return
      }

      step()
      guard let finished = stroke else { return }
      stroke = nil

      if let line = finished.pencil
      {
        guard line.points.count > 1 else { return }
        undoStack.append(.pencil(pencil))
        pencil.append(line)
        pencilRevision += 1
        revision += 1
        scheduleWrite()
        return
      }

    }

    /// drops the stroke in progress as if it never happened, for a second finger landing late
    func cancel()
    {
      aim = nil
      if volumeStroke
      {
        volumeStroke = false
        stroker.cancel()
        return
      }

      guard stroke != nil else { return }
      stroke = nil
      pending.removeAll()
      pencilRevision += 1
      revision += 1
    }

    /// the pencil stroke being drawn, shown before it is kept
    var drawingPencil: SculptPencilStroke?
    {
      stroke?.pencil
    }

    private func pencilWidthAt(_ pointer: SculptPointer, _ p: SIMD3<Float>) -> Float
    {
      let scale = pressureSize ? 0.25 + 0.75 * pointer.pressure : 1
      return Float(pencilWidth) * scale * pointer.pixelSize(at: p)
    }

    /// removes the pencil strokes under the pointer
    private func erasePencil(_ pointer: SculptPointer) -> Bool
    {
      let reach = Float(radius) * pointer.pixelSize(at: cursor?.center ?? pointer.origin + pointer.direction * 3)
      let kept = pencil.filter
      { line in
        !line.points.contains
        { p in
          let v = p - pointer.origin
          let along = simd_dot(v, pointer.direction)
          return simd_length(v - pointer.direction * along) < reach
        }
      }

      guard kept.count != pencil.count else { return true }
      undoStack.append(.pencil(pencil))
      pencil = kept
      pencilRevision += 1
      revision += 1
      scheduleWrite()
      return true
    }

    // MARK: frames

    /// works through queued moves and remeshes what changed, once per frame
    func step()
    {
      absorb()

      // pencil points are cheap, every queued one goes in
      if !pending.isEmpty
      {
        let moves = pending
        pending.removeAll()
        for pointer in moves { followPencil(pointer) }
      }

      // edits made on the main thread remesh here, a running stroke remeshes on its own queue
      if stroker.isIdle { remesh() }
    }

    /// adds a pencil point where the pointer lands
    private func followPencil(_ pointer: SculptPointer)
    {
      guard var current = stroke else { return }
      guard let p = place(pointer, near: current.last), simd_distance(p, current.last) > volume.voxel * 0.5 else { return }
      current.pencil?.points.append(p)
      current.pencil?.widths.append(pencilWidthAt(pointer, p))
      current.last = p
      stroke = current
      revision += 1
    }

    // MARK: meshing

    /// marks bricks to remesh, with the neighbors whose meshes read them
    func markDirty(_ keys: [SIMD3<Int32>])
    {
      for k in keys
      {
        for z: Int32 in -1 ... 1
        {
          for y: Int32 in -1 ... 1
          {
            for x: Int32 in -1 ... 1
            {
              let n = k &+ SIMD3(x, y, z)
              if volume.bricks[n] != nil || chunks[n] != nil { dirty.insert(n) }
            }
          }
        }
      }

      revision += 1
    }

    private func remesh()
    {
      guard !dirty.isEmpty else { return }

      let keys = Array(dirty)
      dirty.removeAll()
      let meshes = SculptMesher.mesh(volume, keys)
      for (k, mesh) in zip(keys, meshes)
      {
        faceTally += (mesh?.indices.count ?? 0) / 3 - (chunks[k]?.indices.count ?? 0) / 3
        chunks[k] = mesh
        uploads.updateValue(mesh, forKey: k)
      }

      if faceTally != surfaceFaces { surfaceFaces = faceTally }
      revision += 1
    }

    /// the mesh the scene holds for the sculpt, its own until the first stroke and the thinned sculpt after each write
    @Published var counts = (vertices: 0, faces: 0)

    /// counts for the status bar
    var statistics: (bricks: Int, triangles: Int)
    {
      (volume.bricks.count, chunks.values.reduce(0) { $0 + $1.indices.count / 3 })
    }

    // MARK: undo

    /// keeps a step for undo, for changes made outside this file
    func pushStep(_ step: SculptStep)
    {
      push(step)
    }

    private func push(_ step: SculptStep)
    {
      undoStack.append(step)
      if undoStack.count > 48 { undoStack.removeFirst() }
      redoStack.removeAll()
    }

    func undo()
    {
      settle()
      guard !isStroking, !isRemeshing, let step = undoStack.popLast() else
      {
        status = "Nothing to undo"
        return
      }

      redoStack.append(revert(step))
      scheduleWrite()
    }

    func redo()
    {
      settle()
      guard !isStroking, !isRemeshing, let step = redoStack.popLast() else
      {
        status = "Nothing to redo"
        return
      }

      undoStack.append(revert(step))
      scheduleWrite()
    }

    /// puts a step back and gives the step that would put it forward again
    private func revert(_ step: SculptStep) -> SculptStep
    {
      switch step
      {
        case let .volume(states):
          var inverse: [SIMD3<Int32>: SculptBrickState] = [:]
          for (k, state) in states
          {
            inverse[k] = volume.state(k)
            volume.restore(k, state)
          }

          markDirty(Array(states.keys))
          return .volume(inverse)

        case let .pencil(strokes):
          let inverse = SculptStep.pencil(pencil)
          pencil = strokes
          pencilRevision += 1
          revision += 1
          return inverse

        case let .whole(next, strokes):
          let inverse = SculptStep.whole(volume, pencil)
          volume = next
          followVoxel()
          pencil = strokes
          pencilRevision += 1
          remeshAll()
          return inverse
      }
    }

    /// runs a change to the whole volume as one undo step
    private func wholeEdit(_ body: () -> Void)
    {
      guard !isRemeshing else { return }
      settle()
      let kept = SculptVolume(voxel: volume.voxel)
      kept.base = volume.base
      kept.bricks = volume.bricks.mapValues { SculptBrick(copy: $0) }
      kept.inside = volume.inside
      push(.whole(kept, pencil))
      body()
      scheduleWrite()
    }

    // MARK: operations

    /// puts the chosen shape where the brush last was, facing the surface
    func insertShape()
    {
      guard primPath != nil else { return }
      settle()

      let center = cursor?.center ?? .zero
      let normal = cursor?.normal ?? SIMD3(0, 1, 0)
      let size = max(cursor?.radius ?? 0.15, volume.voxel * 4)
      let up = SIMD3<Float>(0, 1, 0)
      let facing = simd_normalize(normal)
      let turn = simd_dot(facing, up) < -0.999 ? simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)) : simd_quatf(from: up, to: facing)
      var world = simd_float4x4(turn)
      world.columns.3 = SIMD4(center + (combine == .add ? normal * size * 0.4 : .zero), 1)

      var record: [SIMD3<Int32>: SculptBrickState] = [:]
      let dims: SIMD3<Float> = switch shape
      {
        case .box: SIMD3(size, size * 0.5, size)
        case .cylinder, .capsule: SIMD3(size * 0.5, size, size * 0.5)
        case .torus: SIMD3(size, size * 0.25, size)
        case .sphere: SIMD3(repeating: size)
      }

      var placements = [world]
      for axis in 0 ..< 3 where mirror[axis]
      {
        placements += placements.map
        { m in
          var flip = matrix_identity_float4x4
          flip[axis][axis] = -1
          return flip * m * flip
        }
      }

      var touched: [SIMD3<Int32>] = []
      for m in placements
      {
        touched += volume.insert(shape, size: dims, world: m, combine: combine, color: paintBytes, paints: paintsWhileSculpting)
        { k, make in
          if record[k] == nil { record[k] = make() }
        }
      }

      volume.compact(touched)
      markDirty(touched)
      push(.volume(record))
      status = "Added \(shape.rawValue)"
      scheduleWrite()
    }

    // MARK: remesh

    /// the finest and coarsest voxel a remesh makes, as a share of the sculpt's unit. a phone holds fewer bricks
    static let finest: Float = FormFactor.current == .touch ? 0.0025 : 0.0015
    static let coarsest: Float = 0.05

    /// how far one step of more or less detail moves the voxel size
    static let detailStep: Float = 1.5

    /// the voxel sizes a remesh can make, in the sculpt's own units
    var voxelRange: ClosedRange<Double>
    {
      Double(Self.finest * unit) ... Double(Self.coarsest * unit)
    }

    /// the detail level the sculpt is at, or custom between them
    var detailName: String
    {
      let share = volume.voxel / unit
      return SculptDetail.allCases.first { abs($0.voxel / share - 1) < 0.02 }?.rawValue ?? "Custom"
    }

    /// a voxel size written short enough for a header
    static func format(voxel: Double) -> String
    {
      String(format: "%.3g", voxel)
    }

    /// keeps the detail readouts on the volume's voxel after it changed under them
    private func followVoxel()
    {
      detail = SculptDetail.nearest(volume.voxel / unit)
      remeshVoxel = Double(volume.voxel)
    }

    /// remeshes at one of the detail levels
    func setDetail(_ next: SculptDetail)
    {
      remesh(voxel: next.voxel * unit)
    }

    /// remeshes with smaller voxels, more surface everywhere
    func addDetail()
    {
      remesh(voxel: volume.voxel / Self.detailStep)
    }

    /// remeshes with bigger voxels, a lighter surface
    func reduceDetail()
    {
      remesh(voxel: volume.voxel * Self.detailStep)
    }

    /// remeshes at the voxel size set in the remesh panel
    func remeshAtPanelSize()
    {
      remesh(voxel: Float(remeshVoxel))
    }

    /// resamples the sculpt at another voxel size as one undo step, off the main thread while strokes wait
    func remesh(voxel wanted: Float)
    {
      guard primPath != nil, !isRemeshing else { return }
      settle()
      guard !isStroking else { return }

      let next = min(max(wanted, Self.finest * unit), Self.coarsest * unit)
      remeshVoxel = Double(next)
      guard abs(next / volume.voxel - 1) > 0.001 else
      {
        status = wanted < next ? "Already at the finest detail" : wanted > next ? "Already at the coarsest detail"
          : "Already at voxel size \(Self.format(voxel: Double(next)))"
        return
      }

      let old = volume
      isRemeshing = true
      status = "Remeshing at voxel size \(Self.format(voxel: Double(next)))"

      DispatchQueue.global(qos: .userInitiated).async
      { [weak self] in
        let out = old.resampled(voxel: next)
        DispatchQueue.main.async
        {
          MainActor.assumeIsolated
          {
            guard let self else { return }
            self.isRemeshing = false

            // another mesh was picked meanwhile, the old one keeps its volume
            guard self.volume === old else { return }
            self.push(.whole(old, self.pencil))
            self.volume = out
            self.followVoxel()
            self.remeshAll()
            self.scheduleWrite()
            self.status = "Remeshed at voxel size \(Self.format(voxel: Double(next))), \(self.detailName) detail"
          }
        }
      }
    }

    /// smooths the whole surface a little
    func smoothAll()
    {
      wholeEdit
      {
        let keys = Array(volume.bricks.keys)
        let source = volume.snapshot(keys)
        volume.edit(keys)
        { v in
          guard v.mask < 255 else { return }
          let g = v.g
          let sum = source.distance(g &+ SIMD3(1, 0, 0)) + source.distance(g &- SIMD3(1, 0, 0))
            + source.distance(g &+ SIMD3(0, 1, 0)) + source.distance(g &- SIMD3(0, 1, 0))
            + source.distance(g &+ SIMD3(0, 0, 1)) + source.distance(g &- SIMD3(0, 0, 1))
          v.d += (sum / 6 - v.d) * 0.5 * (1 - Float(v.mask) / 255)
        }

        remeshAll()
      }
    }

    func clearMask()
    {
      editMask { _ in 0 }
    }

    func invertMask()
    {
      editMask { 255 - $0 }
    }

    private func editMask(_ change: @escaping (UInt8) -> UInt8)
    {
      wholeEdit
      {
        volume.edit(Array(volume.bricks.keys)) { v in v.mask = change(v.mask) }
        remeshAll()
      }
    }

    /// paints the whole surface the current color
    func fillPaint()
    {
      let color = paintBytes
      wholeEdit
      {
        volume.edit(Array(volume.bricks.keys))
        { v in
          let free = 1 - Float(v.mask) / 255
          let kept = SIMD4<Float>(v.color) * (1 - free)
          let laid = SIMD4<Float>(color) * free
          v.color = SIMD4<UInt8>((kept + laid).rounded(.toNearestOrAwayFromZero))
        }

        volume.base = color
        remeshAll()
      }
    }

    /// swaps the pencil strokes, as one undo step
    func replacePencil(_ strokes: [SculptPencilStroke])
    {
      undoStack.append(.pencil(pencil))
      pencil = strokes
      pencilRevision += 1
      revision += 1
      scheduleWrite()
    }

    func clearPencil()
    {
      guard !pencil.isEmpty else { return }
      undoStack.append(.pencil(pencil))
      pencil = []
      pencilRevision += 1
      revision += 1
      scheduleWrite()
    }

    /// replaces the sculpt with a volume made elsewhere, as one undo step
    func replace(with next: SculptVolume)
    {
      wholeEdit
      {
        volume = next
        followVoxel()
        frameRequest += 1
        remeshAll()
      }
    }

    // MARK: writing

    /// writes the sculpt into the scene shortly after the last change
    func scheduleWrite()
    {
      writeTimer?.invalidate()
      let timer = Timer(timeInterval: 0.6, repeats: false)
      { [weak self] _ in
        MainActor.assumeIsolated { self?.write() }
      }

      RunLoop.main.add(timer, forMode: .common)
      writeTimer = timer
    }

    /// writes a change still waiting, for saving and leaving the tab. `now` does the work before returning
    func flush(now: Bool = false)
    {
      guard writeTimer != nil else { return }
      writeTimer?.invalidate()
      write(now: now)
    }

    /// writes straight away, from the panel's button
    func writeNow()
    {
      writeTimer?.invalidate()
      write()
    }

    private func write(now: Bool = false)
    {
      // the write reads the volume and its meshes, a stroke still finishing goes in first
      settle()
      writeTimer = nil
      guard let layout, primPath != nil else { return }
      layout.writeSculpt(self, now: now)
    }
  }
}

extension Kraken.SculptVolume
{
  /// the surface direction averaged over the patch a brush covers, steadier than a gradient that would read past the band
  func normal(_ p: SIMD3<Float>, scale: Float) -> SIMD3<Float>
  {
    let center = normal(p)
    guard scale > voxel * 2 else { return center }

    let a = simd_normalize(abs(center.x) < 0.9 ? simd_cross(center, SIMD3(1, 0, 0)) : simd_cross(center, SIMD3(0, 1, 0)))
    let b = simd_cross(center, a)
    var sum = center
    for ring in 1 ... 3
    {
      let out = scale * Float(ring) / 3
      let count = 6 * ring
      for k in 0 ..< count
      {
        let turn = Float(k) / Float(count) * 2 * .pi
        let q = p + (a * cos(turn) + b * sin(turn)) * out
        let d = sample(q)
        guard abs(d) < band * 0.99 else { continue }
        sum += normal(q - center * d) * (1 - Float(ring) / 4)
      }
    }

    let length = simd_length(sum)
    return length > 1e-9 ? sum / length : center
  }
}
