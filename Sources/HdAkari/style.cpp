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

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Tf/staticTokens.h>
# include <Hd/sceneDelegate.h>
# include <Gf/vec3d.h>
# include <Gf/vec3f.h>
# include <Gf/vec4d.h>
# include <Gf/vec4f.h>
# include <Tf/token.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/base/gf/vec3d.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/gf/vec4d.h>
# include <pxr/base/gf/vec4f.h>
# include <pxr/base/tf/token.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/style.h"
#include "HdAkari/scene.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  ((assemble, "akari:assemble"))
  ((assembleCenter, "akari:assembleCenter"))
  ((assembleSize, "akari:assembleSize"))
  ((color, "akari:color"))
  ((shadingModel, "akari:shadingModel"))
  ((shadingModelFront, "akari:shadingModelFront"))
  ((shadingModelFrontBand, "akari:shadingModelFrontBand"))
  ((shadingModelFrontColor, "akari:shadingModelFrontColor"))
  ((shadingModelFrontGlow, "akari:shadingModelFrontGlow"))
  ((unlit, "akari:unlit"))
  ((wireColor, "akari:wireColor"))
  ((wireGlow, "akari:wireGlow"))
  ((wireSpacing, "akari:wireSpacing"))
);

namespace {

template <typename T>
bool First(VtValue const &value, T &out)
{
  if (value.IsHolding<T>()) { out = value.UncheckedGet<T>(); return true; }
  if (value.IsHolding<VtArray<T>>()) {
    VtArray<T> const &values = value.UncheckedGet<VtArray<T>>();
    if (values.empty()) return false;
    out = values[0];
    return true;
  }

  return false;
}

bool ReadFloat(VtValue const &value, float &out)
{
  double d = 0.0;
  int i = 0;
  bool b = false;
  if (First(value, out)) return true;
  if (First(value, d)) { out = float(d); return true; }
  if (First(value, i)) { out = float(i); return true; }
  if (First(value, b)) { out = b ? 1.0f : 0.0f; return true; }
  return false;
}

bool ReadVec3(VtValue const &value, float &x, float &y, float &z)
{
  GfVec3f f;
  GfVec3d d;
  if (First(value, f)) { x = f[0]; y = f[1]; z = f[2]; return true; }
  if (First(value, d)) { x = float(d[0]); y = float(d[1]); z = float(d[2]); return true; }
  return false;
}

bool ReadVec4(VtValue const &value, float &x, float &y, float &z, float &w)
{
  GfVec4f f;
  GfVec4d d;
  if (First(value, f)) { x = f[0]; y = f[1]; z = f[2]; w = f[3]; return true; }
  if (First(value, d)) { x = float(d[0]); y = float(d[1]); z = float(d[2]); w = float(d[3]); return true; }
  return false;
}

} // namespace

void HdAkariSyncStyle(HdSceneDelegate *sceneDelegate, SdfPath const &id, int32_t primId, HdAkariScene *scene)
{
  auto get = [&](TfToken const &name) { return sceneDelegate->Get(id, name); };
  HdAkariStyleData data;
  data.primId = primId;
  bool styled = false;
  styled |= ReadFloat(get(_tokens->shadingModel), data.shadingModel);
  styled |= ReadFloat(get(_tokens->color), data.color);
  styled |= ReadFloat(get(_tokens->unlit), data.unlit);
  styled |= ReadFloat(get(_tokens->assemble), data.assemble);
  styled |= ReadVec4(get(_tokens->shadingModelFront), data.frontX, data.frontY, data.frontZ, data.frontRadius);
  if (!styled) {
    scene->RemoveStyle(primId);
    return;
  }

  ReadFloat(get(_tokens->shadingModelFrontBand), data.frontBand);
  ReadVec3(get(_tokens->shadingModelFrontColor), data.frontGlowR, data.frontGlowG, data.frontGlowB);
  ReadFloat(get(_tokens->shadingModelFrontGlow), data.frontGlow);
  ReadVec3(get(_tokens->wireColor), data.wireR, data.wireG, data.wireB);
  ReadFloat(get(_tokens->wireGlow), data.wireGlow);
  ReadFloat(get(_tokens->wireSpacing), data.wireSpacing);
  data.hasCenter = ReadVec3(get(_tokens->assembleCenter), data.centerX, data.centerY, data.centerZ);
  ReadFloat(get(_tokens->assembleSize), data.size);
  scene->UpdateStyle(data);
}

PXR_NAMESPACE_CLOSE_SCOPE
