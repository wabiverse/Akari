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
#ifndef HDAKARI_RENDER_PARAM_H
#define HDAKARI_RENDER_PARAM_H

#include <pxr/pxrns.h>
#include <Hd/renderDelegate.h>
#include <Hgi/hgiImpl.h>

PXR_NAMESPACE_OPEN_SCOPE

class HdAkariScene;

/// @class HdAkariRenderParam
///
/// Shared, per delegate state handed to render passes and prims.
///
/// The state holds the retained Swift `Akari.RenderEngine`, the
/// Hgi Hydra handed us via drivers, and the scene registry the
/// mesh Rprims publish into.
///
class HdAkariRenderParam final : public HdRenderParam
{
public:
  HdAkariRenderParam(void *renderEngine, Hgi *hgi, HdAkariScene *scene)
    : _renderEngine(renderEngine),
      _hgi(hgi),
      _scene(scene)
  {}

  /// The Swift `Akari.RenderEngine` (an `Unmanaged` opaque pointer).
  void *GetRenderEngine() const { return _renderEngine; }

  /// The Hgi shared with Hydra (same device, so AOV textures are shared).
  Hgi *GetHgi() const { return _hgi; }

  /// The delegate's mesh registry (owned by the delegate, not this param).
  HdAkariScene *GetScene() const { return _scene; }

private:
  void *_renderEngine;
  Hgi *_hgi;
  HdAkariScene *_scene;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_RENDER_PARAM_H
