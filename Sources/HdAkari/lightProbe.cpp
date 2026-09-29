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
# include <Hd/sceneDelegate.h>
# include <Gf/vec3i.h>
# include <Tf/token.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/base/gf/vec3i.h>
# include <pxr/base/tf/token.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/lightProbe.h"
#include "HdAkari/scene.h"

#include <algorithm>
#include <string>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

TfToken const &LightProbeToken()
{
  static const TfToken token("akari:lightProbe");
  return token;
}

TfToken const &LightProbeResolutionToken()
{
  static const TfToken token("akari:lightProbeResolution");
  return token;
}

std::string ProbeKind(VtValue const &value)
{
  if (value.IsHolding<TfToken>()) return value.UncheckedGet<TfToken>().GetString();
  if (value.IsHolding<std::string>()) return value.UncheckedGet<std::string>();
  if (value.IsHolding<VtTokenArray>()) {
    VtTokenArray const &tokens = value.UncheckedGet<VtTokenArray>();
    if (!tokens.empty()) return tokens[0].GetString();
  }
  if (value.IsHolding<VtStringArray>()) {
    VtStringArray const &strings = value.UncheckedGet<VtStringArray>();
    if (!strings.empty()) return strings[0];
  }
  return {};
}

bool ProbeResolution(VtValue const &value, GfVec3i &out)
{
  if (value.IsHolding<GfVec3i>()) {
    out = value.UncheckedGet<GfVec3i>();
    return true;
  }
  if (value.IsHolding<VtVec3iArray>()) {
    VtVec3iArray const &values = value.UncheckedGet<VtVec3iArray>();
    if (values.empty()) return false;
    out = values[0];
    return true;
  }
  return false;
}

} // namespace

bool HdAkariSyncLightProbe(HdSceneDelegate *sceneDelegate,
                           SdfPath const &id,
                           HdAkariScene *scene,
                           VtVec3fArray const *points)
{
  const std::string kind = ProbeKind(sceneDelegate->Get(id, LightProbeToken()));
  if (kind != "volume" && kind != "sphere") {
    scene->RemoveProbe(id);
    return false;
  }

  HdAkariLightProbeData data;
  data.id = id;
  data.transform = sceneDelegate->GetTransform(id);
  data.isSphere = kind == "sphere";

  if (points && !points->empty()) {
    GfVec3f lo = (*points)[0], hi = (*points)[0];
    for (GfVec3f const &p : *points) {
      for (int k = 0; k < 3; ++k) {
        lo[k] = std::min(lo[k], p[k]);
        hi[k] = std::max(hi[k], p[k]);
      }
    }
    data.minX = lo[0]; data.minY = lo[1]; data.minZ = lo[2];
    data.maxX = hi[0]; data.maxY = hi[1]; data.maxZ = hi[2];
  } else {
    scene->CopyProbeBounds(id, data);
  }

  GfVec3i resolution(0, 0, 0);
  if (ProbeResolution(sceneDelegate->Get(id, LightProbeResolutionToken()), resolution)) {
    data.resolutionX = std::max(resolution[0], 0);
    data.resolutionY = std::max(resolution[1], 0);
    data.resolutionZ = std::max(resolution[2], 0);
  }

  scene->UpdateProbe(std::move(data));
  scene->RemoveMesh(id);
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
