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
#ifndef HDAKARI_MESH_H
#define HDAKARI_MESH_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Hd/mesh.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/mesh.h>
#endif

#include "HdAkari/api.h"

#include <memory>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

class HdAkariScene;
class HdAkariSubdivision;

/// a mesh prim akari draws, triangulated once and published into the delegate's scene for the gpu
class HdAkariMesh final : public HdMesh
{
public:
  HDAKARI_API explicit HdAkariMesh(SdfPath const &id);
  ~HdAkariMesh() override = default;

  HDAKARI_API HdDirtyBits GetInitialDirtyBitsMask() const override;

  HDAKARI_API void Sync(HdSceneDelegate *sceneDelegate,
                        HdRenderParam *renderParam,
                        HdDirtyBits *dirtyBits,
                        TfToken const &reprToken) override;

  HDAKARI_API void Finalize(HdRenderParam *renderParam) override;

protected:
  HDAKARI_API void _InitRepr(TfToken const &reprToken,
                             HdDirtyBits *dirtyBits) override;
  HDAKARI_API HdDirtyBits _PropagateDirtyBits(HdDirtyBits bits) const override;

  HdAkariMesh(const HdAkariMesh &) = delete;
  HdAkariMesh &operator=(const HdAkariMesh &) = delete;

private:
  uint64_t _dataGeneration = 0; // bumped each sync so gpu caches invalidate

  // what the last full sync triangulated
  HdTopology::ID _topologyHash = 0;
  VtVec2fArray _topologyUvs;
  uint64_t _topologyRevision = 0;

  // the skel computation skinned on the gpu and its per joint rest bounds, 6 floats each
  SdfPath _skinComputation;
  std::vector<float> _skinJointBounds;
  uint64_t _skinRevision = 0;

  // the rest points and weights that revision was given for
  VtVec3fArray _skinRestPoints;
  VtVec2fArray _skinInfluences;

  // the subdivision from the last full sync, kept so moving points can refine without rebuilding it
  std::shared_ptr<HdAkariSubdivision> _subdivision;

  // the cage topology hash, which a points only sync compares against
  HdTopology::ID _baseTopologyHash = 0;

  // how many refined faces this mesh holds of the scene wide budget
  int64_t _refinedFaces = 0;

  // whether the scene's copy of this mesh already holds its gpu refinement stencils
  bool _sentStencils = false;

  // whether the last full sync shaded with the mesh's own normals
  bool _authoredNormals = false;

  // the material the last full sync baked the atlas uvs for
  SdfPath _materialId;

  void _ReleaseSubdivision();
  bool _SyncMovingCage(HdAkariScene *scene, HdSceneDelegate *sceneDelegate, VtValue const &cagePoints);
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_MESH_H
