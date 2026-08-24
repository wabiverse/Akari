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
#ifndef HDAKARI_AKARI_BRIDGE_H
#define HDAKARI_AKARI_BRIDGE_H

/* (todo): move the C++ implementation for these into native Swift. */

#include <stdint.h>

#include <HdAkari/scene.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Packed codes returned by `AKRenderDelegateDefaultAovDescriptor`.
 */
typedef enum AK_AOV_FORMAT
{
  AK_AOV_FORMAT_COLOR = 0,     /* HdFormatFloat16Vec4, clear (0,0,0,1). */
  AK_AOV_FORMAT_DEPTH = 1,     /* HdFormatFloat32, clear 1.0. */
  AK_AOV_FORMAT_ID = 2,        /* HdFormatInt32, clear -1 (primId/instanceId/elementId). */
  AK_AOV_FORMAT_INVALID = -1,  /* Unsupported AOV, the delegate returns an invalid descriptor. */
} AK_AOV_FORMAT;

/**
 * Hands the Swift `Akari.RenderEngine` to the C++ render delegate.
 *
 * @param engine `Unmanaged.passRetained(engine).toOpaque()`. The
 *        bridge holds the raw pointer, the caller keeps the Swift
 *        object alive.
 *
 * @warning Call *before* selecting the Akari renderer, i.e.
 *          before the Hydra engine (and its render delegate)
 *          is constructed.
 */
void AkariHydraSetRenderEngine(void *engine);

/** The retained `Akari.RenderEngine`, or NULL if none was set. */
void *AkariHydraGetRenderEngine(void);

/**
 * Hands the Swift `Akari.RenderDelegate` to the C++ render delegate adapter.
 *
 * @param delegate `Unmanaged.passRetained(delegate).toOpaque()`. The
 *        bridge holds the raw pointer, the caller keeps the Swift
 *        object alive.
 *
 * @warning Call *before* selecting the Akari renderer, i.e.
 *          before the Hydra engine (and its render delegate)
 *          is constructed.
 */
void AkariHydraSetRenderDelegate(void *delegate);

/** The retained Swift `Akari.RenderDelegate`, or NULL if none was set. */
void *AkariHydraGetRenderDelegate(void);

/**
 * Forces HdAkari's renderer plugin to be linked.
 *
 * HdAkari is a static library, without a reference
 * into the plugin's .o the linker drops it, taking
 * its `TF_REGISTRY_FUNCTION` with it, and Akari
 * never registers. Call this before selecting the
 * renderer.
 */
void AkariHdEnsureLinked(void);

/** Number of meshes the delegate has synced (-1 if renderParam is null). */
long AkariSceneMeshCount(void *renderParam);

/** Total triangles across all synced meshes (-1 if renderParam is null). */
long AkariSceneTriangleCount(void *renderParam);

/**
 * Replaces a color AOV render buffer's texture with a wrap of an
 * externally owned native texture, the handoff for LabGL's final
 * color buffer. The buffer takes over Hgi ownership of the wrap
 * (destroying it on realloc / deallocate does not destroy the Metal
 * object, which stays owned by LabGL). The wrap is described from
 * the AOV's own dims/format, so the creator's texture must match
 * the AOV descriptor.
 *
 * @param renderBuffer  `HdAkariRenderBuffer` for the color AOV.
 * @param hgi           `Hgi` (must be the shared `HgiMetal`).
 * @param rawResource   Backend native texture handle from LabGL.
 */
void AkariRenderBufferSetExternalTexture(void *renderBuffer, void *hgi,
                                         uint64_t rawResource);

#ifdef __cplusplus
}
#endif

#endif // HDAKARI_AKARI_BRIDGE_H
