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
#include "HdAkari/renderPass.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/renderBuffer.h"
#include "HdAkari/akariEngineCallbacks.h"

#include <Hd/renderPassState.h>
#include <Hd/renderIndex.h>
#include <Hd/renderDelegate.h>
#include <Hd/aov.h>
#include <Hd/tokens.h>
#include <Gf/matrix4d.h>

PXR_NAMESPACE_OPEN_SCOPE

HdAkariRenderPass::HdAkariRenderPass(HdRenderIndex *index,
                                    HdRprimCollection const &collection)
  : HdRenderPass(index, collection)
{}

HdAkariRenderPass::~HdAkariRenderPass() = default;

void
HdAkariRenderPass::_Execute(HdRenderPassStateSharedPtr const &renderPassState,
                            TfTokenVector const & /*renderTags*/)
{
  auto *param = static_cast<HdAkariRenderParam *>(
      GetRenderIndex()->GetRenderDelegate()->GetRenderParam());
  if (!param || !param->GetRenderEngine()) {
    return;
  }

  const GfMatrix4d view = renderPassState->GetWorldToViewMatrix();
  const GfMatrix4d proj = renderPassState->GetProjectionMatrix();

  // resolve the color + depth AOV render buffers.
  void *colorBuffer = nullptr;
  void *depthBuffer = nullptr;
  int width = 0;
  int height = 0;
  for (const HdRenderPassAovBinding &aov : renderPassState->GetAovBindings()) {
    auto *rb = dynamic_cast<HdAkariRenderBuffer *>(aov.renderBuffer);
    if (!rb) {
      continue;
    }
    if (aov.aovName == HdAovTokens->color) {
      colorBuffer = rb;
      width = static_cast<int>(rb->GetWidth());
      height = static_cast<int>(rb->GetHeight());
    } else if (aov.aovName == HdAovTokens->depth) {
      depthBuffer = rb;
    }
  }

  AkariEngineRenderFrame(param->GetRenderEngine(), param->GetHgi(), param,
                         colorBuffer, depthBuffer,
                         view.GetArray(), proj.GetArray(), width, height);
}

PXR_NAMESPACE_CLOSE_SCOPE
