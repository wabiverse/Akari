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
);

namespace {

/// Finds the node feeding a given (nodePath, inputName) via a relationship,
/// and which of its outputs it feeds from.
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

/// Extracts an asset path parameter (e.g. a UsdUVTexture's "file" input).
std::string
GetAssetPathParam(HdMaterialNode const &node, TfToken const &paramName)
{
  auto it = node.parameters.find(paramName);
  if (it == node.parameters.end() || !it->second.IsHolding<SdfAssetPath>()) return std::string();
  SdfAssetPath const &assetPath = it->second.UncheckedGet<SdfAssetPath>();
  std::string resolved = assetPath.GetResolvedPath();
  return !resolved.empty() ? resolved : assetPath.GetAssetPath();
}

/// If `inputName` on `previewSurfaceNode` is fed by a UsdUVTexture
/// node, returns that texture's resolved file path.
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
    if (varIt != uvNode->parameters.end() && varIt->second.IsHolding<std::string>()) {
      textures.uvVarname = TfToken(varIt->second.UncheckedGet<std::string>());
    }
  }

  textures.hasAny = true;
  return path;
}

/// The color `input` on `node` takes, through a PxrColorCorrect whose gamma linearizes an sRGB pick or map,
/// out of a texture or a Ptex, which lands in `textures`.
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

/// Reads UsdPreviewSurface's diffuseColor/opacity/roughness/metallic
/// from the prim's bound material.
void HdAkariApplyMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                          GfVec3f &color, float &opacity,
                          float &roughness, float &metallic,
                          float &opacityThreshold,
                          HdAkariMaterialTextures &textures,
                          SdfPath &materialIdOut)
{
  HdAkariApplyMaterialId(sceneDelegate, sceneDelegate->GetMaterialId(id), color, opacity, roughness, metallic,
                         opacityThreshold, textures, materialIdOut);
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
    opacity = 1.0f - std::clamp((transparency[0] + transparency[1] + transparency[2]) / 3.0f, 0.0f, 1.0f);
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

/// Fetches the prim's raw UV primvar, remapped into its atlas cell.
void HdAkariComputeAtlasUvs(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                            HdAkariMaterialTextures const &textures, HdAkariAtlasCell const &cell,
                            VtVec3iArray const &triangleIndices, VtVec2fArray &outUvs)
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

  // looks up one candidate UV primvar, expands it to one
  // UV per triangle corner, and remaps it into the atlas cell.
  auto tryVarname = [&](TfToken const &varname) -> bool {
    HdInterpolation interp;
    if (!findInterpolation(varname, interp)) return false;

    VtIntArray uvIndices;
    VtValue uvVal = sceneDelegate->GetIndexedPrimvar(id, varname, &uvIndices);
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
    for (size_t i = 0; i < cornerCount; ++i) {
      float localU = (rawUvs[i][0] - cell.tileU0) / std::max(cell.tileUSpan, 1e-6f);
      float localV = (rawUvs[i][1] - cell.tileV0) / std::max(cell.tileVSpan, 1e-6f);
      // UDIM materials (tileUSpan/tileVSpan > 1) clamp.
      bool isUdim = cell.tileUSpan > 1.0f || cell.tileVSpan > 1.0f;
      if (isUdim) {
        localU = std::clamp(localU, 0.0f, 1.0f);
        localV = std::clamp(localV, 0.0f, 1.0f);
      } else {
        localU -= std::floor(localU);
        localV -= std::floor(localV);
      }

      outUvs[i] = GfVec2f(cell.u0 + localU * (cell.u1 - cell.u0),
                          cell.v0 + localV * (cell.v1 - cell.v0));
    }

    return true;
  };

  // try the material's declared UV varname first,
  // then fall back to the "st" primvar.
  static const TfToken kSt("st");
  if (tryVarname(textures.uvVarname)) {
    return;
  }

  if (textures.uvVarname != kSt && tryVarname(kSt)) {
    return;
  }
}

void HdAkariSyncMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                         HdAkariTextureAtlas *atlas, HdMeshUtil &meshUtil,
                         HdAkariMeshData &data,
                         HdMeshTopology const *topology,
                         VtIntArray const *primitiveParams)
{
  HdAkariMaterialTextures textures;
  SdfPath materialId;
  float opacityThreshold = 0.0f;
  HdAkariApplyMaterial(sceneDelegate, id, data.displayColor, data.opacity,
                       data.roughness, data.metallic, opacityThreshold, textures, materialId);
  data.transparent = opacityThreshold <= 0.0f && textures.opacityPath.empty() && data.opacity < 0.98f;
  const GfVec3f &e = textures.emissiveColor;
  data.emitter = textures.colorPath.empty()
              && std::max({data.displayColor[0], data.displayColor[1], data.displayColor[2]}) < 0.02f
              && (!textures.emissivePath.empty() || std::max({e[0], e[1], e[2]}) > 0.5f);

  // bake/lookup this material's shared texture atlas cell.
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
                                                 textures.emissivePath, textures.emissiveColor, textures.sources);
    HdAkariComputeAtlasUvs(sceneDelegate, id, meshUtil, textures, cell,
                           data.triangleIndices, data.uvs);
  }

  if (!atlas || !topology || !primitiveParams) return;

  // each triangle's Ptex face, what its streamed tiles key on.
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
  if (subsets.empty() || primitiveParams->size() != data.triangleIndices.size() ||
      data.uvs.size() != data.triangleIndices.size() * 3) {
    return;
  }

  std::vector<int> faceSubset(size_t(topology->GetNumFaces()), -1);
  for (size_t s = 0; s < subsets.size(); ++s) {
    if (subsets[s].type != HdGeomSubset::TypeFaceSet || subsets[s].materialId.IsEmpty()) continue;
    for (int face : subsets[s].indices) {
      if (face >= 0 && size_t(face) < faceSubset.size()) faceSubset[size_t(face)] = int(s);
    }
  }

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
      noteUser(materialId.GetString(), id);
      HdAkariAtlasCell cell = atlas->GetOrBakeCell(materialId.GetString(),
                                                   textures.roughnessPath, roughness,
                                                   textures.metallicPath, metallic,
                                                   textures.opacityPath, opacity,
                                                   opacityThreshold,
                                                   textures.colorPath, color,
                                                   textures.normalPath,
                                                   textures.emissivePath, textures.emissiveColor, textures.sources);
      VtVec2fArray uvs;
      HdAkariComputeAtlasUvs(sceneDelegate, id, meshUtil, textures, cell, data.triangleIndices, uvs);
      it = subsetUvs.emplace(materialId, std::move(uvs)).first;
    }

    VtVec2fArray const &uvs = it->second;
    if (uvs.size() != data.uvs.size()) continue;
    for (size_t c = 0; c < 3; ++c) data.uvs[t * 3 + c] = uvs[t * 3 + c];
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
