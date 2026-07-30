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
#include "HdAkari/rendererPlugin.h"
#include "HdAkari/renderDelegate.h"
#include "HdAkari/akariBridge.h"

#include <Hd/rendererPluginRegistry.h>
#include <Tf/registryManager.h>
#include <Tf/type.h>

PXR_NAMESPACE_OPEN_SCOPE

// register Akari with Hydra's plugin registry.
TF_REGISTRY_FUNCTION(TfType)
{
  HdRendererPluginRegistry::Define<HdAkariRendererPlugin>();
}

PXR_NAMESPACE_CLOSE_SCOPE

/// Statically linking HdAkari means nothing references this
/// translation unit, so the linker would drop it, and with it
/// the TF_REGISTRY_FUNCTION above, leaving Akari undiscoverable,
/// calling this from Swift forces the whole .o to be linked in.
extern "C" void AkariHdEnsureLinked(void) {}

PXR_NAMESPACE_OPEN_SCOPE

HdRenderDelegate *
HdAkariRendererPlugin::CreateRenderDelegate()
{
  return new HdAkariRenderDelegate();
}

HdRenderDelegate *
HdAkariRendererPlugin::CreateRenderDelegate(
    HdRenderSettingsMap const &settingsMap)
{
  return new HdAkariRenderDelegate(settingsMap);
}

void
HdAkariRendererPlugin::DeleteRenderDelegate(HdRenderDelegate *renderDelegate)
{
  delete renderDelegate;
}

bool
HdAkariRendererPlugin::IsSupported(
    const HdRendererCreateArgsSchema & /*rendererCreateArgs*/,
    std::string * /*reasonWhyNot*/) const
{
  // akari is available wherever Hydra runs.
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
