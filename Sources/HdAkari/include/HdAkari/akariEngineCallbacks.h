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

/* Declarations of the Swift exported (@_cdecl) engine entry points. */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Renders one frame with the Swift `Akari.RenderEngine`.
 *
 * @param engine        retained `Akari.RenderEngine` (opaque).
 * @param hgi           `Hgi` shared with Hydra.
 * @param renderParam   `HdAkariRenderParam` (reaches the mesh scene).
 * @param colorBuffer   `HdAkariRenderBuffer` for the color AOV (may be null).
 * @param depthBuffer   `HdAkariRenderBuffer` for the depth AOV (may be null).
 * @param viewMatrix    16 doubles, GfMatrix4d row-major (world->view).
 * @param projMatrix    16 doubles, GfMatrix4d row-major (view->clip).
 * @param width         target width dimension in pixels.
 * @param height        target height dimension in pixels.
 */
void AkariEngineRenderFrame(void *engine, void *hgi, void *renderParam,
                            void *colorBuffer, void *depthBuffer,
                            const double *viewMatrix, const double *projMatrix,
                            int width, int height);

#ifdef __cplusplus
}
#endif

#endif // HDAKARI_ENGINE_CALLBACKS_H
