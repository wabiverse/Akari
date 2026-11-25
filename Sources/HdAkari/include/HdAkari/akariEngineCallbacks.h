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
#ifndef HDAKARI_ENGINE_CALLBACKS_H
#define HDAKARI_ENGINE_CALLBACKS_H

/* the engine entry points swift exports with `@_cdecl` */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * renders one frame with the swift `Akari.RenderEngine`.
 *
 * @param engine           the retained `Akari.RenderEngine` as an opaque pointer.
 * @param hgi              the `Hgi` shared with hydra.
 * @param renderParam      the `HdAkariRenderParam`, which reaches the mesh scene.
 * @param colorBuffer      the `HdAkariRenderBuffer` for the color aov, may be null.
 * @param depthBuffer      the `HdAkariRenderBuffer` for the depth aov, may be null.
 * @param primIdBuffer     the `HdAkariRenderBuffer` for the prim id aov, may be null.
 * @param instanceIdBuffer the `HdAkariRenderBuffer` for the instance id aov, may be null.
 * @param viewMatrix       16 doubles, a row major `GfMatrix4d` from world to view.
 * @param projMatrix       16 doubles, a row major `GfMatrix4d` from view to clip.
 * @param width            the target width in pixels.
 * @param height           the target height in pixels.
 */
void AkariEngineRenderFrame(void *engine, void *hgi, void *renderParam,
                            void *colorBuffer, void *depthBuffer,
                            void *primIdBuffer, void *instanceIdBuffer,
                            const double *viewMatrix, const double *projMatrix,
                            int width, int height);

#ifdef __cplusplus
}
#endif

#endif // HDAKARI_ENGINE_CALLBACKS_H
