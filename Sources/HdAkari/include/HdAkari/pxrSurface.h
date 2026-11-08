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

#ifndef HDAKARI_PXR_SURFACE_H
#define HDAKARI_PXR_SURFACE_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Gf/vec3f.h>
# include <Tf/token.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/tf/token.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/api.h"

PXR_NAMESPACE_OPEN_SCOPE

/// The PxrSurface inputs that shape its look, at RenderMan's defaults.
struct HdAkariPxrSurface
{
  float diffuseGain = 1.0f;
  GfVec3f diffuseColor = GfVec3f(0.18f);
  GfVec3f irradianceTint = GfVec3f(1.0f);

  int specularFresnelMode = 0;
  GfVec3f specularFaceColor = GfVec3f(0.0f);
  GfVec3f specularEdgeColor = GfVec3f(0.0f);
  GfVec3f specularIor = GfVec3f(1.5f);
  GfVec3f specularExtinctionCoeff = GfVec3f(0.0f);
  float specularRoughness = 0.2f;

  int roughSpecularFresnelMode = 0;
  GfVec3f roughSpecularFaceColor = GfVec3f(0.0f);
  GfVec3f roughSpecularEdgeColor = GfVec3f(0.0f);
  GfVec3f roughSpecularIor = GfVec3f(1.5f);
  GfVec3f roughSpecularExtinctionCoeff = GfVec3f(0.0f);
  float roughSpecularRoughness = 0.6f;

  int clearcoatFresnelMode = 0;
  GfVec3f clearcoatFaceColor = GfVec3f(0.0f);
  GfVec3f clearcoatEdgeColor = GfVec3f(0.0f);
  GfVec3f clearcoatIor = GfVec3f(1.5f);
  GfVec3f clearcoatExtinctionCoeff = GfVec3f(0.0f);
  float clearcoatThickness = 0.0f;
  GfVec3f clearcoatAbsorptionTint = GfVec3f(0.0f);
  float clearcoatRoughness = 0.0f;

  float iridescenceFaceGain = 0.0f;
  GfVec3f iridescencePrimaryColor = GfVec3f(1.0f, 0.0f, 0.0f);
  GfVec3f iridescenceSecondaryColor = GfVec3f(0.0f, 0.0f, 1.0f);

  float fuzzGain = 0.0f;
  GfVec3f fuzzColor = GfVec3f(1.0f);

  float subsurfaceGain = 0.0f;
  GfVec3f subsurfaceColor = GfVec3f(0.830f, 0.791f, 0.753f);
  float singlescatterGain = 0.0f;
  GfVec3f singlescatterColor = GfVec3f(0.830f, 0.791f, 0.753f);

  float refractionGain = 0.0f;
  float reflectionGain = 0.0f;
  GfVec3f refractionColor = GfVec3f(1.0f);
  float glassRoughness = 0.1f;
  float glassIor = 1.5f;

  float glowGain = 0.0f;
  GfVec3f glowColor = GfVec3f(1.0f);
  float presence = 1.0f;
};

/// A PxrSurface's look in Akari's metallic roughness model.
struct HdAkariSurfaceLook
{
  GfVec3f color = GfVec3f(0.18f);
  float metallic = 0.0f;
  float roughness = 0.2f;
  float opacity = 1.0f;
  GfVec3f emissive = GfVec3f(0.0f);
};

/// Sets the input named `name` from `value`, false when it isn't one that shapes the look.
HDAKARI_API bool HdAkariSetPxrSurfaceInput(HdAkariPxrSurface &surface, TfToken const &name, VtValue const &value);

/// Layers the coat, specular, glass, fuzz, subsurface and diffuse lobes down onto one base color,
/// metallic and roughness, with glass seen through Akari's transparency.
HDAKARI_API HdAkariSurfaceLook HdAkariApproximatePxrSurface(HdAkariPxrSurface const &surface);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_PXR_SURFACE_H
