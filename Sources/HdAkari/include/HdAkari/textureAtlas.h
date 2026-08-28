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

#include <pxr/pxrns.h>
#include <Arch/swiftInterop.h>
#include <Gf/vec3f.h>
#include <Tf/sharedPtrRetainReleaseHelper.h>

#include <atomic>
#include <cstdint>
#include <future>
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
  float averageOpacity = 1.0f;                        // CPU-side opaque/transparent split.
  float opacityThreshold = 0.0f;                      // >0 means alpha-test/cutout, not blend.
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
  static constexpr int kCellPixels = 256;     // resolution per cell.
  static constexpr int kDefaultGridSize = 24; // fallback if never sized.

  /// Sizes the grid to fit the scene's actual unique material count.
  void EnsureGridSized(HdSceneDelegate *sceneDelegate);

  /// Finds (or bakes, on first use) the atlas cell for one material.
  HdAkariAtlasCell GetOrBakeCell(std::string const &materialKey,
                                 std::string const &roughnessPath, float roughnessConst,
                                 std::string const &metallicPath, float metallicConst,
                                 std::string const &opacityPath, float opacityConst,
                                 float opacityThreshold,
                                 std::string const &colorPath, GfVec3f const &colorConst);

  /// True once new cells have been baked since the last call.
  bool ConsumeDirty() { return _dirty.exchange(false, std::memory_order_acq_rel); }

  /// Raw pointer to the RGBA8 (GL_UNSIGNED_BYTE) pixel buffer.
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *PixelData() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _pixels.empty() ? nullptr : _pixels.data();
  }
  int Width() const { return _gridSize * kCellPixels; }
  int Height() const { return _gridSize * kCellPixels; }

  /// Raw pointer to the diffuseColor RGBA8 pixel buffer.
  uint8_t const SWIFT_RETURNS_INDEPENDENT_VALUE *ColorPixelData() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _colorPixels.empty() ? nullptr : _colorPixels.data();
  }

private:
  void BakeChannel(int cellX, int cellY, int channelIndex,
                    std::string const &texPath, float fallbackConst,
                    int tileMinU, int tileMinV, int tileMaxU, int tileMaxV,
                    float *outAverage);
  void BakeColorChannel(int cellX, int cellY,
                         std::string const &texPath, GfVec3f const &fallbackConst,
                         int tileMinU, int tileMinV, int tileMaxU, int tileMaxV);

  mutable std::mutex _mutex;
  std::unordered_map<std::string, HdAkariAtlasCell> _cells;
  // Materials currently being baked by some other thread.
  std::unordered_map<std::string, std::shared_future<HdAkariAtlasCell>> _pending;
  int _nextCell = 0;
  std::vector<uint8_t> _pixels;      // lazily sized to Width()*Height()*4 on first bake.
  std::vector<uint8_t> _colorPixels; // same thing, for diffuseColor.
  std::atomic<bool> _dirty{false};
  std::once_flag _sizeOnce;
  std::atomic<int> _gridSize{kDefaultGridSize};
};

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
