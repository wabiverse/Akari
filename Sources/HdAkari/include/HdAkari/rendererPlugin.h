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
#ifndef HDAKARI_RENDERER_PLUGIN_H
#define HDAKARI_RENDERER_PLUGIN_H

#include <pxr/pxrns.h>
#include <Hd/rendererPlugin.h>
#include "HdAkari/api.h"

PXR_NAMESPACE_OPEN_SCOPE

/// @class HdAkariRendererPlugin
///
/// The Hydra entry point that makes "Akari" a selectable Hydra renderer.
///
/// Registered via plugInfo.json, Hydra instantiates it to construct the
/// `HdAkariRenderDelegate`.
///
class HdAkariRendererPlugin final : public HdRendererPlugin
{
public:
  HdAkariRendererPlugin() = default;
  ~HdAkariRendererPlugin() override = default;

  HdAkariRendererPlugin(const HdAkariRendererPlugin &) = delete;
  HdAkariRendererPlugin &operator=(const HdAkariRendererPlugin &) = delete;

  HDAKARI_API
  HdRenderDelegate *CreateRenderDelegate() override;

  HDAKARI_API
  HdRenderDelegate *CreateRenderDelegate(HdRenderSettingsMap const &settingsMap) override;

  HDAKARI_API
  void DeleteRenderDelegate(HdRenderDelegate *renderDelegate) override;

  HDAKARI_API
  bool IsSupported(const HdRendererCreateArgsSchema &rendererCreateArgs,
                   std::string *reasonWhyNot = nullptr) const override;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_RENDERER_PLUGIN_H
