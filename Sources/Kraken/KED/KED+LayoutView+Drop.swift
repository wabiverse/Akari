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
import SwiftCrossUI
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

extension Kraken.LayoutView
{
  /// the dropped asset's bounds where it would land, the surface it's on and what the drop will do
  func drawAssetDrop(_ camera: Kraken.ViewCamera)
  {
    guard let drop = assetDrop, !drop.finished else { return }
    let accent = PlatformColor(red: 1, green: 0.67, blue: 0.25, alpha: 1)
    if let hit = drop.hit
    {
      // a ring lying on the surface under the pointer, and its normal
      let n = simd_normalize(hit.normal)
      let a = simd_normalize(simd_cross(abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0), n))
      let b = simd_cross(n, a)
      let radius = camera.pixelSize(at: hit.point) * 18
      var ring: [CGPoint] = []
      var last: CGPoint?
      for k in 0 ... 32
      {
        let angle = Double(k) / 32 * 2 * .pi
        let q = camera.project(hit.point + (a * cos(angle) + b * sin(angle)) * radius)
        if let last, let q { ring += [last, q] }
        last = q
      }

      stroke(ring, accent, 2)
      if let base = camera.project(hit.point), let tip = camera.project(hit.point + n * radius * 1.6)
      {
        stroke([base, tip], accent, 1.5)
        dot(base, 3, accent)
      }

      if drop.asset?.kind == .material, !hit.path.isEmpty
      {
        stroke(boxEdges(hit.lo, hit.hi, matrix_identity_double4x4, camera), accent.withAlphaComponent(0.9), 1.5, dash: [5, 4])
      }
    }

    if let placed = drop.placed, let asset = drop.asset
    {
      stroke(boxEdges(asset.lo, asset.hi, placed, camera), accent, 1.5)
    }

    text(drop.caption, at: CGPoint(x: drop.point.x + 16, y: drop.point.y + 14), size: 12, color: .white)
  }

  /// the twelve edges of a box from `lo` to `hi` through `m`, as segment pairs on screen
  private func boxEdges(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>, _ m: simd_double4x4, _ camera: Kraken.ViewCamera) -> [CGPoint]
  {
    let corners = (0 ..< 8).map
    { i -> CGPoint? in
      let p = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
      let w = m * SIMD4(p, 1)
      return camera.project(SIMD3(w.x, w.y, w.z))
    }

    var segments: [CGPoint] = []
    for (i, j) in [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
    {
      if let a = corners[i], let b = corners[j] { segments += [a, b] }
    }

    return segments
  }
}

#if os(macOS)
  extension Kraken.LayoutView
  {
    /// takes assets from the browser and usd files from the finder
    func acceptAssetDrops()
    {
      registerForDraggedTypes([.krakenAsset, .fileURL])
    }

    /// the asset a drag carries, or the usd file it brings to be read first
    private func dragged(_ info: NSDraggingInfo) -> (asset: Kraken.LibraryAsset?, file: URL?)?
    {
      let board = info.draggingPasteboard
      if let data = board.data(forType: .krakenAsset), let asset = try? JSONDecoder().decode(Kraken.LibraryAsset.self, from: data)
      {
        return (asset, nil)
      }

      let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      if let file = urls.first(where: { Kraken.AssetScan.extensions.contains($0.pathExtension.lowercased()) })
      {
        return (nil, file)
      }

      return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation
    {
      guard layout.tab != .sculpting, let carried = dragged(sender) else { return [] }
      assetDrop?.cancel()
      let drop = Kraken.AssetDrop(layout: layout, asset: carried.asset)
      drop.view = self
      drop.point = convert(sender.draggingLocation, from: nil)
      assetDrop = drop
      if carried.asset != nil
      {
        drop.begin()
      }
      else if let file = carried.file
      {
        drop.caption = "Reading \(file.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async
        {
          let assets = Kraken.AssetScan.describe(file)
          let asset = assets.first { $0.kind == .model } ?? assets.first
          DispatchQueue.main.async
          { [weak drop] in
            guard let drop, !drop.finished else { return }
            guard let asset else
            {
              drop.caption = "\(file.lastPathComponent) has nothing to place"
              return
            }

            drop.asset = asset
            drop.caption = asset.name
            drop.begin()
            if drop.released { drop.drop() }
          }
        }
      }

      invalidate()
      return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation
    {
      guard let drop = assetDrop, !drop.finished else { return [] }
      drop.move(to: convert(sender.draggingLocation, from: nil), in: self)
      invalidate()
      return .copy
    }

    override func draggingExited(_: NSDraggingInfo?)
    {
      assetDrop?.cancel()
      assetDrop = nil
      invalidate()
    }

    override func prepareForDragOperation(_: NSDraggingInfo) -> Bool
    {
      assetDrop != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool
    {
      guard let drop = assetDrop else { return false }
      drop.move(to: convert(sender.draggingLocation, from: nil), in: self)
      drop.release()
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return true
    }

    override func concludeDragOperation(_: NSDraggingInfo?)
    {
      invalidate()
    }
  }
#endif
