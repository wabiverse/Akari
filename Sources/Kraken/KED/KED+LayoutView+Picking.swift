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
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI
#if os(macOS)
  import AppKit
#endif

#if os(macOS)
  extension Kraken.LayoutView
  {
    func click(_ p: CGPoint, extend: Bool)
    {
      if layout.tool == .cursor
      {
        placeCursor(p)
        return
      }

      if layout.mode == .edit
      {
        editClick(p, extend: extend)
        return
      }

      if let path = widgetHit(p)
      {
        layout.select([path], extend: extend)
        return
      }

      let hydra = layout.hydra
      let viewPoint = CGPoint(x: p.x, y: bounds.height - p.y)
      hydra.pick(at: viewPoint, viewSize: bounds.size)
      { [weak self] result in
        MainActor.assumeIsolated
        {
          guard let self else { return }
          if let result
          {
            self.layout.picked(String((result.isInstance ? result.instancerPath : result.primPath).GetAsString()),
                               extend: extend)
          }
          else
          {
            self.awaitAovPick(tries: 12, extend: extend)
          }
        }
      }
    }

    /// Akari answers a click from its prim ID buffer a frame or so later.
    private func awaitAovPick(tries: Int, extend: Bool)
    {
      if let path = layout.hydra.lastPickedPath
      {
        layout.picked(String(path.GetAsString()), extend: extend)
        return
      }

      guard tries > 0 else
      {
        layout.picked(nil, extend: extend)
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04)
      { [weak self] in
        self?.awaitAovPick(tries: tries - 1, extend: extend)
      }
    }

    private func widgetHit(_ p: CGPoint) -> String?
    {
      var best: (String, CGFloat)?
      for widget in widgetHits
      {
        let d = Self.distance(p, widget.points)
        if d < 8, d < (best?.1 ?? .infinity) { best = (widget.path, d) }
      }

      return best?.0
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat
    {
      let dx = b.x - a.x, dy = b.y - a.y
      let length = dx * dx + dy * dy
      let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
      return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    /// Distance to a run of segments, pairs of points.
    static func distance(_ p: CGPoint, _ segments: [CGPoint]) -> CGFloat
    {
      var best = CGFloat.infinity
      var i = 0
      while i + 1 < segments.count
      {
        best = min(best, distance(p, segments[i], segments[i + 1]))
        i += 2
      }

      return best
    }

    func placeCursor(_ p: CGPoint)
    {
      guard let camera else { return }
      let ray = camera.ray(p)
      if let hit = Self.hit(.zero, layout.up, ray), simd_dot(hit - ray.origin, ray.direction) > 0
      {
        layout.cursor = hit
      }
      else if let hit = Self.hit(layout.cursor, camera.forward, ray)
      {
        layout.cursor = hit
      }
    }

    func select(in rect: CGRect, extend: Bool)
    {
      guard let camera else { return }
      if layout.mode == .edit
      {
        guard var mesh = layout.mesh else { return }
        let view = EditView(mesh, layout.meshWorld, camera, xray: layout.xray)
        if !extend { mesh.clearSelection() }
        switch mesh.mode
        {
          case .vertex:
            for v in mesh.points.indices where view.visible[v]
            {
              if let q = view.screen[v], rect.contains(q) { mesh.verts.insert(v) }
            }
          case .edge:
            for e in mesh.allEdges where view.sees(e)
            {
              if let a = view.screen[e.a], let b = view.screen[e.b], rect.contains(a), rect.contains(b) { mesh.edges.insert(e) }
            }
          case .face:
            for f in mesh.faces.indices where view.front[f]
            {
              if let q = camera.project(view.centers[f]), rect.contains(q) { mesh.selectedFaces.insert(f) }
            }
        }

        mesh.flush()
        layout.mesh = mesh
        return
      }

      let extra = layout.selection
      layout.selectable
      { [weak self] all in
        guard let self else { return }
        let inside = all.filter { camera.project($0.center).map(rect.contains) ?? false }.map(\.path)
        self.layout.select(extend ? extra + inside.filter { !extra.contains($0) } : inside)
      }
    }

    /// The edit mesh as it sits on screen this frame.
    struct EditView
    {
      var screen: [CGPoint?]
      var world: [SIMD3<Double>]
      var front: [Bool]
      var visible: [Bool]
      var centers: [SIMD3<Double>]
      let camera: Kraken.ViewCamera
      let xray: Bool
      var depth: [Float] = []
      var columns = 0
      private var rows = 0

      private static let cell: CGFloat = 3

      init(_ mesh: Kraken.EditMesh, _ matrix: simd_double4x4, _ camera: Kraken.ViewCamera, xray: Bool)
      {
        self.camera = camera
        self.xray = xray
        let points = mesh.points.map
        {
          let p = matrix * SIMD4(SIMD3<Double>($0), 1)
          return SIMD3(p.x, p.y, p.z)
        }

        world = points
        screen = points.map(camera.project)
        centers = mesh.faces.map
        { face in
          face.reduce(SIMD3<Double>.zero) { $0 + points[$1] } / Double(max(face.count, 1))
        }

        front = [Bool](repeating: true, count: mesh.faces.count)
        visible = [Bool](repeating: true, count: mesh.points.count)
        guard !xray else { return }
        rasterize(mesh)
        let view = self
        visible = points.map { view.sees($0) }
        front = centers.map { view.sees($0) }
      }

      private func depthOf(_ p: SIMD3<Double>) -> Double
      {
        camera.perspective ? simd_dot(p - camera.eye, camera.forward) : simd_dot(p, camera.forward)
      }

      /// The mesh's own nearest depth per few pixels, what hides its far side.
      private mutating func rasterize(_ mesh: Kraken.EditMesh)
      {
        columns = Int(camera.size.width / Self.cell) + 1
        rows = Int(camera.size.height / Self.cell) + 1
        depth = [Float](repeating: .infinity, count: columns * rows)
        let d = world.map { Float(depthOf($0)) }
        for face in mesh.faces where face.count >= 3
        {
          for k in 1 ..< face.count - 1
          {
            let corners = [face[0], face[k], face[k + 1]]
            guard let a = screen[corners[0]], let b = screen[corners[1]], let c = screen[corners[2]] else { continue }
            let ax = Float(a.x / Self.cell), ay = Float(a.y / Self.cell)
            let bx = Float(b.x / Self.cell), by = Float(b.y / Self.cell)
            let cx = Float(c.x / Self.cell), cy = Float(c.y / Self.cell)
            let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            guard abs(area) > 1e-6 else { continue }
            let x0 = max(Int(min(ax, bx, cx)), 0), x1 = min(Int(max(ax, bx, cx)) + 1, columns - 1)
            let y0 = max(Int(min(ay, by, cy)), 0), y1 = min(Int(max(ay, by, cy)) + 1, rows - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            let da = d[corners[0]], db = d[corners[1]], dc = d[corners[2]]
            for y in y0 ... y1
            {
              for x in x0 ... x1
              {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let w0 = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area
                let w1 = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area
                let w2 = 1 - w0 - w1
                guard w0 >= -0.02, w1 >= -0.02, w2 >= -0.02 else { continue }
                let z = w0 * da + w1 * db + w2 * dc
                let i = y * columns + x
                if z < depth[i] { depth[i] = z }
              }
            }
          }
        }
      }

      /// Whether a point of the mesh is in front of the rest of it.
      func sees(_ p: SIMD3<Double>) -> Bool
      {
        guard !xray, !depth.isEmpty else { return true }
        guard let q = camera.project(p) else { return false }
        let x = Int(q.x / Self.cell), y = Int(q.y / Self.cell)
        guard x >= 0, y >= 0, x < columns, y < rows else { return true }
        let z = Float(depthOf(p))
        return z <= depth[y * columns + x] + max(abs(z) * 0.01, 1e-4)
      }

      func sees(_ e: Kraken.Edge) -> Bool
      {
        sees((world[e.a] + world[e.b]) * 0.5)
      }
    }

    private func editClick(_ p: CGPoint, extend: Bool)
    {
      guard var mesh = layout.mesh, let camera else { return }
      let view = EditView(mesh, layout.meshWorld, camera, xray: layout.xray)
      switch mesh.mode
      {
        case .vertex:
          var best: (Int, CGFloat)?
          for v in mesh.points.indices where view.visible[v]
          {
            guard let q = view.screen[v] else { continue }
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < 16, d < (best?.1 ?? .infinity) { best = (v, d) }
          }

          if let best { mesh.toggle(vertex: best.0, extend: extend) } else if !extend { mesh.clearSelection() }
        case .edge:
          if let e = edge(near: p, mesh, view) { mesh.toggle(edge: e, extend: extend) }
          else if !extend { mesh.clearSelection() }
        case .face:
          var best: (Int, Double)?
          for (f, face) in mesh.faces.enumerated() where view.front[f]
          {
            let polygon = face.compactMap { view.screen[$0] }
            guard polygon.count == face.count, Self.contains(polygon, p) else { continue }
            let depth = simd_distance(view.centers[f], camera.eye)
            if depth < (best?.1 ?? .infinity) { best = (f, depth) }
          }

          if let best { mesh.toggle(face: best.0, extend: extend) } else if !extend { mesh.clearSelection() }
      }

      layout.mesh = mesh
    }

    func edge(near p: CGPoint, _ mesh: Kraken.EditMesh, _ view: EditView) -> Kraken.Edge?
    {
      var best: (Kraken.Edge, CGFloat)?
      for e in mesh.allEdges where view.sees(e)
      {
        guard let a = view.screen[e.a], let b = view.screen[e.b] else { continue }
        let d = Self.distance(p, a, b)
        if d < 12, d < (best?.1 ?? .infinity) { best = (e, d) }
      }

      return best?.0
    }

    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool
    {
      var inside = false
      var j = polygon.count - 1
      for i in polygon.indices
      {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
      }

      return inside
    }

    /// Alt click, the edge loop under the pointer.
    func selectLoop(at p: CGPoint, extend: Bool)
    {
      guard var mesh = layout.mesh, let camera else { return }
      let view = EditView(mesh, layout.meshWorld, camera, xray: layout.xray)
      guard let e = edge(near: p, mesh, view) else { return }
      mesh.selectLoop(e, extend: extend)
      layout.mesh = mesh
    }

    func linkedUnderMouse()
    {
      guard var mesh = layout.mesh, let camera else { return }
      let view = EditView(mesh, layout.meshWorld, camera, xray: layout.xray)
      var best: (Int, CGFloat)?
      for v in mesh.points.indices where view.visible[v]
      {
        guard let q = view.screen[v] else { continue }
        let d = hypot(q.x - mouse.x, q.y - mouse.y)
        if d < (best?.1 ?? .infinity) { best = (v, d) }
      }

      guard let best else { return }
      mesh.selectLinked(from: [best.0])
      mesh.flush()
      layout.mesh = mesh
    }

    func updateLoopCut()
    {
      guard let mesh = layout.mesh, let camera else
      {
        loopCut = nil
        return
      }

      let view = EditView(mesh, layout.meshWorld, camera, xray: layout.xray)
      loopCut = edge(near: mouse, mesh, view).map { ($0, mesh.ring($0)) }
    }
  }
#endif
