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
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/tf/sharedPtrRetainReleaseHelper.h>
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

/// One material's assigned region within
/// the shared material atlas texture.
struct HdAkariAtlasCell
{
  float u0 = 0.0f, v0 = 0.0f, u1 = 1.0f, v1 = 1.0f;   // atlas-space rect, [0,1].
  float tileU0 = 0.0f, tileV0 = 0.0f;                 // lowest UDIM tile's (u,v) origin.
  float tileUSpan = 1.0f, tileVSpan = 1.0f;           // tile-grid width/height covered.
  float opacityThreshold = 0.0f;                      // >0 means alpha-test/cutout, not blend.
  int constantIndex = -1;                             // untextured: its constants row, the rect unused.
};

/// The constants rows changed since the last drain, `count` from `first`.
struct HdAkariConstantRange
{
  int first = 0, count = 0;
};

/// A square pixel region of the atlas
/// baked since the last drain.
struct HdAkariAtlasRect
{
  int x = 0, y = 0, size = 0;
};

/// Which component of each scalar texture feeds it, a UsdUVTexture's r, g, b or a output.
struct HdAkariScalarSources
{
  int roughness = 0, metallic = 0, opacity = 0;
};

/// @class HdAkariTextureAtlas
///
/// Bakes UsdPreviewSurface roughness/metallic/opacity maps, including
/// multi-tile UDIM sets, into one shared RGBA8 CPU pixel buffer (R =
/// roughness, G = metallic, B = opacity), laid out as a fixed grid of
/// square cells in discovery order.
class SWIFT_SHARED_REFERENCE(HdAkariTextureAtlasRetain, HdAkariTextureAtlasRelease)
HdAkariTextureAtlas
{
public:
  static constexpr int kCellPixels = 256;      // minimum resolution per cell.
  static constexpr int kMaxCellPixels = 2048;  // cells grow up to this when few materials.
  static constexpr int kMaxAtlasPixels = 4096; // largest atlas grown cells may fill.
  static constexpr int kDefaultGridSize = 4;   // fallback if never sized.
  // the atlas is a fixed 16384x16384 square (supported by all Metal devices),
  // if we run out of slots, extra materials will share cells via round-robin.
  static constexpr int kMaxTexturePixels = 16384;
  static constexpr int kMaxGridSize = kMaxTexturePixels / kCellPixels;

  // Border reserved inside each cell so mip
  // levels only sample individual cells.
  static constexpr int kCellPadding = 16;
  static constexpr int kMaxMipLevel = 3;

  /// Whether a prim has given this material a constants row yet.
  bool HasConstants(std::string const &materialKey)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _constantIndex.count(materialKey) != 0;
  }

  /// Sizes the grid to fit the scene's actual unique material count.
  void EnsureGridSized(HdSceneDelegate *sceneDelegate);

  /// Finds (or bakes, on first use) the atlas cell for one material.
  HdAkariAtlasCell GetOrBakeCell(std::string const &materialKey,
                                 std::string const &roughnessPath, float roughnessConst,
                                 std::string const &metallicPath, float metallicConst,
                                 std::string const &opacityPath, float opacityConst,
                                 float opacityThreshold,
                                 std::string const &colorPath, GfVec3f const &colorConst,
                                 std::string const &normalPath,
                                 std::string const &emissivePath, GfVec3f const &emissiveConst,
                                 HdAkariScalarSources const &sources = HdAkariScalarSources());

  /// Rewrites an untextured material's constants row when its emission or opacity changed,
  /// for either animated over time. Null leaves that one as is. False when there's nothing to do.
  bool UpdateConstants(std::string const &materialKey, GfVec3f const *emissive, float const *opacity);

  /// Marks an untextured material's row with the Ptex map its color streams from, one past its id.
  void SetConstantsPtexMap(std::string const &materialKey, int map);

  /// Untextured materials skip the atlas, the shaders read their constants from a small
  /// float table by index instead, kConstantTexels RGBA texels a row: color and opacity,
  /// roughness, metallic and opacity threshold, emission. Animating one rewrites its row.
  static constexpr int kConstantTexels = 3;

  int ConstantCount() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return int(_constants.size() / (kConstantTexels * 4));
  }

  /// Copies `count` rows from `first` into `dst`, kConstantTexels * 4 floats a row.
  void CopyConstants(int first, int count, float *dst) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    const size_t row = kConstantTexels * 4;
    std::copy(_constants.begin() + first * row, _constants.begin() + (first + count) * row, dst);
  }

  /// The rows written since the last call, empty when none were.
  HdAkariConstantRange DrainDirtyConstants()
  {
    std::lock_guard<std::mutex> lock(_mutex);
    HdAkariConstantRange out;
    if (_constantsDirtyHi > _constantsDirtyLo) out = {_constantsDirtyLo, _constantsDirtyHi - _constantsDirtyLo};
    _constantsDirtyLo = INT_MAX;
    _constantsDirtyHi = INT_MIN;
    return out;
  }

  /// True once new cells have been baked since the last call.
  bool ConsumeDirty() { return _dirty.exchange(false, std::memory_order_acq_rel); }

  /// The regions baked since the last
  /// call, for uploading just those.
  std::vector<HdAkariAtlasRect> DrainDirtyRects()
  {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<HdAkariAtlasRect> out;
    out.swap(_dirtyRects);
    return out;
  }

  /// Frees the CPU pixels once they're uploaded and nothing is mid bake,
  /// a later bake starts from zeroed buffers and only its rect uploads.
  void ReleasePixelsIfIdle()
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_pending.empty() || !_dirtyRects.empty()) return;
    std::vector<uint8_t>().swap(_pixels);
    std::vector<uint8_t>().swap(_colorPixels);
    std::vector<uint8_t>().swap(_normalPixels);
    std::vector<uint8_t>().swap(_emissivePixels);
  }

  /// Raw pointer to the RGBA8 (GL_UNSIGNED_BYTE) pixel buffer.
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *PixelData() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _pixels.empty() ? nullptr : _pixels.data();
  }
  int Width() const { return _gridSize * _cellPixels; }
  int Height() const { return _gridSize * _cellPixels; }

  /// Raw pointer to the diffuseColor RGBA8 pixel buffer.
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *ColorPixelData() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _colorPixels.empty() ? nullptr : _colorPixels.data();
  }

  /// Raw pointer to the tangent space normal RGBA8 pixel buffer.
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *NormalPixelData() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _normalPixels.empty() ? nullptr : _normalPixels.data();
  }

  /// Raw pointer to the emissiveColor RGBA8 pixel buffer.
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *EmissivePixelData() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _emissivePixels.empty() ? nullptr : _emissivePixels.data();
  }

private:
  /// What a cell bakes from.
  struct BakeInputs
  {
    std::string roughnessPath, metallicPath, opacityPath, colorPath, normalPath, emissivePath;
    float roughnessConst = 0.0f, metallicConst = 0.0f, opacityConst = 1.0f, opacityThreshold = 0.0f;
    GfVec3f colorConst{0.0f}, emissiveConst{0.0f};
    int px0 = 0, py0 = 0, regionSize = 0, contentPx0 = 0, contentPy0 = 0, contentSize = 0;
    int tileMinU = INT_MAX, tileMinV = INT_MAX, tileMaxU = INT_MIN, tileMaxV = INT_MIN;
    HdAkariScalarSources sources;
  };

  void BakeRegion(BakeInputs const &in);
  /// Writes one untextured material's row, the lock held.
  void WriteConstants(int index, GfVec3f const &color, float opacity, float roughness, float metallic,
                      float opacityThreshold, GfVec3f const &emissive);
  void BakeChannel(int px0, int py0, int regionSize, int channelIndex,
                    std::string const &texPath, float fallbackConst,
                    int tileMinU, int tileMinV, int tileMaxU, int tileMaxV, int sourceChannel = 0);
  void BakeColorChannel(std::vector<uint8_t> &target, bool decodeSRGB,
                         int px0, int py0, int regionSize,
                         std::string const &texPath, GfVec3f const &fallbackConst,
                         int tileMinU, int tileMinV, int tileMaxU, int tileMaxV);

  mutable std::mutex _mutex;
  std::unordered_map<std::string, HdAkariAtlasCell> _cells;
  // Materials currently being baked by some other thread.
  std::unordered_map<std::string, std::shared_future<HdAkariAtlasCell>> _pending;
  int _nextCell = 0;
  bool _warnedOverflow = false;      // guards a one-time stderr warning if cells wrap.
  std::vector<uint8_t> _pixels;      // lazily sized to Width()*Height()*4 on first bake.
  std::vector<uint8_t> _colorPixels; // same thing, for diffuseColor.
  std::vector<uint8_t> _normalPixels;   // tangent space normal, flat where untextured.
  std::vector<uint8_t> _emissivePixels; // emissiveColor.
  std::vector<HdAkariAtlasRect> _dirtyRects;
  std::unordered_map<std::string, int> _constantIndex;
  std::vector<float> _constants;
  int _constantsDirtyLo = INT_MAX, _constantsDirtyHi = INT_MIN;
  std::atomic<bool> _dirty{false};
  std::once_flag _sizeOnce;
  SdfPathVector _sizeMaterials;
  std::atomic<size_t> _sizeNext{0};
  std::atomic<size_t> _sizeTextured{0};
  size_t _sizeFinished = 0;
  std::atomic<bool> _sized{false};
  std::mutex _sizeMutex;
  std::condition_variable _sizeDone;
  std::atomic<int> _gridSize{kDefaultGridSize};
  std::atomic<int> _cellPixels{kCellPixels};
};

/// The RGBA texels in each row of the atlas's constants table.
inline int HdAkariConstantTexels() { return HdAkariTextureAtlas::kConstantTexels; }

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
