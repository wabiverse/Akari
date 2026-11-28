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
#ifndef HDAKARI_TEXTURE_ATLAS_H
#define HDAKARI_TEXTURE_ATLAS_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Arch/swiftInterop.h>
# include <Gf/vec3f.h>
# include <Tf/sharedPtrRetainReleaseHelper.h>
#else
# include <pxr/pxr.h>
# include <HdAkari/swiftInterop.h>
# include <pxr/base/gf/vec3f.h>
# include <HdAkari/sharedPtrRetainReleaseHelper.h>
#endif

#include "HdAkari/api.h"

#include <algorithm>
#include <climits>
#include <atomic>
#include <cstdint>
#include <future>
#include <condition_variable>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

class HdSceneDelegate;

/// one material's region in the shared material atlas
struct HdAkariAtlasCell
{
  float u0 = 0.0f, v0 = 0.0f, u1 = 1.0f, v1 = 1.0f;   // atlas-space rect, [0,1].
  float tileU0 = 0.0f, tileV0 = 0.0f;                 // lowest UDIM tile's (u,v) origin.
  float tileUSpan = 1.0f, tileVSpan = 1.0f;           // tile-grid width/height covered.
  float opacityThreshold = 0.0f;                      // >0 means alpha-test/cutout, not blend.
  int constantIndex = -1;                             // untextured: its constants row, the rect unused.
};

/// the constants rows changed since the last drain, `count` from `first`.
struct HdAkariConstantRange
{
  int first = 0, count = 0;
};

/// a rect of the atlas baked since the last upload, in texels.
struct HdAkariAtlasRegion
{
  int x = 0, y = 0, width = 0, height = 0;
};

/// which component of each scalar texture feeds it, a UsdUVTexture's r, g, b or a output.
struct HdAkariScalarSources
{
  int roughness = 0, metallic = 0, opacity = 0;
};

/// bakes preview surface maps into shared rgba8 atlases, each material packed at its own texture size
class SWIFT_SHARED_REFERENCE(HdAkariTextureAtlasRetain, HdAkariTextureAtlasRelease)
HdAkariTextureAtlas
{
public:
  // the largest atlas side, which every metal device supports.
  static constexpr int kMaxTexturePixels = 16384;

  // the border inside each region so mips only sample their own region
  static constexpr int kCellPadding = 16;
  static constexpr int kMaxMipLevel = 3;

  // regions start and size on this, so every mip level stays on whole BC7 blocks.
  static constexpr int kRegionAlign = 4 << kMaxMipLevel;

  /// whether a prim has given this material a constants row yet.
  bool HasConstants(std::string const &materialKey)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _constantIndex.count(materialKey) != 0;
  }

  /// packs every material the scene has at its texture's own size, before the first bake.
  void EnsureGridSized(HdSceneDelegate *sceneDelegate);

  /// finds or bakes on first use one material's atlas cell
  HdAkariAtlasCell GetOrBakeCell(std::string const &materialKey,
                                 std::string const &roughnessPath, float roughnessConst,
                                 std::string const &metallicPath, float metallicConst,
                                 std::string const &opacityPath, float opacityConst,
                                 float opacityThreshold,
                                 std::string const &colorPath, GfVec3f const &colorConst,
                                 std::string const &normalPath,
                                 std::string const &emissivePath, GfVec3f const &emissiveConst,
                                 HdAkariScalarSources const &sources = HdAkariScalarSources(),
                                 GfVec3f const &specularConst = GfVec3f(0.04f));

  /// rewrites an untextured material's constants row when its emission or opacity animates, false when there's nothing to do
  bool UpdateConstants(std::string const &materialKey, GfVec3f const *emissive, float const *opacity);

  /// rewrites an untextured material's row in place, false when it has none.
  bool UpdateConstantMaterial(std::string const &materialKey, GfVec3f const &color, float opacity, float roughness,
                              float metallic, float opacityThreshold, GfVec3f const &emissive,
                              GfVec3f const &specular = GfVec3f(0.04f));

  /// an untextured material's row, false when it has none.
  bool GetConstants(std::string const &materialKey, float *out);

  /// drops a material's cell, so its next use bakes it again.
  void ForgetCell(std::string const &materialKey);

  /// marks an untextured material's row with the ptex map its color streams from, one past its id.
  void SetConstantsPtexMap(std::string const &materialKey, int map);

  /// untextured materials read constants from a small float table by index instead of the atlas
  static constexpr int kConstantTexels = 4;

  int ConstantCount() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return int(_constants.size() / (kConstantTexels * 4));
  }

  /// copies `count` rows from `first` into `dst`
  void CopyConstants(int first, int count, float *dst) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    const size_t row = kConstantTexels * 4;
    std::copy(_constants.begin() + first * row, _constants.begin() + (first + count) * row, dst);
  }

  /// the rows written since the last call, empty when none were.
  HdAkariConstantRange DrainDirtyConstants()
  {
    std::lock_guard<std::mutex> lock(_mutex);
    HdAkariConstantRange out;
    if (_constantsDirtyHi > _constantsDirtyLo) out = {_constantsDirtyLo, _constantsDirtyHi - _constantsDirtyLo};
    _constantsDirtyLo = INT_MAX;
    _constantsDirtyHi = INT_MIN;
    return out;
  }

  /// true once new cells have been baked since the last call.
  bool ConsumeDirty() { return _dirty.exchange(false, std::memory_order_acq_rel); }

  /// hands the regions baked since the last call to the uploader, so the atlas never holds a full size copy
  int TakeBakedRegions();

  HdAkariAtlasRegion BakedRegion(int i) const;

  /// one taken region's texels for the material, color, normal or emissive atlas
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *BakedPixels(int i, int atlas) const;

  /// frees the regions the uploader took once they're on the gpu.
  void ReleaseUploaded();

  int Width() const { return _width.load(std::memory_order_relaxed); }
  int Height() const { return _height.load(std::memory_order_relaxed); }

private:
  /// what a cell bakes from.
  struct BakeInputs
  {
    std::string roughnessPath, metallicPath, opacityPath, colorPath, normalPath, emissivePath;
    float roughnessConst = 0.0f, metallicConst = 0.0f, opacityConst = 1.0f, opacityThreshold = 0.0f;
    GfVec3f specularConst{0.04f};
    GfVec3f colorConst{0.0f}, emissiveConst{0.0f};
    int px0 = 0, py0 = 0, regionW = 0, regionH = 0, contentPx0 = 0, contentPy0 = 0, contentW = 0, contentH = 0;
    int tileMinU = INT_MAX, tileMinV = INT_MAX, tileMaxU = INT_MIN, tileMaxV = INT_MIN;
    HdAkariScalarSources sources;
  };

  /// bakes a region into its own buffers and queues them for upload.
  void BakeRegion(BakeInputs const &in);
  /// writes one untextured material's row, the lock held.
  void WriteConstants(int index, GfVec3f const &color, float opacity, float roughness, float metallic,
                      float opacityThreshold, GfVec3f const &emissive, GfVec3f const &specular);
  void BakeChannel(uint8_t *target, int stride, int px0, int py0, int regionW, int regionH, int channelIndex,
                    std::string const &texPath, float fallbackConst,
                    int tileMinU, int tileMinV, int tileMaxU, int tileMaxV, int sourceChannel = 0);
  void BakeColorChannel(uint8_t *target, int stride, bool decodeSRGB,
                         int px0, int py0, int regionW, int regionH,
                         std::string const &texPath, GfVec3f const &fallbackConst,
                         int tileMinU, int tileMinV, int tileMaxU, int tileMaxV);

  mutable std::mutex _mutex;
  std::unordered_map<std::string, HdAkariAtlasCell> _cells;

  // materials currently being baked by some other thread.
  std::unordered_map<std::string, std::shared_future<HdAkariAtlasCell>> _pending;

  // each planned material's region, and the shelf later materials pack onto below them.
  std::unordered_map<std::string, HdAkariAtlasRegion> _plan;
  int _planCap = kMaxTexturePixels;
  int _shelfX = 0, _shelfY = 0, _shelfRowH = 0;
  bool _warnedFull = false;
  /// a baked region's texels for each of the four atlases, held only until uploaded.
  struct Baked
  {
    HdAkariAtlasRegion rect;
    std::vector<uint8_t> pixels[4];
  };

  std::vector<Baked> _baked;     // waiting for the uploader.
  std::vector<Baked> _uploading; // taken by the uploader.
  std::unordered_map<std::string, int> _constantIndex;
  std::vector<float> _constants;
  int _constantsDirtyLo = INT_MAX, _constantsDirtyHi = INT_MIN;
  std::atomic<bool> _dirty{false};
  std::once_flag _sizeOnce;
  SdfPathVector _sizeMaterials;
  std::atomic<size_t> _sizeNext{0};
  std::atomic<size_t> _sizeTextured{0};

  // each textured material's key and native texture size, gathered for the plan.
  std::vector<std::pair<std::string, HdAkariAtlasRegion>> _sizeItems;
  size_t _sizeFinished = 0;
  std::atomic<bool> _sized{false};
  std::mutex _sizeMutex;
  std::condition_variable _sizeDone;
  std::atomic<int> _width{256};
  std::atomic<int> _height{256};
};

/// the rgba texels in each row of the atlas's constants table.
inline int HdAkariConstantTexels() { return HdAkariTextureAtlas::kConstantTexels; }

/// the largest atlas side this device's memory allows, at most `kMaxTexturePixels`, set once before anything renders
HDAKARI_API void HdAkariSetAtlasSideLimit(int side);

PXR_NAMESPACE_CLOSE_SCOPE

inline void HdAkariTextureAtlasRetain(PXR_INTERNAL_NS::HdAkariTextureAtlas *atlas)
{
  PXR_INTERNAL_NS::Tf_SharedPtrRetainReleaseHelper<PXR_INTERNAL_NS::HdAkariTextureAtlas>::Retain(atlas);
}

inline void HdAkariTextureAtlasRelease(PXR_INTERNAL_NS::HdAkariTextureAtlas *atlas)
{
  PXR_INTERNAL_NS::Tf_SharedPtrRetainReleaseHelper<PXR_INTERNAL_NS::HdAkariTextureAtlas>::Release(atlas);
}

#endif // HDAKARI_TEXTURE_ATLAS_H
