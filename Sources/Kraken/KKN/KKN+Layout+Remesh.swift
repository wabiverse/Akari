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
import HdAkari
import HydraKit
import simd

extension Kraken.Layout
{
  /// rebuilds each selected mesh as clean quads following its shape and sharp edges, off the main thread, one undo step
  func remesh(faces: Int, symmetry: Int? = nil)
  {
    let paths = selection
    guard !paths.isEmpty else { return }

    status = "Remeshing"
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      var inputs: [(path: String, points: [Float], counts: [Int32], indices: [Int32])] = []
      for path in paths where Kraken.SceneEdit.isMesh(stage, path)
      {
        let mesh = Kraken.SceneEdit.mesh(stage, path, time)
        if mesh.valid && !mesh.counts.isEmpty { inputs.append((path, mesh.points, mesh.counts, mesh.indices)) }
      }

      guard !inputs.isEmpty else
      {
        DispatchQueue.main.async { [weak self] in self?.status = "Remesh needs a selected mesh" }
        return
      }

      let meshes = inputs
      DispatchQueue.global(qos: .userInitiated).async
      { [self] in
        var options = Kraken.Remesh.Options()
        options.faces = faces
        options.symmetry = symmetry
        let built = meshes.map
        { input in
          (path: input.path, result: Kraken.Remesh.run(points: input.points, counts: input.counts, indices: input.indices,
                                                        options: options))
        }

        let results = built.compactMap { b in b.result.map { (path: b.path, result: $0) } }
        let failed = built.count - results.count

        DispatchQueue.main.async
        { [self] in
          guard !results.isEmpty else
          {
            status = "Remesh found nothing to rebuild"
            return
          }

          checkpoint()
          onStage
          { [self] stage in
            for (path, result) in results
            {
              let points = result.points.flatMap { [$0.x, $0.y, $0.z] }
              let sharpness = [Float](repeating: 10, count: result.sharp.count / 2)
              Kraken.Modifiers.clearSession(stage, path)
              Kraken.SceneEdit.setMesh(stage, path, points, result.counts, result.indices, creases: result.sharp,
                                       creaseSharpness: sharpness, sharp: result.sharp)
              Kraken.Modifiers.sync(stage, path, time)
            }

            let summary = results.map
            { r in
              "\(r.result.stats.inputTriangles) tris to \(r.result.stats.quads) quads in "
                + String(format: "%.1f s", r.result.stats.seconds)
            }
            .joined(separator: ", ")
            for r in results { print("remesh \(r.path): \(r.result.stats)") }

            DispatchQueue.main.async
            { [weak self] in
              guard let self else { return }

              self.status = "Remeshed " + summary + (failed > 0 ? ", \(failed) failed" : "")
              self.inspector.reload()
            }
          }
        }
      }
    }
  }
}
