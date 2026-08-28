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
#include <Arch/swiftInterop.h>
#include <Tf/sharedPtrRetainReleaseHelper.h>
#include <Hd/renderDelegate.h>
#include <Hgi/hgiImpl.h>

PXR_NAMESPACE_OPEN_SCOPE

class HdAkariScene;
class HdAkariTextureAtlas;

/// @class HdAkariRenderParam
///
/// Shared, per delegate state handed to render passes and prims.
///
/// The state holds the retained Swift `Akari.RenderEngine`, the
/// Hgi Hydra handed us via drivers, and the scene registry the
/// mesh Rprims publish into.
///
class SWIFT_SHARED_REFERENCE(HdAkariRenderParamRetain, HdAkariRenderParamRelease)
HdAkariRenderParam final : public HdRenderParam
{
public:
  HdAkariRenderParam(void *renderEngine, Hgi *hgi, std::shared_ptr<HdAkariScene> scene,
                     std::shared_ptr<HdAkariTextureAtlas> textureAtlas)
    : _renderEngine(renderEngine),
      _hgi(hgi),
      _scene(scene),
      _textureAtlas(textureAtlas)
  {}

  /// The Swift `Akari.RenderEngine` (an `Unmanaged` opaque pointer).
  void *GetRenderEngine() const { return _renderEngine; }

  /// The delegate's mesh registry (owned by the delegate, not this param).
  HdAkariScene SWIFT_RETURNS_UNRETAINED *GetScene() const { return _scene.get(); }

  /// The delegate's shared roughness/metallic/opacity texture atlas.
  HdAkariTextureAtlas SWIFT_RETURNS_UNRETAINED *GetTextureAtlas() const { return _textureAtlas.get(); }

  /// The Hgi shared with Hydra (same device, so AOV textures are shared).
  Hgi *GetHgi() const
  {
    std::lock_guard<std::mutex> lock(_hgiMutex);
    return _hgi;
  }
  
  void SetHgi(Hgi *hgi)
  {
    std::lock_guard<std::mutex> lock(_hgiMutex);
    _hgi = hgi;
  }

private:
  void *_renderEngine;
  Hgi *_hgi;
  std::shared_ptr<HdAkariScene> _scene;
  std::shared_ptr<HdAkariTextureAtlas> _textureAtlas;

  mutable std::mutex _hgiMutex;
};

PXR_NAMESPACE_CLOSE_SCOPE

inline void HdAkariRenderParamRetain(PXR_INTERNAL_NS::HdAkariRenderParam *param)
{
  PXR_INTERNAL_NS::Tf_SharedPtrRetainReleaseHelper<PXR_INTERNAL_NS::HdAkariRenderParam>::Retain(param);
}

inline void HdAkariRenderParamRelease(PXR_INTERNAL_NS::HdAkariRenderParam *param)
{
  PXR_INTERNAL_NS::Tf_SharedPtrRetainReleaseHelper<PXR_INTERNAL_NS::HdAkariRenderParam>::Release(param);
}

#endif // HDAKARI_RENDER_PARAM_H
