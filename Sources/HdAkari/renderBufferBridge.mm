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
#include "HdAkari/akariBridge.h"
#include "HdAkari/renderBuffer.h"

#include <Hgi/texture.h>
#include <HgiMetal/hgi.h>
#include <HgiMetal/texture.h>

#include <cstdint>

PXR_NAMESPACE_OPEN_SCOPE

extern "C" void
AkariRenderBufferSetExternalTexture(void *renderBuffer, void *hgiPtr,
                                    uint64_t rawResource)
{
  auto *rb = static_cast<HdAkariRenderBuffer *>(renderBuffer);
  auto *hgiMetal = static_cast<HgiMetal *>(hgiPtr);
  if (!rb || !hgiMetal || rawResource == 0) {
    return;
  }

  // the wrap is described from the AOV's own dims/format, so the creator's
  // texture must match the AOV descriptor (Float16Vec4 color, Float32 depth).
  HgiTextureDesc desc;
  desc.debugName = "HdAkari AOV (external)";
  desc.dimensions = GfVec3i((int)rb->GetWidth(), (int)rb->GetHeight(), 1);
  desc.format = HdAkariRenderBuffer::ToHgiFormat(rb->GetFormat());
  desc.layerCount = 1;
  desc.mipLevels = 1;
  desc.sampleCount = HgiSampleCount1;
  const bool isDepth = (rb->GetFormat() == HdFormatFloat32);
  desc.usage = (isDepth ? HgiTextureUsageBitsDepthTarget
                        : HgiTextureUsageBitsColorTarget) | HgiTextureUsageBitsShaderRead;
  
  rb->SetWrappedTexture(hgiMetal->CreateExternalTexture(desc, rawResource));
}

PXR_NAMESPACE_CLOSE_SCOPE
