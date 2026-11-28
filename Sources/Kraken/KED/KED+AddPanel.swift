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

import SwiftCrossUI

extension Kraken
{
  /// the touch layout's add panel, primitives in a menu and the asset libraries as tiles a tap adds or views
  @MainActor
  struct AddPanel: View
  {
    enum Shelf: String, CustomStringConvertible
    {
      case objects = "Objects"
      case materials = "Materials"

      var description: String
      {
        rawValue
      }
    }

    @State private var layout: Layout
    @State private var viewer: AssetViewer
    @State private var shelf = Shelf.objects

    init(layout: Layout)
    {
      _layout = State(wrappedValue: layout)
      _viewer = State(wrappedValue: layout.viewer)
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        if layout.viewsAssets
        {
          StudioStrip(viewer: viewer)
            .padding(.bottom, 8)
        }
        else
        {
          HStack(spacing: 8)
          {
            Segmented(options: [Shelf.objects, .materials], selection: Binding(get: { shelf }, set: { shelf = $0 ?? .objects }))
            Spacer()
            MenuButton(symbol: "cube", title: "Primitives", size: 34)
            {
              layout.viewport?.entries(.add).filter { !$0.isHeader } ?? []
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
        }

        // viewing is for artifacts, so the materials shelf only shows while adding
        if layout.viewsAssets || shelf == .objects
        {
          AssetBrowser(layout: layout, shelf: AssetShelf.objects, compact: true)
        }
        else
        {
          AssetBrowser(layout: layout, shelf: AssetShelf.materials, compact: true)
        }
      }
    }
  }
}
