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

extension Kraken.EditMesh
{
  /// a crease of 1 holds an edge hard through subdivision, the same as a usd crease sharpness of 10
  static let creaseSharpness: Float = 10

  /// the selected edges, in vertex mode the ones with both verts selected
  var selectedEdgeList: [Kraken.Edge]
  {
    let present = Set(allEdges)
    return edges.filter(present.contains).sorted { ($0.a, $0.b) < ($1.a, $1.b) }
  }

  /// sets every selected edge's crease, 0 clears it
  mutating func setCrease(_ value: Float)
  {
    let c = min(max(value, 0), 1)
    for e in selectedEdgeList { creases[e] = c > 0 ? c : nil }
  }

  /// shifts every selected edge's crease from where `original` had it, as a shift e drag does
  mutating func shiftCrease(by amount: Float, from original: [Kraken.Edge: Float])
  {
    for e in selectedEdgeList
    {
      let c = min(max((original[e] ?? 0) + amount, 0), 1)
      creases[e] = c > 0 ? c : nil
    }
  }

  /// marks the selected edges sharp, or clears them
  mutating func markSharp(_ on: Bool)
  {
    let chosen = Set(selectedEdgeList)
    if on { sharp.formUnion(chosen) } else { sharp.subtract(chosen) }
  }

  /// selects the edges whose two faces meet at more than `angle` degrees
  mutating func selectSharp(angle: Float = 30)
  {
    let limit = cos(angle * .pi / 180)
    let found = allEdges.filter
    { e in
      guard let s = side(e) else { return false }
      let around = topology.facesAround(s)
      guard around.count == 2 else { return false }
      return simd_dot(normal(topology.corners(of: around[0])), normal(topology.corners(of: around[1]))) < limit
    }

    clearSelection()
    edges = Set(found)
    verts = Set(found.flatMap { [$0.a, $0.b] })
    selectedFaces = Set(faces.indices.filter { Self.edges(of: faces[$0]).allSatisfy(edges.contains) })
  }

  /// edges split at a new middle vert carry their crease and sharpness on to both halves
  mutating func inherit(_ middles: [Kraken.Edge: Int])
  {
    for (e, m) in middles
    {
      if let c = creases[e]
      {
        creases[Kraken.Edge(e.a, m)] = c
        creases[Kraken.Edge(m, e.b)] = c
      }

      if sharp.contains(e)
      {
        sharp.insert(Kraken.Edge(e.a, m))
        sharp.insert(Kraken.Edge(m, e.b))
      }
    }
  }
}
