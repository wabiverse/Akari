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
# include <Tf/stringUtils.h>
# include <Hd/material.h>
# include <Hd/meshUtil.h>
# include <Hd/geomSubset.h>
# include <Hd/meshTopology.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <Hd/types.h>
# include <Sdf/assetPath.h>
# include <Gf/vec2f.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
# include <pxr/base/tf/stringUtils.h>
# include <pxr/imaging/hd/material.h>
# include <pxr/imaging/hd/meshUtil.h>
# include <pxr/imaging/hd/geomSubset.h>
# include <pxr/imaging/hd/meshTopology.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/imaging/hd/types.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/base/gf/vec2f.h>
#endif

#include "HdAkari/materialBinding.h"
#include "HdAkari/ptex.h"
#include "HdAkari/pxrSurface.h"
#include "HdAkari/scene.h"

#include <algorithm>
#include <cmath>
#include <shared_mutex>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  (bumpNormal)
  (emitColor)
  (presence)
  (specular)
);

namespace {

/// the node feeding an input through a relationship and which of its outputs feeds it
HdMaterialNode const *
FindUpstreamNode(HdMaterialNetwork const &network, SdfPath const &nodePath, TfToken const &inputName,
                 TfToken *outputName = nullptr)
{
  for (HdMaterialRelationship const &rel : network.relationships) {
    if (rel.outputId != nodePath || rel.outputName != inputName) continue;
    for (HdMaterialNode const &node : network.nodes) {
      if (node.path == rel.inputId) {
        if (outputName) *outputName = rel.inputName;
        return &node;
      }
    }
  }

  return nullptr;
}

/// an asset path parameter, like a texture's file input
std::string
GetAssetPathParam(HdMaterialNode const &node, TfToken const &paramName)
{
  auto it = node.parameters.find(paramName);
  if (it == node.parameters.end() || !it->second.IsHolding<SdfAssetPath>()) return std::string();
  SdfAssetPath const &assetPath = it->second.UncheckedGet<SdfAssetPath>();
  std::string resolved = assetPath.GetResolvedPath();
  return !resolved.empty() ? resolved : assetPath.GetAssetPath();
}

/// the resolved file of the texture feeding `inputName` on the preview surface, if one does
std::string
ResolveTextureConnection(HdMaterialNetwork const &network, HdMaterialNode const &previewSurfaceNode,
                         TfToken const &inputName, HdAkariMaterialTextures &textures,
                         int *sourceChannel = nullptr)
{
  static const TfToken kUsdUVTexture("UsdUVTexture");
  static const TfToken kPxrTexture("PxrTexture"), kPxrNormalMap("PxrNormalMap");
  static const TfToken kUsdPrimvarReader("UsdPrimvarReader_float2");
  static const TfToken kFile("file"), kFilename("filename");
  static const TfToken kSt("st");
  static const TfToken kVarname("varname");

  TfToken output;
  HdMaterialNode const *texNode = FindUpstreamNode(network, previewSurfaceNode.path, inputName, &output);
  if (!texNode) return std::string();
  const bool renderman = texNode->identifier == kPxrTexture || texNode->identifier == kPxrNormalMap;
  if (!renderman && texNode->identifier != kUsdUVTexture) return std::string();
  if (sourceChannel) {
    static const TfToken kG("g"), kB("b"), kA("a"), kResultG("resultG"), kResultB("resultB"), kResultA("resultA");
    *sourceChannel = output == kA || output == kResultA ? 3 : output == kB || output == kResultB ? 2
                   : output == kG || output == kResultG ? 1 : 0;
  }

  std::string path = GetAssetPathParam(*texNode, renderman ? kFilename : kFile);
  if (path.empty()) return std::string();

  HdMaterialNode const *uvNode = FindUpstreamNode(network, texNode->path, kSt);
  if (uvNode && uvNode->identifier == kUsdPrimvarReader) {
    auto varIt = uvNode->parameters.find(kVarname);

    // authored readers carry a string, generated ones like the draw mode cards carry a token.
    if (varIt != uvNode->parameters.end() && varIt->second.IsHolding<std::string>()) {
      textures.uvVarname = TfToken(varIt->second.UncheckedGet<std::string>());
    } else if (varIt != uvNode->parameters.end() && varIt->second.IsHolding<TfToken>()) {
      textures.uvVarname = varIt->second.UncheckedGet<TfToken>();
    }
  }

  textures.hasAny = true;
  return path;
}

/// whether a node reads a primvar straight off the gprim, as a painted displayColor is read
bool
IsPrimvarReader(HdMaterialNode const &node)
{
  static const TfToken kPxrPrimvar("PxrPrimvar");
  return node.identifier == kPxrPrimvar || TfStringStartsWith(node.identifier.GetString(), "UsdPrimvarReader_float3");
}

/// the color an input takes, through a color correct that linearizes an srgb pick or map, out of a texture or ptex into `textures`
GfVec3f
ResolveColor(HdMaterialNetwork const &network, HdMaterialNode const &node, TfToken const &input, GfVec3f fallback,
             HdAkariMaterialTextures &textures)
{
  static const TfToken kPxrColorCorrect("PxrColorCorrect"), kPxrPtexture("PxrPtexture");
  static const TfToken kInputRGB("inputRGB"), kGamma("gamma"), kFilename("filename");
  auto param = [](HdMaterialNode const &n, TfToken const &name, GfVec3f fallback) {
    auto it = n.parameters.find(name);
    return it != n.parameters.end() && it->second.IsHolding<GfVec3f>() ? it->second.UncheckedGet<GfVec3f>() : fallback;
  };

  GfVec3f color = param(node, input, fallback), gamma(1.0f);
  HdMaterialNode const *feeding = &node;
  TfToken feedingInput = input;
  HdMaterialNode const *upstream = FindUpstreamNode(network, node.path, input);
  if (upstream && upstream->identifier == kPxrColorCorrect) {
    color = param(*upstream, kInputRGB, color);
    gamma = param(*upstream, kGamma, gamma);
    feeding = upstream;
    feedingInput = kInputRGB;
    upstream = FindUpstreamNode(network, upstream->path, kInputRGB);
  }

  // a primvar reader hands the color over per vertex, so the surface itself stays white under it
  if (upstream && IsPrimvarReader(*upstream)) return GfVec3f(1.0f);

  if (upstream && upstream->identifier == kPxrPtexture) {
    textures.ptexPath = GetAssetPathParam(*upstream, kFilename);
  } else {
    textures.colorPath = ResolveTextureConnection(network, *feeding, feedingInput, textures);
  }

  if (!textures.ptexPath.empty()) return HdAkariPtexAverageColor(textures.ptexPath);
  for (int k = 0; k < 3; ++k) color[k] = std::pow(std::max(color[k], 0.0f), 1.0f / std::max(gamma[k], 1e-5f));
  return color;
}

}  // namespace

/// reads the preview surface's color, opacity, roughness and metallic from the prim's bound material
void HdAkariApplyMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                          GfVec3f &color, float &opacity,
                          float &roughness, float &metallic,
                          float &opacityThreshold,
                          HdAkariMaterialTextures &textures,
                          SdfPath &materialIdOut)
{
  HdAkariApplyMaterialId(sceneDelegate, sceneDelegate->GetMaterialId(id), color, opacity, roughness, metallic,
                         opacityThreshold, textures, materialIdOut);

  // the gprim's own display opacity dims the material, which is how the viewport ghosts a mesh while its cage is edited
  const VtValue display = sceneDelegate->Get(id, HdTokens->displayOpacity);
  if (display.IsHolding<VtFloatArray>()) {
    VtFloatArray const &values = display.UncheckedGet<VtFloatArray>();
    if (!values.empty()) opacity *= values[0];
  } else if (display.IsHolding<float>()) {
    opacity *= display.UncheckedGet<float>();
  }
}

namespace {

struct ParsedMaterial
{
  GfVec3f color;
  float opacity, roughness, metallic, opacityThreshold;
  HdAkariMaterialTextures textures;
};

std::shared_mutex parsedMutex;
std::unordered_map<SdfPath, ParsedMaterial, SdfPath::Hash> parsedMaterials;

void ParseMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &materialId,
                   GfVec3f &color, float &opacity,
                   float &roughness, float &metallic,
                   float &opacityThreshold,
                   HdAkariMaterialTextures &textures)
{
  const VtValue matResource = sceneDelegate->GetMaterialResource(materialId);
  if (!matResource.IsHolding<HdMaterialNetworkMap>()) {
    return;
  }

  const HdMaterialNetworkMap &networkMap = matResource.UncheckedGet<HdMaterialNetworkMap>();
  auto netIt = networkMap.map.find(HdMaterialTerminalTokens->surface);
  if (netIt == networkMap.map.end()) {
    return;
  }

  const HdMaterialNetwork &network = netIt->second;

  static const TfToken kUsdPreviewSurface("UsdPreviewSurface");
  static const TfToken kDiffuseColor("diffuseColor");
  static const TfToken kOpacity("opacity");
  static const TfToken kRoughness("roughness");
  static const TfToken kMetallic("metallic");
  static const TfToken kOpacityThreshold("opacityThreshold");
  static const TfToken kNormal("normal");
  static const TfToken kEmissiveColor("emissiveColor");
  static const TfToken kIor("ior");
  static const TfToken kUseSpecularWorkflow("useSpecularWorkflow");
  static const TfToken kSpecularColor("specularColor");

  static const TfToken kPxrSurface("PxrSurface");
  static const TfToken kSpecularFaceColor("specularFaceColor"), kSpecularRoughness("specularRoughness"),
    kPresence("presence"), kGlowColor("glowColor"), kBumpNormal("bumpNormal");
  for (HdMaterialNode const &node : network.nodes) {
    if (node.identifier != kPxrSurface) continue;
    HdAkariPxrSurface surface;
    for (auto const &[name, value] : node.parameters) HdAkariSetPxrSurfaceInput(surface, name, value);
    surface.diffuseColor = ResolveColor(network, node, kDiffuseColor, surface.diffuseColor, textures);
    const HdAkariSurfaceLook look = HdAkariApproximatePxrSurface(surface);
    color = look.color;
    metallic = look.metallic;
    roughness = look.roughness;
    opacity = look.opacity;
    textures.emissiveColor = look.emissive;
    textures.specular = look.specular;
    if (metallic >= 0.5f) {
      HdAkariMaterialTextures face = textures;
      face.colorPath = ResolveTextureConnection(network, node, kSpecularFaceColor, face);
      if (!face.colorPath.empty()) {
        textures = face;
        textures.ptexPath.clear();
      }
    }

    textures.roughnessPath = ResolveTextureConnection(network, node, kSpecularRoughness, textures,
                                                      &textures.sources.roughness);
    textures.opacityPath = ResolveTextureConnection(network, node, kPresence, textures, &textures.sources.opacity);
    textures.emissivePath = ResolveTextureConnection(network, node, kGlowColor, textures);
    textures.normalPath = ResolveTextureConnection(network, node, kBumpNormal, textures);
    return;
  }

  static const TfToken kPxrDisneyBsdf("PxrDisneyBsdf"), kBaseColor("baseColor");
  for (HdMaterialNode const &node : network.nodes) {
    if (node.identifier != kPxrDisneyBsdf) continue;
    auto param = [](HdMaterialNode const &n, TfToken const &name, auto fallback) {
      auto it = n.parameters.find(name);
      return it != n.parameters.end() && it->second.IsHolding<decltype(fallback)>()
        ? it->second.UncheckedGet<decltype(fallback)>() : fallback;
    };

    color = ResolveColor(network, node, kBaseColor, param(node, kBaseColor, GfVec3f(0.18f)), textures);
    metallic = param(node, kMetallic, 0.0f);
    textures.metallicPath = ResolveTextureConnection(network, node, kMetallic, textures, &textures.sources.metallic);
    roughness = param(node, kRoughness, 0.25f);
    textures.roughnessPath = ResolveTextureConnection(network, node, kRoughness, textures, &textures.sources.roughness);
    opacity = param(node, _tokens->presence, 1.0f);
    textures.opacityPath = ResolveTextureConnection(network, node, _tokens->presence, textures, &textures.sources.opacity);
    textures.specular = GfVec3f(std::clamp(0.08f * param(node, _tokens->specular, 0.5f), 0.0f, 1.0f));
    textures.emissiveColor = param(node, _tokens->emitColor, GfVec3f(0.0f));
    textures.emissivePath = ResolveTextureConnection(network, node, _tokens->emitColor, textures);
    textures.normalPath = ResolveTextureConnection(network, node, _tokens->bumpNormal, textures);
    return;
  }

  static const TfToken kPxrMayaLambert("PxrMayaLambert"), kPxrMayaBlinn("PxrMayaBlinn");
  static const TfToken kColor("color"), kDiffuse("diffuse"), kTransparency("transparency"),
    kIncandescence("incandescence"), kEccentricity("eccentricity"), kNormalCamera("normalCamera");
  for (HdMaterialNode const &node : network.nodes) {
    const bool blinn = node.identifier == kPxrMayaBlinn;
    if (!blinn && node.identifier != kPxrMayaLambert) continue;
    auto param = [&](TfToken const &name, auto fallback) {
      auto it = node.parameters.find(name);
      return it != node.parameters.end() && it->second.IsHolding<decltype(fallback)>()
        ? it->second.UncheckedGet<decltype(fallback)>() : fallback;
    };

    color = param(kColor, GfVec3f(0.5f)) * param(kDiffuse, 0.8f);
    textures.colorPath = ResolveTextureConnection(network, node, kColor, textures);
    const GfVec3f transparency = param(kTransparency, GfVec3f(0.0f));
    const float clarity = std::clamp((transparency[0] + transparency[1] + transparency[2]) / 3.0f, 0.0f, 1.0f);
    opacity = 1.0f - clarity;

    // maya transparency tints the light passing through, so clear surfaces take its hue over their diffuse color.
    if (clarity > 0.0f && textures.colorPath.empty()) {
      const float peak = std::max({transparency[0], transparency[1], transparency[2], 1e-6f});
      const GfVec3f tint = transparency / peak;
      color = color * (1.0f - clarity) + tint * clarity;
    }
    roughness = blinn ? std::sqrt(std::clamp(param(kEccentricity, 0.3f), 0.0f, 1.0f)) : 1.0f;
    metallic = 0.0f;
    textures.emissiveColor = param(kIncandescence, GfVec3f(0.0f));
    textures.emissivePath = ResolveTextureConnection(network, node, kIncandescence, textures);
    textures.normalPath = ResolveTextureConnection(network, node, kNormalCamera, textures);
    return;
  }

  bool foundPreviewSurface = false;
  for (HdMaterialNode const &node : network.nodes) {
    if (node.identifier != kUsdPreviewSurface) continue;
    foundPreviewSurface = true;

    auto colorIt = node.parameters.find(kDiffuseColor);
    if (colorIt != node.parameters.end() && colorIt->second.IsHolding<GfVec3f>()) {
      color = colorIt->second.UncheckedGet<GfVec3f>();
    } else {
      textures.colorPath = ResolveTextureConnection(network, node, kDiffuseColor, textures);
      HdMaterialNode const *texNode = textures.colorPath.empty()
        ? FindUpstreamNode(network, node.path, kDiffuseColor, nullptr) : nullptr;

      // a primvar reader hands the color over per vertex, so the surface itself stays white under it
      if (texNode && IsPrimvarReader(*texNode)) color = GfVec3f(1.0f);
      if (texNode && TfStringContains(texNode->identifier.GetString(), "Ptex")) {
        static const TfToken kFile("file"), kFilename("filename");
        textures.ptexPath = GetAssetPathParam(*texNode, kFile);
        if (textures.ptexPath.empty()) textures.ptexPath = GetAssetPathParam(*texNode, kFilename);
        if (!textures.ptexPath.empty()) color = HdAkariPtexAverageColor(textures.ptexPath);
      }
    }

    auto opacityIt = node.parameters.find(kOpacity);
    if (opacityIt != node.parameters.end() && opacityIt->second.IsHolding<float>()) {
      opacity = opacityIt->second.UncheckedGet<float>();
    } else {
      textures.opacityPath = ResolveTextureConnection(network, node, kOpacity, textures, &textures.sources.opacity);
    }

    auto threshIt = node.parameters.find(kOpacityThreshold);
    if (threshIt != node.parameters.end() && threshIt->second.IsHolding<float>()) {
      opacityThreshold = threshIt->second.UncheckedGet<float>();
    }

    auto roughnessIt = node.parameters.find(kRoughness);
    if (roughnessIt != node.parameters.end() && roughnessIt->second.IsHolding<float>()) {
      roughness = roughnessIt->second.UncheckedGet<float>();
    } else {
      textures.roughnessPath = ResolveTextureConnection(network, node, kRoughness, textures, &textures.sources.roughness);
    }

    auto metallicIt = node.parameters.find(kMetallic);
    if (metallicIt != node.parameters.end() && metallicIt->second.IsHolding<float>()) {
      metallic = metallicIt->second.UncheckedGet<float>();
    } else {
      textures.metallicPath = ResolveTextureConnection(network, node, kMetallic, textures, &textures.sources.metallic);
    }

    // index of refraction sets what the surface reflects facing the eye, 1.5 giving the usual four percent
    float ior = 1.5f;
    auto iorIt = node.parameters.find(kIor);
    if (iorIt != node.parameters.end() && iorIt->second.IsHolding<float>()) {
      ior = std::max(iorIt->second.UncheckedGet<float>(), 1.0f);
    }
    const float facing = (ior - 1.0f) / (ior + 1.0f);
    textures.specular = GfVec3f(std::clamp(facing * facing, 0.0f, 1.0f));

    // the specular workflow names that reflectance outright and leaves metallic unused
    bool specularWorkflow = false;
    auto workflowIt = node.parameters.find(kUseSpecularWorkflow);
    if (workflowIt != node.parameters.end()) {
      if (workflowIt->second.IsHolding<int>()) specularWorkflow = workflowIt->second.UncheckedGet<int>() != 0;
      else if (workflowIt->second.IsHolding<bool>()) specularWorkflow = workflowIt->second.UncheckedGet<bool>();
    }
    if (specularWorkflow) {
      metallic = 0.0f;
      textures.metallicPath.clear();
      auto specIt = node.parameters.find(kSpecularColor);
      if (specIt != node.parameters.end() && specIt->second.IsHolding<GfVec3f>()) {
        const GfVec3f tint = specIt->second.UncheckedGet<GfVec3f>();
        textures.specular = GfVec3f(std::clamp(tint[0], 0.0f, 1.0f),
                                    std::clamp(tint[1], 0.0f, 1.0f),
                                    std::clamp(tint[2], 0.0f, 1.0f));
      }
    }

    auto emissiveIt = node.parameters.find(kEmissiveColor);
    if (emissiveIt != node.parameters.end() && emissiveIt->second.IsHolding<GfVec3f>()) {
      textures.emissiveColor = emissiveIt->second.UncheckedGet<GfVec3f>();
    } else {
      textures.emissivePath = ResolveTextureConnection(network, node, kEmissiveColor, textures);
    }

    textures.normalPath = ResolveTextureConnection(network, node, kNormal, textures);
    break;
  }
}

}  // namespace

void HdAkariApplyMaterialId(HdSceneDelegate *sceneDelegate, SdfPath const &materialId,
                            GfVec3f &color, float &opacity,
                            float &roughness, float &metallic,
                            float &opacityThreshold,
                            HdAkariMaterialTextures &textures,
                            SdfPath &materialIdOut)
{
  if (materialId.IsEmpty()) {
    return;
  }

  materialIdOut = materialId;

  ParsedMaterial parsed;
  bool found = false;
  {
    std::shared_lock<std::shared_mutex> lock(parsedMutex);
    const auto it = parsedMaterials.find(materialId);
    if (it != parsedMaterials.end()) {
      parsed = it->second;
      found = true;
    }
  }

  if (!found) {
    const float unset = NAN;
    parsed = {GfVec3f(unset), unset, unset, unset, unset, {}};
    ParseMaterial(sceneDelegate, materialId, parsed.color, parsed.opacity, parsed.roughness, parsed.metallic,
                  parsed.opacityThreshold, parsed.textures);
    std::unique_lock<std::shared_mutex> lock(parsedMutex);
    parsedMaterials.emplace(materialId, parsed);
  }

  if (!std::isnan(parsed.color[0])) color = parsed.color;
  if (!std::isnan(parsed.opacity)) opacity = parsed.opacity;
  if (!std::isnan(parsed.roughness)) roughness = parsed.roughness;
  if (!std::isnan(parsed.metallic)) metallic = parsed.metallic;
  if (!std::isnan(parsed.opacityThreshold)) opacityThreshold = parsed.opacityThreshold;
  textures = parsed.textures;
}

void HdAkariForgetMaterial(SdfPath const &materialId)
{
  std::unique_lock<std::shared_mutex> lock(parsedMutex);
  parsedMaterials.erase(materialId);
}

namespace {

std::mutex usersMutex;
std::unordered_map<std::string, std::unordered_set<SdfPath, SdfPath::Hash>> materialUsers;

void noteUser(std::string const &materialKey, SdfPath const &id)
{
  std::lock_guard<std::mutex> lock(usersMutex);
  materialUsers[materialKey].insert(id);
}

} // namespace

std::vector<SdfPath> HdAkariMaterialUsers(std::string const &materialKey)
{
  std::lock_guard<std::mutex> lock(usersMutex);
  auto it = materialUsers.find(materialKey);
  return it == materialUsers.end() ? std::vector<SdfPath>() : std::vector<SdfPath>(it->second.begin(), it->second.end());
}

/// fetches the prim's raw uv primvar, remapped into its atlas cell.
void HdAkariComputeAtlasUvs(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                            HdAkariMaterialTextures const &textures, HdAkariAtlasCell const &cell,
                            VtVec3iArray const &triangleIndices, VtVec2fArray &outUvs,
                            HdAkariRefinedPrimvars const *refined)
{
  const size_t cornerCount = triangleIndices.size() * 3;

  // a constant material only needs one uv, the renderer repeats it over the corners.
  if (cell.constantIndex >= 0) {
    const float row = -float(cell.constantIndex + 1);
    outUvs.assign(cornerCount == 0 ? 0 : 1, GfVec2f(row, row));
    return;
  }

  outUvs.assign(cornerCount == 0 ? 0 : 1, GfVec2f((cell.u0 + cell.u1) * 0.5f, (cell.v0 + cell.v1) * 0.5f));
  if (!textures.hasAny) return;

  auto findInterpolation = [&](TfToken const &varname, HdInterpolation &out) -> bool {
    for (int i = 0; i < HdInterpolationCount; ++i) {
      for (HdPrimvarDescriptor const &pv : sceneDelegate->GetPrimvarDescriptors(id, HdInterpolation(i))) {
        if (pv.name == varname) {
          out = HdInterpolation(i);
          return true;
        }
      }
    }

    return false;
  };

  // looks up one uv primvar, expands it to a uv per triangle corner and remaps it into the atlas cell
  auto tryVarname = [&](TfToken const &varname) -> bool {
    HdInterpolation interp;
    if (!findInterpolation(varname, interp)) return false;

    VtIntArray uvIndices;
    VtValue uvVal;
    if (refined) {
      if (!refined->Get(sceneDelegate, id, varname, interp, &uvVal)) return false;
    } else {
      uvVal = sceneDelegate->GetIndexedPrimvar(id, varname, &uvIndices);
    }
    if (!uvVal.IsHolding<VtVec2fArray>()) return false;
    VtVec2fArray const &uvValues = uvVal.UncheckedGet<VtVec2fArray>();
    if (uvValues.empty()) return false;

    VtVec2fArray flatUv;
    if (!uvIndices.empty()) {
      flatUv.resize(uvIndices.size());
      for (size_t i = 0; i < uvIndices.size(); ++i) {
        int idx = uvIndices[i];
        flatUv[i] = (idx >= 0 && size_t(idx) < uvValues.size()) ? uvValues[idx] : GfVec2f(0.0f, 0.0f);
      }
    } else {
      flatUv = uvValues;
    }

    if (flatUv.empty()) return false;

    VtVec2fArray rawUvs;
    if (interp == HdInterpolationVertex || interp == HdInterpolationVarying) {
      rawUvs.resize(cornerCount);
      for (size_t t = 0; t < triangleIndices.size(); ++t) {
        for (int c = 0; c < 3; ++c) {
          int idx = triangleIndices[t][c];
          rawUvs[t * 3 + c] = (idx >= 0 && size_t(idx) < flatUv.size()) ? flatUv[idx] : GfVec2f(0.0f, 0.0f);
        }
      }
    } else if (interp == HdInterpolationFaceVarying) {
      VtValue triangulated;
      HdMeshComputationResult result = meshUtil.ComputeTriangulatedFaceVaryingPrimvar(
          flatUv.cdata(), int(flatUv.size()), HdTypeFloatVec2, &triangulated);
      if (result != HdMeshComputationResult::Success || !triangulated.IsHolding<VtVec2fArray>()) return false;
      rawUvs = triangulated.UncheckedGet<VtVec2fArray>();
    } else {
      return false;
    }

    if (rawUvs.size() != cornerCount) return false;

    outUvs.resize(cornerCount);

    // udim materials clamp
    const bool isUdim = cell.tileUSpan > 1.0f || cell.tileVSpan > 1.0f;
    for (size_t t = 0; t < triangleIndices.size(); ++t) {
      GfVec2f local[3];
      for (int c = 0; c < 3; ++c) {
        local[c] = GfVec2f((rawUvs[t * 3 + c][0] - cell.tileU0) / std::max(cell.tileUSpan, 1e-6f),
                           (rawUvs[t * 3 + c][1] - cell.tileV0) / std::max(cell.tileVSpan, 1e-6f));
      }

      // a repeating texture wraps the whole triangle by one tile, so a corner on 1.0 stays the far edge, not 0.
      for (int a = 0; a < 2 && !isUdim; ++a) {
        const float shift = std::floor(std::min({local[0][a], local[1][a], local[2][a]}) + 1e-5f);
        for (int c = 0; c < 3; ++c) local[c][a] -= shift;
      }

      for (int c = 0; c < 3; ++c) {
        const float u = std::clamp(local[c][0], 0.0f, 1.0f), v = std::clamp(local[c][1], 0.0f, 1.0f);
        outUvs[t * 3 + c] = GfVec2f(cell.u0 + u * (cell.u1 - cell.u0), cell.v0 + v * (cell.v1 - cell.v0));
      }
    }

    return true;
  };

  // tries the material's uv name first, then the st primvar
  static const TfToken kSt("st");
  if (tryVarname(textures.uvVarname)) {
    return;
  }

  if (textures.uvVarname != kSt && tryVarname(kSt)) {
    return;
  }
}

/// whether a material can cut holes in a mesh's shadow.
static bool HdAkariShadowCutout(HdAkariMaterialTextures const &textures, float opacity, float opacityThreshold)
{
  return !textures.opacityPath.empty() || !textures.ptexPath.empty() || opacityThreshold > 0.0f || opacity < 0.98f;
}

HdAkariSurface HdAkariClassifySurface(HdAkariMaterialTextures const &textures, GfVec3f const &color, float opacity,
                                      float opacityThreshold)
{
  const bool constantOpacity = textures.opacityPath.empty();
  const GfVec3f &e = textures.emissiveColor;
  HdAkariSurface surface;
  surface.transparent = opacityThreshold <= 0.0f && constantOpacity && opacity < 0.98f;
  surface.hidden = opacityThreshold > 0.0f && constantOpacity && textures.ptexPath.empty() && opacity < opacityThreshold;
  surface.shadowCutout = HdAkariShadowCutout(textures, opacity, opacityThreshold);

  // a black glowing surface, or a glowing shell you see through like a blade's sheath, is light that casts no shadow.
  const bool glowing = !textures.emissivePath.empty() || std::max({e[0], e[1], e[2]}) > 0.5f;
  const bool black = textures.colorPath.empty() && std::max({color[0], color[1], color[2]}) < 0.02f;

  // so is a surface that gives out far more than it reflects, or a blade's core would shut its own lights inside it
  const float glow = std::max({e[0], e[1], e[2]});
  const float albedo = std::max({color[0], color[1], color[2]});
  const bool outshines = textures.colorPath.empty() && textures.emissivePath.empty()
                      && glow > 1.0f && glow > 8.0f * albedo;
  surface.emitter = glowing && (black || surface.transparent || outshines);
  return surface;
}

bool HdAkariShowsDisplayColor(HdSceneDelegate *sceneDelegate, SdfPath const &id)
{
  const SdfPath materialId = sceneDelegate->GetMaterialId(id);
  if (materialId.IsEmpty()) return false;

  const VtValue resource = sceneDelegate->GetMaterialResource(materialId);
  if (!resource.IsHolding<HdMaterialNetworkMap>()) return false;

  HdMaterialNetworkMap const &networks = resource.UncheckedGet<HdMaterialNetworkMap>();
  auto found = networks.map.find(HdMaterialTerminalTokens->surface);
  if (found == networks.map.end()) return false;

  static const TfToken kVarname("varname");
  for (HdMaterialNode const &node : found->second.nodes) {
    if (!IsPrimvarReader(node)) continue;
    auto it = node.parameters.find(kVarname);
    if (it == node.parameters.end()) continue;
    if (it->second.IsHolding<std::string>() && it->second.UncheckedGet<std::string>() == HdTokens->displayColor.GetString()) return true;
    if (it->second.IsHolding<TfToken>() && it->second.UncheckedGet<TfToken>() == HdTokens->displayColor) return true;
  }

  return false;
}

void HdAkariSyncMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                         HdAkariTextureAtlas *atlas, HdMeshUtil &meshUtil,
                         HdAkariMeshData &data,
                         HdMeshTopology const *topology,
                         VtIntArray const *primitiveParams,
                         HdAkariRefinedPrimvars const *refined)
{
  HdAkariMaterialTextures textures;
  SdfPath materialId;
  float opacityThreshold = 0.0f;
  HdAkariApplyMaterial(sceneDelegate, id, data.displayColor, data.opacity,
                       data.roughness, data.metallic, opacityThreshold, textures, materialId);
  const HdAkariSurface surface = HdAkariClassifySurface(textures, data.displayColor, data.opacity, opacityThreshold);
  data.transparent = surface.transparent;
  data.shadowCutout = surface.shadowCutout;
  data.emitter = surface.emitter;
  if (surface.hidden) data.visible = false;

  // bakes or looks up this material's shared atlas cell
  if (atlas) {
    const std::string cellKey = materialId.IsEmpty() ? id.GetString() : materialId.GetString();
    noteUser(cellKey, id);
    HdAkariAtlasCell cell = atlas->GetOrBakeCell(cellKey,
                                                 textures.roughnessPath, data.roughness,
                                                 textures.metallicPath, data.metallic,
                                                 textures.opacityPath, data.opacity,
                                                 opacityThreshold,
                                                 textures.colorPath, data.displayColor,
                                                 textures.normalPath,
                                                 textures.emissivePath, textures.emissiveColor, textures.sources,
                                                 textures.specular);
    HdAkariComputeAtlasUvs(sceneDelegate, id, meshUtil, textures, cell,
                           data.triangleIndices, data.uvs, refined);
  }

  if (!atlas || !topology || !primitiveParams) return;

  // each triangle's ptex face, what its streamed tiles key on.
  if (!textures.ptexPath.empty() && primitiveParams->size() == data.triangleIndices.size()) {
    VtIntArray faceRes = HdAkariPtexFaceRes(textures.ptexPath);
    VtIntArray const &counts = topology->GetFaceVertexCounts();
    VtIntArray const &indices = topology->GetFaceVertexIndices();
    if (HdAkariPtexMapId(textures.ptexPath) >= 0 && faceRes.size() == counts.size()) {
      std::vector<int> starts(counts.size() + 1, 0);
      for (size_t f = 0; f < counts.size(); ++f) starts[f + 1] = starts[f] + counts[f];

      // the face in the low bits, each corner's place on it two bits apiece above.
      VtIntArray triangleFaces(primitiveParams->size());
      for (size_t t = 0; t < primitiveParams->size(); ++t) {
        const int face = HdMeshUtil::DecodeFaceIndexFromCoarseFaceParam((*primitiveParams)[t]);
        int code = 0;
        for (int c = 0; c < 3 && face >= 0 && size_t(face) < counts.size(); ++c) {
          for (int k = 0; k < std::min(counts[face], 4); ++k) {
            const size_t at = size_t(starts[face] + k);
            if (at < indices.size() && indices[at] == data.triangleIndices.cdata()[t][c]) { code |= k << (c * 2); break; }
          }
        }

        triangleFaces[t] = face | (code << 24);
      }

      data.triangleFaces = std::move(triangleFaces);
      data.faceRes = std::move(faceRes);
      data.ptexMap = HdAkariPtexMapId(textures.ptexPath);
      if (data.ptexMap >= 0) {
        atlas->SetConstantsPtexMap(materialId.IsEmpty() ? id.GetString() : materialId.GetString(), data.ptexMap);
      }
    }
  }

  // material bound face subsets, their triangles take their own material's cell or constants row.
  HdGeomSubsets const &subsets = topology->GetGeomSubsets();
  const size_t cornerCount = data.triangleIndices.size() * 3;
  if (subsets.empty() || primitiveParams->size() != data.triangleIndices.size() || cornerCount == 0) {
    return;
  }

  std::vector<int> faceSubset(size_t(topology->GetNumFaces()), -1);
  bool bound = false;
  for (size_t s = 0; s < subsets.size(); ++s) {
    if (subsets[s].type != HdGeomSubset::TypeFaceSet || subsets[s].materialId.IsEmpty()) continue;
    for (int face : subsets[s].indices) {
      if (face >= 0 && size_t(face) < faceSubset.size()) { faceSubset[size_t(face)] = int(s); bound = true; }
    }
  }

  // a constant mesh material spreads its one uv over every corner, so the subsets can take theirs.
  if (!bound) return;
  if (data.uvs.size() == 1) data.uvs = VtVec2fArray(cornerCount, data.uvs[0]);
  if (data.uvs.size() != cornerCount) return;

  std::unordered_map<SdfPath, VtVec2fArray, SdfPath::Hash> subsetUvs;
  for (size_t t = 0; t < data.triangleIndices.size(); ++t) {
    const int face = HdMeshUtil::DecodeFaceIndexFromCoarseFaceParam((*primitiveParams)[t]);
    if (face < 0 || size_t(face) >= faceSubset.size() || faceSubset[size_t(face)] < 0) continue;
    SdfPath const &materialId = subsets[size_t(faceSubset[size_t(face)])].materialId;
    auto it = subsetUvs.find(materialId);
    if (it == subsetUvs.end()) {
      GfVec3f color = data.displayColor;
      float opacity = 1.0f, roughness = 0.5f, metallic = 0.0f, opacityThreshold = 0.0f;
      HdAkariMaterialTextures textures;
      SdfPath resolved;
      HdAkariApplyMaterialId(sceneDelegate, materialId, color, opacity, roughness, metallic,
                             opacityThreshold, textures, resolved);

      // if any subset's material cuts holes, the whole mesh keeps the alpha test.
      data.shadowCutout = data.shadowCutout || HdAkariShadowCutout(textures, opacity, opacityThreshold);
      noteUser(materialId.GetString(), id);
      HdAkariAtlasCell cell = atlas->GetOrBakeCell(materialId.GetString(),
                                                   textures.roughnessPath, roughness,
                                                   textures.metallicPath, metallic,
                                                   textures.opacityPath, opacity,
                                                   opacityThreshold,
                                                   textures.colorPath, color,
                                                   textures.normalPath,
                                                   textures.emissivePath, textures.emissiveColor, textures.sources,
                                                   textures.specular);
      VtVec2fArray uvs;
      HdAkariComputeAtlasUvs(sceneDelegate, id, meshUtil, textures, cell, data.triangleIndices, uvs, refined);
      it = subsetUvs.emplace(materialId, std::move(uvs)).first;
    }

    VtVec2fArray const &uvs = it->second;
    if (uvs.size() == 1) {
      for (size_t c = 0; c < 3; ++c) data.uvs[t * 3 + c] = uvs[0];
      continue;
    }

    if (uvs.size() != cornerCount) continue;
    for (size_t c = 0; c < 3; ++c) data.uvs[t * 3 + c] = uvs[t * 3 + c];
  }

}

PXR_NAMESPACE_CLOSE_SCOPE
