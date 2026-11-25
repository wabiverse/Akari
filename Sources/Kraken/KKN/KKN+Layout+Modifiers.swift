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

extension Kraken.Layout
{
  /// gives every selected mesh a subdivision modifier refining to level, or takes it off at level zero
  func setSubdivision(level: Int)
  {
    let paths = selection
    guard !paths.isEmpty else { return }

    checkpoint()
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      for path in paths
      {
        guard Kraken.SceneEdit.isMesh(stage, path) else { continue }

        let standing = Kraken.Modifiers.read(stage, path).first { $0.kind.isRefinement }
        if level <= 0
        {
          if let standing { Kraken.Modifiers.remove(stage, path, standing.name) }
        }
        else
        {
          let name = standing?.name ?? Kraken.Modifiers.add(stage, path, .subdivision)
          guard let name else { continue }

          Kraken.Modifiers.setLevels(stage, path, name, viewport: level, render: standing == nil ? max(level, 2) : nil)
        }

        Kraken.Modifiers.sync(stage, path, time)
      }

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }

        self.status = level <= 0 ? "Subdivision off" : "Subdivision level \(level)"
        self.inspector.reload()
      }
    }
  }

  /// shades the selected meshes smoothly across their faces, or flat on each one
  func shade(smooth: Bool)
  {
    let paths = selection
    guard !paths.isEmpty else { return }

    checkpoint()
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      for path in paths where Kraken.SceneEdit.isMesh(stage, path)
      {
        // the stack keeps its result over the mesh, so the normals go onto the cage underneath it
        Kraken.Modifiers.clearSession(stage, path)
        Kraken.SceneEdit.shade(stage, path, smooth: smooth, time: time)
        Kraken.Modifiers.sync(stage, path, time)
      }

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }

        self.status = smooth ? "Shade smooth" : "Shade flat"
        self.inspector.reload()
      }
    }
  }
}
