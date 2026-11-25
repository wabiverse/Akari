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

/* todo move the c++ implementation of these into swift */

#include <stdint.h>

#include <HdAkari/scene.h>

#ifdef __cplusplus
extern "C" {
#endif

/** packed codes returned by `AKRenderDelegateDefaultAovDescriptor` */
typedef enum AK_AOV_FORMAT
{
  AK_AOV_FORMAT_COLOR = 0,     /* `HdFormatFloat16Vec4` cleared to opaque black */
  AK_AOV_FORMAT_DEPTH = 1,     /* `HdFormatFloat32` cleared to 1 */
  AK_AOV_FORMAT_ID = 2,        /* `HdFormatInt32` cleared to -1, for prim, instance and element ids */
  AK_AOV_FORMAT_INVALID = -1,  /* an unsupported aov, the delegate returns an invalid descriptor */
} AK_AOV_FORMAT;

/**
 * hands the swift `Akari.RenderEngine` to the c++ render delegate.
 *
 * @param engine `Unmanaged.passRetained(engine).toOpaque()`, the bridge
 *        holds the raw pointer and the caller keeps the swift object alive.
 *
 * @warning call this before selecting the akari renderer, so before the
 *          hydra engine and its render delegate are constructed.
 */
void AkariHydraSetRenderEngine(void *engine);

/** the retained `Akari.RenderEngine`, or null if none was set */
void *AkariHydraGetRenderEngine(void);

/**
 * hands the swift `Akari.RenderDelegate` to the c++ render delegate adapter.
 *
 * @param delegate `Unmanaged.passRetained(delegate).toOpaque()`, the bridge
 *        holds the raw pointer and the caller keeps the swift object alive.
 *
 * @warning call this before selecting the akari renderer, so before the
 *          hydra engine and its render delegate are constructed.
 */
void AkariHydraSetRenderDelegate(void *delegate);

/** the retained swift `Akari.RenderDelegate`, or null if none was set */
void *AkariHydraGetRenderDelegate(void);

/**
 * forces the hdakari renderer plugin to be linked.
 *
 * hdakari is a static library, so without a reference into the plugin's
 * object file the linker drops it along with its `TF_REGISTRY_FUNCTION`
 * and akari never registers. call this before selecting the renderer.
 */
void AkariHdEnsureLinked(void);

/** how many meshes the delegate has synced, -1 when `renderParam` is null */
long AkariSceneMeshCount(void *renderParam);

/** the triangles across every synced mesh, -1 when `renderParam` is null */
long AkariSceneTriangleCount(void *renderParam);

#ifdef __cplusplus
}
#endif

#endif // HDAKARI_AKARI_BRIDGE_H
