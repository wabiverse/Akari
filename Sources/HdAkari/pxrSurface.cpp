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
# include <Gf/vec3d.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
# include <pxr/base/gf/vec3d.h>
#endif

#include "HdAkari/pxrSurface.h"

#include <algorithm>
#include <cmath>

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  (clearcoatAbsorptionTint)
  (clearcoatEdgeColor)
  (clearcoatExtinctionCoeff)
  (clearcoatFaceColor)
  (clearcoatFresnelMode)
  (clearcoatIor)
  (clearcoatRoughness)
  (clearcoatThickness)
  (diffuseColor)
  (diffuseGain)
  (fuzzColor)
  (fuzzGain)
  (glassIor)
  (glassRoughness)
  (glowColor)
  (glowGain)
  (iridescenceFaceGain)
  (iridescencePrimaryColor)
  (iridescenceSecondaryColor)
  (irradianceTint)
  (presence)
  (reflectionGain)
  (refractionColor)
  (refractionGain)
  (roughSpecularEdgeColor)
  (roughSpecularExtinctionCoeff)
  (roughSpecularFaceColor)
  (roughSpecularFresnelMode)
  (roughSpecularIor)
  (roughSpecularRoughness)
  (singlescatterColor)
  (singlescatterGain)
  (specularEdgeColor)
  (specularExtinctionCoeff)
  (specularFaceColor)
  (specularFresnelMode)
  (specularIor)
  (specularRoughness)
  (subsurfaceColor)
  (subsurfaceGain)
);

namespace {

using Surface = HdAkariPxrSurface;

struct FloatInput { TfToken name; float Surface::*member; };
struct ColorInput { TfToken name; GfVec3f Surface::*member; };
struct ModeInput { TfToken name; int Surface::*member; };

bool Scalar(VtValue const &value, double &out)
{
  if (value.IsHolding<float>()) out = value.UncheckedGet<float>();
  else if (value.IsHolding<double>()) out = value.UncheckedGet<double>();
  else if (value.IsHolding<int>()) out = value.UncheckedGet<int>();
  else return false;
  return true;
}

GfVec3f Mul(GfVec3f const &a, GfVec3f const &b) { return GfVec3f(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }
GfVec3f Mix(GfVec3f const &a, GfVec3f const &b, float t) { return a + (b - a) * t; }
float Saturate(float x) { return std::clamp(x, 0.0f, 1.0f); }
float MaxOf(GfVec3f const &c) { return std::max({c[0], c[1], c[2]}); }
GfVec3f Saturate(GfVec3f const &c) { return GfVec3f(Saturate(c[0]), Saturate(c[1]), Saturate(c[2])); }

float Brightness(GfVec3f const &c)
{
  return std::sqrt(0.299f * c[0] * c[0] + 0.587f * c[1] * c[1] + 0.114f * c[2] * c[2]);
}

float Reflectance(float n, float k)
{
  return ((n - 1.0f) * (n - 1.0f) + k * k) / ((n + 1.0f) * (n + 1.0f) + k * k);
}

/// A specular lobe's color facing the eye, physical mode tinting its conductor fresnel by the edge color.
GfVec3f FaceReflectance(int mode, GfVec3f const &face, GfVec3f const &edge, GfVec3f const &ior, GfVec3f const &k)
{
  if (mode == 0) return Saturate(face);
  return Saturate(Mul(GfVec3f(Reflectance(ior[0], k[0]), Reflectance(ior[1], k[1]), Reflectance(ior[2], k[2])), edge));
}

/// The metallic whose base color reflects `specular` facing and scatters `diffuse`, Khronos' specular glossiness conversion.
float SolveMetallic(float diffuse, float specular, float oneMinusSpecular)
{
  constexpr float dielectric = 0.04f;
  if (specular < dielectric) return 0.0f;
  const float b = diffuse * oneMinusSpecular / (1.0f - dielectric) + specular - 2.0f * dielectric;
  const float c = dielectric - specular;
  return Saturate((-b + std::sqrt(std::max(b * b - 4.0f * dielectric * c, 0.0f))) / (2.0f * dielectric));
}

}  // namespace

bool HdAkariSetPxrSurfaceInput(HdAkariPxrSurface &surface, TfToken const &name, VtValue const &value)
{
  static FloatInput const kFloats[] = {
    {_tokens->diffuseGain, &Surface::diffuseGain},
    {_tokens->specularRoughness, &Surface::specularRoughness},
    {_tokens->roughSpecularRoughness, &Surface::roughSpecularRoughness},
    {_tokens->clearcoatThickness, &Surface::clearcoatThickness},
    {_tokens->clearcoatRoughness, &Surface::clearcoatRoughness},
    {_tokens->iridescenceFaceGain, &Surface::iridescenceFaceGain},
    {_tokens->fuzzGain, &Surface::fuzzGain},
    {_tokens->subsurfaceGain, &Surface::subsurfaceGain},
    {_tokens->singlescatterGain, &Surface::singlescatterGain},
    {_tokens->refractionGain, &Surface::refractionGain},
    {_tokens->reflectionGain, &Surface::reflectionGain},
    {_tokens->glassRoughness, &Surface::glassRoughness},
    {_tokens->glassIor, &Surface::glassIor},
    {_tokens->glowGain, &Surface::glowGain},
    {_tokens->presence, &Surface::presence},
  };

  static ColorInput const kColors[] = {
    {_tokens->diffuseColor, &Surface::diffuseColor},
    {_tokens->irradianceTint, &Surface::irradianceTint},
    {_tokens->specularFaceColor, &Surface::specularFaceColor},
    {_tokens->specularEdgeColor, &Surface::specularEdgeColor},
    {_tokens->specularIor, &Surface::specularIor},
    {_tokens->specularExtinctionCoeff, &Surface::specularExtinctionCoeff},
    {_tokens->roughSpecularFaceColor, &Surface::roughSpecularFaceColor},
    {_tokens->roughSpecularEdgeColor, &Surface::roughSpecularEdgeColor},
    {_tokens->roughSpecularIor, &Surface::roughSpecularIor},
    {_tokens->roughSpecularExtinctionCoeff, &Surface::roughSpecularExtinctionCoeff},
    {_tokens->clearcoatFaceColor, &Surface::clearcoatFaceColor},
    {_tokens->clearcoatEdgeColor, &Surface::clearcoatEdgeColor},
    {_tokens->clearcoatIor, &Surface::clearcoatIor},
    {_tokens->clearcoatExtinctionCoeff, &Surface::clearcoatExtinctionCoeff},
    {_tokens->clearcoatAbsorptionTint, &Surface::clearcoatAbsorptionTint},
    {_tokens->iridescencePrimaryColor, &Surface::iridescencePrimaryColor},
    {_tokens->iridescenceSecondaryColor, &Surface::iridescenceSecondaryColor},
    {_tokens->fuzzColor, &Surface::fuzzColor},
    {_tokens->subsurfaceColor, &Surface::subsurfaceColor},
    {_tokens->singlescatterColor, &Surface::singlescatterColor},
    {_tokens->refractionColor, &Surface::refractionColor},
    {_tokens->glowColor, &Surface::glowColor},
  };

  static ModeInput const kModes[] = {
    {_tokens->specularFresnelMode, &Surface::specularFresnelMode},
    {_tokens->roughSpecularFresnelMode, &Surface::roughSpecularFresnelMode},
    {_tokens->clearcoatFresnelMode, &Surface::clearcoatFresnelMode},
  };

  double x = 0.0;
  for (FloatInput const &input : kFloats) {
    if (input.name != name) continue;
    if (!Scalar(value, x)) return false;
    surface.*input.member = float(x);
    return true;
  }

  for (ModeInput const &input : kModes) {
    if (input.name != name) continue;
    if (!Scalar(value, x)) return false;
    surface.*input.member = int(std::lround(x));
    return true;
  }

  for (ColorInput const &input : kColors) {
    if (input.name != name) continue;
    if (value.IsHolding<GfVec3f>()) surface.*input.member = value.UncheckedGet<GfVec3f>();
    else if (value.IsHolding<GfVec3d>()) surface.*input.member = GfVec3f(value.UncheckedGet<GfVec3d>());
    else if (Scalar(value, x)) surface.*input.member = GfVec3f(float(x));
    else return false;
    return true;
  }

  return false;
}

HdAkariSurfaceLook HdAkariApproximatePxrSurface(HdAkariPxrSurface const &s)
{
  constexpr float kFuzzAlbedo = 0.25f;
  constexpr float eps = 1e-6f;

  const GfVec3f coat = FaceReflectance(s.clearcoatFresnelMode, s.clearcoatFaceColor, s.clearcoatEdgeColor,
                                       s.clearcoatIor, s.clearcoatExtinctionCoeff);
  const GfVec3f absorbed = Mix(GfVec3f(1.0f), Saturate(s.clearcoatAbsorptionTint), Saturate(s.clearcoatThickness));
  const GfVec3f under = Mul(GfVec3f(1.0f) - coat, absorbed);

  GfVec3f primary = FaceReflectance(s.specularFresnelMode, s.specularFaceColor, s.specularEdgeColor,
                                    s.specularIor, s.specularExtinctionCoeff);
  if (s.iridescenceFaceGain > 0.0f) {
    GfVec3f film = (s.iridescencePrimaryColor + s.iridescenceSecondaryColor) * 0.5f;
    film /= std::max(Brightness(film), eps);
    primary = Saturate(Mix(primary, Mul(primary, film), Saturate(s.iridescenceFaceGain)));
  }

  const GfVec3f rough = FaceReflectance(s.roughSpecularFresnelMode, s.roughSpecularFaceColor, s.roughSpecularEdgeColor,
                                        s.roughSpecularIor, s.roughSpecularExtinctionCoeff);
  const float transmit = Saturate(s.refractionGain);
  const GfVec3f glass = GfVec3f(Reflectance(s.glassIor, 0.0f) * std::max(Saturate(s.reflectionGain), transmit));

  const GfVec3f lobes[] = {coat, Mul(under, primary), Mul(under, rough), Mul(under, glass)};
  const float roughnesses[] = {s.clearcoatRoughness, s.specularRoughness, s.roughSpecularRoughness, s.glassRoughness};
  GfVec3f specular(0.0f);
  float weight = 0.0f, roughness = 0.0f;
  for (int i = 0; i < 4; ++i) {
    specular += lobes[i];
    const float w = Brightness(lobes[i]);
    weight += w;
    roughness += w * roughnesses[i];
  }

  specular = Saturate(specular);

  GfVec3f diffuse = s.diffuseColor * std::max(s.diffuseGain, 0.0f);
  diffuse = Mix(diffuse, s.subsurfaceColor, Saturate(s.subsurfaceGain));
  diffuse = Mix(diffuse, s.singlescatterColor, Saturate(s.singlescatterGain));
  diffuse = Mix(diffuse, s.fuzzColor, kFuzzAlbedo * Saturate(s.fuzzGain));
  diffuse = Saturate(Mul(Mul(diffuse, s.irradianceTint), under) * (1.0f - transmit));

  HdAkariSurfaceLook look;
  const float oneMinusSpecular = 1.0f - MaxOf(specular);
  look.metallic = SolveMetallic(Brightness(diffuse), Brightness(specular), oneMinusSpecular) * (1.0f - transmit);
  const float m = look.metallic;
  const GfVec3f fromDiffuse = diffuse * (oneMinusSpecular / (1.0f - 0.04f) / std::max(1.0f - m, eps));
  const GfVec3f fromSpecular = (specular - GfVec3f(0.04f * (1.0f - m))) / std::max(m, eps);
  look.color = Saturate(Mix(fromDiffuse, fromSpecular, m * m));
  look.color = Saturate(Mix(look.color, s.refractionColor, transmit));
  look.roughness = Saturate(weight > eps ? roughness / weight : 1.0f);
  look.opacity = Saturate(s.presence) * (1.0f - transmit);
  look.emissive = s.glowColor * std::max(s.glowGain, 0.0f);
  return look;
}

PXR_NAMESPACE_CLOSE_SCOPE
