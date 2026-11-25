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
#ifndef HDAKARI_RENDER_BUFFER_BRIDGE_H
#define HDAKARI_RENDER_BUFFER_BRIDGE_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <HgiMetal/hgi.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hgiMetal/hgi.h>
#endif

#include "HdAkari/renderBuffer.h"

#include <cstdint>

PXR_NAMESPACE_OPEN_SCOPE

/**
 * replaces a color aov render buffer's texture with a wrap of an externally
 * owned native texture, which is how labgl hands over its final color buffer.
 * the buffer takes over hgi ownership of the wrap, and destroying it on a
 * reallocation does not destroy the metal object, which labgl still owns.
 * the wrap is described from the aov's own size and format, so the creator's
 * texture must match the aov descriptor.
 *
 * @param renderBuffer  the `HdAkariRenderBuffer` for the color aov.
 * @param hgi           the `HgiMetal` shared with hydra.
 * @param rawResource   the native texture handle from labgl.
 */
void AkariRenderBufferSetExternalTexture(HdAkariRenderBuffer *renderBuffer,
                                         HgiMetal *hgi,
                                         uint64_t rawResource);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_RENDER_BUFFER_BRIDGE_H
