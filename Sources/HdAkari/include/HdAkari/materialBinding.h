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
#ifndef HDAKARI_MATERIAL_BINDING_H
#define HDAKARI_MATERIAL_BINDING_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Gf/vec3f.h>
# include <Sdf/path.h>
# include <Tf/token.h>
# include <Vt/types.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/usd/sdf/path.h>
# include <pxr/base/tf/token.h>
# include <pxr/base/vt/types.h>
#endif

#include "HdAkari/api.h"
#include "HdAkari/textureAtlas.h"

#include <string>

PXR_NAMESPACE_OPEN_SCOPE

class HdSceneDelegate;
class HdMeshUtil;
struct HdAkariMeshData;

/// Resolved per-material texture info for
/// the channels Akari samples.
struct HdAkariMaterialTextures
{
  std::string roughnessPath;
  std::string metallicPath;
  std::string opacityPath;
  std::string colorPath;
  std::string normalPath;
  std::string emissivePath;
  GfVec3f emissiveColor = GfVec3f(0.0f); // used when emissive isn't textured.
  TfToken uvVarname = TfToken("st");
  bool hasAny = false;
};

/// Reads UsdPreviewSurface's diffuseColor/opacity/roughness/metallic
/// from the prim's bound material.
void HdAkariApplyMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                          GfVec3f &color, float &opacity,
                          float &roughness, float &metallic,
                          float &opacityThreshold,
                          HdAkariMaterialTextures &textures,
                          SdfPath &materialIdOut);

/// Fetches the prim's raw UV primvar, remapped into its atlas cell.
void HdAkariComputeAtlasUvs(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                            HdAkariMaterialTextures const &textures, HdAkariAtlasCell const &cell,
                            VtVec3iArray const &triangleIndices, VtVec2fArray &outUvs);

/// Resolves the prim's bound material into `data`, bakes its atlas
/// cell, and fills one atlas UV per triangle corner.
void HdAkariSyncMaterial(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                         HdAkariTextureAtlas *atlas, HdMeshUtil &meshUtil,
                         HdAkariMeshData &data);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_MATERIAL_BINDING_H
