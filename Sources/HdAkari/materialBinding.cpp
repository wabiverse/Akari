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

#include "pxr/pxrns.h"

#include "HdAkari/materialBinding.h"
#include "HdAkari/scene.h"

#include <Hd/material.h>
#include <Hd/meshUtil.h>
#include <Hd/sceneDelegate.h>
#include <Hd/tokens.h>
#include <Hd/types.h>
#include <Sdf/assetPath.h>
#include <Gf/vec2f.h>

#include <algorithm>
#include <cmath>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// Finds the node feeding a given (nodePath, inputName) via a relationship.
HdMaterialNode const *
FindUpstreamNode(HdMaterialNetwork const &network, SdfPath const &nodePath, TfToken const &inputName)
{
  for (HdMaterialRelationship const &rel : network.relationships) {
    if (rel.outputId != nodePath || rel.outputName != inputName) continue;
    for (HdMaterialNode const &node : network.nodes) {
      if (node.path == rel.inputId) return &node;
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
                         TfToken const &inputName, HdAkariMaterialTextures &textures)
{
  static const TfToken kUsdUVTexture("UsdUVTexture");
  static const TfToken kUsdPrimvarReader("UsdPrimvarReader_float2");
  static const TfToken kFile("file");
  static const TfToken kSt("st");
  static const TfToken kVarname("varname");

  HdMaterialNode const *texNode = FindUpstreamNode(network, previewSurfaceNode.path, inputName);
  if (!texNode || texNode->identifier != kUsdUVTexture) return std::string();

  std::string path = GetAssetPathParam(*texNode, kFile);
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
  const SdfPath materialId = sceneDelegate->GetMaterialId(id);
  if (materialId.IsEmpty()) {
    return;
  }
  materialIdOut = materialId;

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

  bool foundPreviewSurface = false;
  for (HdMaterialNode const &node : network.nodes) {
    if (node.identifier != kUsdPreviewSurface) continue;
    foundPreviewSurface = true;

    auto colorIt = node.parameters.find(kDiffuseColor);
    if (colorIt != node.parameters.end() && colorIt->second.IsHolding<GfVec3f>()) {
      color = colorIt->second.UncheckedGet<GfVec3f>();
    } else {
      textures.colorPath = ResolveTextureConnection(network, node, kDiffuseColor, textures);
    }

    auto opacityIt = node.parameters.find(kOpacity);
    if (opacityIt != node.parameters.end() && opacityIt->second.IsHolding<float>()) {
      opacity = opacityIt->second.UncheckedGet<float>();
    } else {
      textures.opacityPath = ResolveTextureConnection(network, node, kOpacity, textures);
    }

    auto threshIt = node.parameters.find(kOpacityThreshold);
    if (threshIt != node.parameters.end() && threshIt->second.IsHolding<float>()) {
      opacityThreshold = threshIt->second.UncheckedGet<float>();
    }

    auto roughnessIt = node.parameters.find(kRoughness);
    if (roughnessIt != node.parameters.end() && roughnessIt->second.IsHolding<float>()) {
      roughness = roughnessIt->second.UncheckedGet<float>();
    } else {
      textures.roughnessPath = ResolveTextureConnection(network, node, kRoughness, textures);
    }

    auto metallicIt = node.parameters.find(kMetallic);
    if (metallicIt != node.parameters.end() && metallicIt->second.IsHolding<float>()) {
      metallic = metallicIt->second.UncheckedGet<float>();
    } else {
      textures.metallicPath = ResolveTextureConnection(network, node, kMetallic, textures);
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

/// Fetches the prim's raw UV primvar, remapped into its atlas cell.
void HdAkariComputeAtlasUvs(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                            HdAkariMaterialTextures const &textures, HdAkariAtlasCell const &cell,
                            VtVec3iArray const &triangleIndices, VtVec2fArray &outUvs)
{
  const size_t cornerCount = triangleIndices.size() * 3;
  outUvs.assign(cornerCount, GfVec2f((cell.u0 + cell.u1) * 0.5f, (cell.v0 + cell.v1) * 0.5f));
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
                         HdAkariMeshData &data)
{
  HdAkariMaterialTextures textures;
  SdfPath materialId;
  float opacityThreshold = 0.0f;
  HdAkariApplyMaterial(sceneDelegate, id, data.displayColor, data.opacity,
                       data.roughness, data.metallic, opacityThreshold, textures, materialId);

  // bake/lookup this material's shared texture atlas cell.
  if (atlas) {
    const std::string cellKey = materialId.IsEmpty() ? id.GetString() : materialId.GetString();
    HdAkariAtlasCell cell = atlas->GetOrBakeCell(cellKey,
                                                 textures.roughnessPath, data.roughness,
                                                 textures.metallicPath, data.metallic,
                                                 textures.opacityPath, data.opacity,
                                                 opacityThreshold,
                                                 textures.colorPath, data.displayColor,
                                                 textures.normalPath,
                                                 textures.emissivePath, textures.emissiveColor);
    HdAkariComputeAtlasUvs(sceneDelegate, id, meshUtil, textures, cell,
                           data.triangleIndices, data.uvs);
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
