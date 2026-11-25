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
#ifndef HDAKARI_BRIDGE_DELEGATE_CALLS_H
#define HDAKARI_BRIDGE_DELEGATE_CALLS_H

/* the parts of `HdRenderDelegate` implemented in swift */

#ifdef __cplusplus
extern "C" {
#endif

/** called once for each string the swift delegate lists */
typedef void (*AKStringCallback)(const char *value, void *context);

/**
 * the supported hydra prim type tokens, handed out through a callback.
 *
 * @param delegate  the retained `Akari.RenderDelegate` as an opaque pointer.
 * @param cb        called once for each supported token.
 * @param context   passed through to `cb`, the adapter's `TfTokenVector`.
 */
void AKRenderDelegateSupportedRprimTypes(void *delegate, AKStringCallback cb, void *context);
void AKRenderDelegateSupportedSprimTypes(void *delegate, AKStringCallback cb, void *context);
void AKRenderDelegateSupportedBprimTypes(void *delegate, AKStringCallback cb, void *context);

/**
 * the packed aov descriptor for `name` as an `AK_AOV_FORMAT` code. the adapter
 * maps the code back to an `HdAovDescriptor` with its format, multisampling
 * and clear value.
 *
 * @param delegate  the retained `Akari.RenderDelegate` as an opaque pointer.
 * @param name      the aov name, such as color, depth or `primId`.
 */
int32_t AKRenderDelegateDefaultAovDescriptor(void *delegate, const char *name);

/**
 * the factories behind `CreateRprim`, `CreateSprim` and `CreateBprim`. each
 * returns the renderer's class name for a prim type, or null to decline it.
 * the c++ adapter maps each known name onto the hydra subclass it constructs.
 *
 * @param delegate  the retained `Akari.RenderDelegate` as an opaque pointer.
 * @param typeId    the hydra prim type token, such as mesh.
 */
const char *AKRenderDelegateRprimClassName(void *delegate, const char *typeId);
const char *AKRenderDelegateSprimClassName(void *delegate, const char *typeId);
const char *AKRenderDelegateBprimClassName(void *delegate, const char *typeId);

#ifdef __cplusplus
}
#endif

#endif // HDAKARI_BRIDGE_DELEGATE_CALLS_H
