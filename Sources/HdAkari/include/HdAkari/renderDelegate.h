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
#ifndef HDAKARI_RENDER_DELEGATE_H
#define HDAKARI_RENDER_DELEGATE_H

#include <pxr/pxrns.h>
#include <Hd/renderDelegate.h>
#include <Hd/resourceRegistry.h>
#include <Hgi/hgiImpl.h>

#include "HdAkari/api.h"

#include <memory>
#include <mutex>

PXR_NAMESPACE_OPEN_SCOPE

class HdAkariRenderParam;
class HdAkariScene;

/// @class HdAkariRenderDelegate
///
/// The Hydra render delegate for Akari.
///
/// A thin adapter: every virtual it overrides forwards to the Swift
/// `Akari.RenderDelegate` registered through `AkariHydraSetRenderDelegate`.
///
/// The delegate logic (supported prim types, default AOVs, prim factory
/// decisions) live in Swift (AkariRenderDelegate.swift). This class keeps
/// only the per renderer state Hydra hands it (Hgi, resource registry, the
/// scene/render param) and the C++ glue the prim shells still need.
///
class HdAkariRenderDelegate final : public HdRenderDelegate
{
public:
  HDAKARI_API HdAkariRenderDelegate();
  HDAKARI_API explicit HdAkariRenderDelegate(HdRenderSettingsMap const &settingsMap);
  HDAKARI_API ~HdAkariRenderDelegate() override;

  HdAkariRenderDelegate(const HdAkariRenderDelegate &) = delete;
  HdAkariRenderDelegate &operator=(const HdAkariRenderDelegate &) = delete;

  /// Hydra hands us the graphics interface via drivers.
  HDAKARI_API void SetDrivers(HdDriverVector const &drivers) override;

  /// Supported prim types.
  HDAKARI_API const TfTokenVector &GetSupportedRprimTypes() const override;
  HDAKARI_API const TfTokenVector &GetSupportedSprimTypes() const override;
  HDAKARI_API const TfTokenVector &GetSupportedBprimTypes() const override;

  HDAKARI_API HdResourceRegistrySharedPtr GetResourceRegistry() const override;
  HDAKARI_API HdRenderParam *GetRenderParam() const override;

  /// Render pass.
  HDAKARI_API HdRenderPassSharedPtr CreateRenderPass(HdRenderIndex *index,
                                                     HdRprimCollection const &collection) override;

  /// Prim factories.
  HDAKARI_API HdInstancer *CreateInstancer(HdSceneDelegate *delegate, SdfPath const &id) override;
  HDAKARI_API void DestroyInstancer(HdInstancer *instancer) override;

  HDAKARI_API HdRprim *CreateRprim(TfToken const &typeId, SdfPath const &rprimId) override;
  HDAKARI_API void DestroyRprim(HdRprim *rPrim) override;

  HDAKARI_API HdSprim *CreateSprim(TfToken const &typeId, SdfPath const &sprimId) override;
  HDAKARI_API HdSprim *CreateFallbackSprim(TfToken const &typeId) override;
  HDAKARI_API void DestroySprim(HdSprim *sPrim) override;

  HDAKARI_API HdBprim *CreateBprim(TfToken const &typeId, SdfPath const &bprimId) override;
  HDAKARI_API HdBprim *CreateFallbackBprim(TfToken const &typeId) override;
  HDAKARI_API void DestroyBprim(HdBprim *bPrim) override;

  HDAKARI_API void CommitResources(HdChangeTracker *tracker) override;

  HDAKARI_API HdAovDescriptor GetDefaultAovDescriptor(TfToken const &name) const override;

private:
  void _Initialize();

  Hgi *_hgi = nullptr;                       // shared with Hydra, not owned
  void *_renderEngine = nullptr;             // retained Swift Akari.RenderEngine
  void *_swiftDelegate = nullptr;            // retained Swift Akari.RenderDelegate
  
  // ---- shared with swift. ----
  std::shared_ptr<HdAkariScene> _scene;      // mesh registry the Rprims fill
  std::shared_ptr<HdAkariRenderParam> _renderParam;
  // ----------------------------

  HdResourceRegistrySharedPtr _resourceRegistry;

  /// Cached vectors of supported prim types,
  /// filled from the Swift delegate on first
  /// use (the static constants below are the
  /// fallback when no Swift delegate is set).
  mutable TfTokenVector _supportedRprimTypes;
  mutable TfTokenVector _supportedSprimTypes;
  mutable TfTokenVector _supportedBprimTypes;

  static const TfTokenVector SUPPORTED_RPRIM_TYPES;
  static const TfTokenVector SUPPORTED_SPRIM_TYPES;
  static const TfTokenVector SUPPORTED_BPRIM_TYPES;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_RENDER_DELEGATE_H
