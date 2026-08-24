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
#include "HdAkari/renderDelegate.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/renderPass.h"
#include "HdAkari/renderBuffer.h"
#include "HdAkari/mesh.h"
#include "HdAkari/sphere.h"
#include "HdAkari/cube.h"
#include "HdAkari/scene.h"
#include "HdAkari/akariBridge.h"
#include "HdAkari/akariBridgeDelegateCalls.h"

#include <Hd/camera.h>
#include <Hd/driver.h>
#include <Hd/instancer.h>
#include <Hd/tokens.h>
#include <Hd/aov.h>
#include <Hgi/tokens.h>
#include <Gf/vec4f.h>
#include <Tf/diagnostic.h>

#include <cstdio>
#include <cstring>
#include <mutex>

PXR_NAMESPACE_OPEN_SCOPE

const TfTokenVector HdAkariRenderDelegate::SUPPORTED_RPRIM_TYPES = {
  HdPrimTypeTokens->mesh,
  HdPrimTypeTokens->sphere,
  HdPrimTypeTokens->cube,
};

const TfTokenVector HdAkariRenderDelegate::SUPPORTED_SPRIM_TYPES = {
  HdPrimTypeTokens->camera,
  HdPrimTypeTokens->material,
};

const TfTokenVector HdAkariRenderDelegate::SUPPORTED_BPRIM_TYPES = {
  HdPrimTypeTokens->renderBuffer,
};

namespace {

/// Collect tokens the Swift delegate query enumerates into `out`.
void FillTokens(TfTokenVector &out, void *delegate,
                void (*enumerate)(void *, AKStringCallback, void *))
{
  out.clear();
  enumerate(delegate, [](const char *value, void *ctx) {
    static_cast<TfTokenVector *>(ctx)->emplace_back(value);
  }, &out);
}

}  // namespace

HdAkariRenderDelegate::HdAkariRenderDelegate()
  : HdRenderDelegate()
{
  _Initialize();
}

HdAkariRenderDelegate::HdAkariRenderDelegate(HdRenderSettingsMap const &settingsMap)
  : HdRenderDelegate(settingsMap)
{
  _Initialize();
}

void
HdAkariRenderDelegate::_Initialize()
{
  // the swift Akari.RenderEngine + Akari.RenderDelegate,
  // handed over before renderer selection.
  _renderEngine = AkariHydraGetRenderEngine();
  _swiftDelegate = AkariHydraGetRenderDelegate();
  _resourceRegistry = std::make_shared<HdResourceRegistry>();
  _scene = std::make_shared<HdAkariScene>();
  _renderParam = std::make_shared<HdAkariRenderParam>(_renderEngine, _hgi, _scene);
  
  // references shared with swift.
  Tf_SharedPtrRetainReleaseHelper<HdAkariScene>::Register(_scene);
  Tf_SharedPtrRetainReleaseHelper<HdAkariRenderParam>::Register(_renderParam);
}

HdAkariRenderDelegate::~HdAkariRenderDelegate()
{
  _resourceRegistry.reset();
  _renderParam.reset(); // references _scene, so tear down before it
  _scene.reset();
}

void
HdAkariRenderDelegate::SetDrivers(HdDriverVector const &drivers)
{
  for (HdDriver *hdDriver : drivers) {
    if (hdDriver->name == HgiTokens->renderDriver &&
        hdDriver->driver.IsHolding<Hgi *>()) {
      _hgi = hdDriver->driver.UncheckedGet<Hgi *>();
      break;
    }
  }
  // rebuild the shared param now that Hgi is known.
  if (_renderParam) {
    _renderParam->SetHgi(_hgi);
  }
}

const TfTokenVector &
HdAkariRenderDelegate::GetSupportedRprimTypes() const
{
  if (_swiftDelegate) {
    FillTokens(_supportedRprimTypes, _swiftDelegate, AKRenderDelegateSupportedRprimTypes);
    return _supportedRprimTypes;
  }
  return SUPPORTED_RPRIM_TYPES;
}

const TfTokenVector &
HdAkariRenderDelegate::GetSupportedSprimTypes() const
{
  if (_swiftDelegate) {
    FillTokens(_supportedSprimTypes, _swiftDelegate, AKRenderDelegateSupportedSprimTypes);
    return _supportedSprimTypes;
  }
  return SUPPORTED_SPRIM_TYPES;
}

const TfTokenVector &
HdAkariRenderDelegate::GetSupportedBprimTypes() const
{
  if (_swiftDelegate) {
    FillTokens(_supportedBprimTypes, _swiftDelegate, AKRenderDelegateSupportedBprimTypes);
    return _supportedBprimTypes;
  }
  return SUPPORTED_BPRIM_TYPES;
}

HdResourceRegistrySharedPtr HdAkariRenderDelegate::GetResourceRegistry() const { return _resourceRegistry; }
HdRenderParam *HdAkariRenderDelegate::GetRenderParam() const { return _renderParam.get(); }

HdRenderPassSharedPtr
HdAkariRenderDelegate::CreateRenderPass(HdRenderIndex *index,
                                        HdRprimCollection const &collection)
{
  return HdRenderPassSharedPtr(new HdAkariRenderPass(index, collection));
}

HdInstancer *
HdAkariRenderDelegate::CreateInstancer(HdSceneDelegate * /*delegate*/,
                                       SdfPath const & /*id*/)
{
  // todo: support instancing.
  return nullptr;
}

void HdAkariRenderDelegate::DestroyInstancer(HdInstancer *instancer) { delete instancer; }

HdRprim *
HdAkariRenderDelegate::CreateRprim(TfToken const &typeId, SdfPath const &rprimId)
{
  const char *className = _swiftDelegate
      ? AKRenderDelegateRprimClassName(_swiftDelegate, typeId.GetText())
      : nullptr;
  
  using RprimFactoryFunc = HdRprim*(*)(const SdfPath&);
  static const std::unordered_map<TfToken, RprimFactoryFunc, TfToken::HashFunctor> factoryMap = {
    { TfToken("mesh"),   [](const SdfPath& id) -> HdRprim* { return new HdAkariMesh(id);   } },
    { TfToken("sphere"), [](const SdfPath& id) -> HdRprim* { return new HdAkariSphere(id); } },
    { TfToken("cube"),   [](const SdfPath& id) -> HdRprim* { return new HdAkariCube(id);   } }
  };
  
  const TfToken lookupToken(className);

  auto it = factoryMap.find(lookupToken);
  if (it != factoryMap.end()) {
    fprintf(stderr, "[akari] CreateRprim %s %s\n", lookupToken.GetText(), rprimId.GetText());
    return it->second(rprimId);
  }

  fprintf(stderr, "[akari] CreateRprim UNSUPPORTED type '%s' (%s)\n",
          typeId.GetText(), rprimId.GetText());

  return nullptr;
}

void HdAkariRenderDelegate::DestroyRprim(HdRprim *rPrim) { delete rPrim; }

HdSprim *
HdAkariRenderDelegate::CreateSprim(TfToken const &typeId, SdfPath const &sprimId)
{
  const char *className = _swiftDelegate
      ? AKRenderDelegateSprimClassName(_swiftDelegate, typeId.GetText())
      : nullptr;

  if (className && strcmp(className, "camera") == 0) {
    return new HdCamera(sprimId);
  }
  // materials are accepted (so binding works) but not yet consumed.
  return nullptr;
}

HdSprim *
HdAkariRenderDelegate::CreateFallbackSprim(TfToken const &typeId)
{
  const char *className = _swiftDelegate
      ? AKRenderDelegateSprimClassName(_swiftDelegate, typeId.GetText())
      : nullptr;

  if (className && strcmp(className, "camera") == 0) {
    return new HdCamera(SdfPath::EmptyPath());
  }
  return nullptr;
}

void HdAkariRenderDelegate::DestroySprim(HdSprim *sPrim) { delete sPrim; }

HdBprim *
HdAkariRenderDelegate::CreateBprim(TfToken const &typeId, SdfPath const &bprimId)
{
  const char *className = _swiftDelegate
      ? AKRenderDelegateBprimClassName(_swiftDelegate, typeId.GetText())
      : nullptr;

  if (className && strcmp(className, "renderBuffer") == 0) {
    return new HdAkariRenderBuffer(bprimId);
  }
  return nullptr;
}

HdBprim *
HdAkariRenderDelegate::CreateFallbackBprim(TfToken const &typeId)
{
  const char *className = _swiftDelegate
      ? AKRenderDelegateBprimClassName(_swiftDelegate, typeId.GetText())
      : nullptr;

  if (className && strcmp(className, "renderBuffer") == 0) {
    return new HdAkariRenderBuffer(SdfPath::EmptyPath());
  }
  return nullptr;
}

void HdAkariRenderDelegate::DestroyBprim(HdBprim *bPrim) { delete bPrim; }

void
HdAkariRenderDelegate::CommitResources(HdChangeTracker * /*tracker*/)
{
  // resource upload is driven by the engine per frame, nothing to flush yet.
}

HdAovDescriptor
HdAkariRenderDelegate::GetDefaultAovDescriptor(TfToken const &name) const
{
  int32_t formatCode = AK_AOV_FORMAT_INVALID;
  if (_swiftDelegate) {
    formatCode = AKRenderDelegateDefaultAovDescriptor(_swiftDelegate, name.GetText());
  }

  switch (formatCode) {
    case AK_AOV_FORMAT_COLOR:
      return HdAovDescriptor(HdFormatFloat16Vec4, /*multiSampled*/ false,
                             VtValue(GfVec4f(0.0f, 0.0f, 0.0f, 1.0f)));
    case AK_AOV_FORMAT_DEPTH:
      return HdAovDescriptor(HdFormatFloat32, false, VtValue(1.0f));
    case AK_AOV_FORMAT_ID:
      return HdAovDescriptor(HdFormatInt32, false, VtValue(-1));
    default:
      return HdAovDescriptor();
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
