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
#include "HdAkari/textureAtlas.h"

#include "HdAkari/akariImaging.h" // swift -> c++ interop, see Sources/AkariImaging.

#include <Hd/renderIndex.h>
#include <Hd/sceneDelegate.h>
#include <Hio/image.h>
#include <Hio/types.h>
#include <Work/loops.h>

#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// Finds every UDIM tile that exists on disk for a templated path.
std::vector<std::pair<int, int>> DiscoverUdimTiles(std::string const &templatePath)
{
  std::vector<std::pair<int, int>> tiles;
  if (templatePath.empty()) return tiles;

  auto pos = templatePath.find("<UDIM>");
  if (pos == std::string::npos) {
    std::error_code ec;
    if (std::filesystem::exists(templatePath, ec)) tiles.push_back({0, 0});
    return tiles;
  }

  std::filesystem::path full(templatePath);
  std::string dir = full.parent_path().string();
  std::string prefix = std::filesystem::path(templatePath.substr(0, pos)).filename().string();
  std::string suffix = templatePath.substr(pos + 6);

  std::error_code ec;
  for (auto const &entry : std::filesystem::directory_iterator(dir, ec)) {
    if (ec) break;
    std::string name = entry.path().filename().string();
    if (name.size() < prefix.size() + suffix.size() + 4) continue;
    if (name.compare(0, prefix.size(), prefix) != 0) continue;
    if (name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) continue;
    std::string tileStr = name.substr(prefix.size(), 4);
    if (tileStr.size() != 4 || !std::all_of(tileStr.begin(), tileStr.end(), ::isdigit)) continue;
    int tileNum = std::stoi(tileStr);
    if (tileNum < 1001) continue;
    tiles.push_back({(tileNum - 1001) % 10, (tileNum - 1001) / 10});
  }
  return tiles;
}

/// Converts one texel of raw bytes into `nComp` floats.
void ConvertTexelToFloat(uint8_t const *raw, HioType type, int nComp, float *out)
{
  switch (type) {
    case HioTypeUnsignedByte:
    case HioTypeUnsignedByteSRGB:
      for (int c = 0; c < nComp; ++c) out[c] = float(raw[c]) / 255.0f;
      return;
    case HioTypeSignedByte:
      for (int c = 0; c < nComp; ++c)
        out[c] = std::max(float(reinterpret_cast<int8_t const *>(raw)[c]) / 127.0f, -1.0f);
      return;
    case HioTypeUnsignedShort: {
      auto const *p = reinterpret_cast<uint16_t const *>(raw);
      for (int c = 0; c < nComp; ++c) out[c] = float(p[c]) / 65535.0f;
      return;
    }
    case HioTypeSignedShort: {
      auto const *p = reinterpret_cast<int16_t const *>(raw);
      for (int c = 0; c < nComp; ++c) out[c] = std::max(float(p[c]) / 32767.0f, -1.0f);
      return;
    }
    case HioTypeUnsignedInt: {
      auto const *p = reinterpret_cast<uint32_t const *>(raw);
      for (int c = 0; c < nComp; ++c) out[c] = float(double(p[c]) / 4294967295.0);
      return;
    }
    case HioTypeInt: {
      auto const *p = reinterpret_cast<int32_t const *>(raw);
      for (int c = 0; c < nComp; ++c) out[c] = float(p[c]);
      return;
    }
    case HioTypeHalfFloat: {
      auto const *p = reinterpret_cast<uint16_t const *>(raw);
      for (int c = 0; c < nComp; ++c) {
        uint16_t h = p[c];
        uint32_t sign = uint32_t(h & 0x8000) << 16;
        uint32_t exp = (h >> 10) & 0x1F;
        uint32_t mant = h & 0x3FF;
        uint32_t bits;
        if (exp == 0) {
          if (mant == 0) {
            bits = sign;
          } else {
            // subnormal half -> normalized float.
            int shift = 0;
            while ((mant & 0x400) == 0) { mant <<= 1; ++shift; }
            mant &= 0x3FF;
            uint32_t fexp = uint32_t(127 - 15 - shift + 1);
            bits = sign | (fexp << 23) | (mant << 13);
          }
        } else if (exp == 0x1F) {
          bits = sign | 0x7F800000u | (mant << 13); // inf/nan.
        } else {
          bits = sign | ((exp - 15 + 127) << 23) | (mant << 13);
        }
        float f;
        std::memcpy(&f, &bits, sizeof(f));
        out[c] = f;
      }
      return;
    }
    case HioTypeFloat:
      std::memcpy(out, raw, sizeof(float) * size_t(nComp));
      return;
    case HioTypeDouble: {
      auto const *p = reinterpret_cast<double const *>(raw);
      for (int c = 0; c < nComp; ++c) out[c] = float(p[c]);
      return;
    }
    default:
      for (int c = 0; c < nComp; ++c) out[c] = 0.0f;
      return;
  }
}

/// Decodes one UDIM tile file into a flat float buffer,
/// `outComp` components per texel.
bool DecodeTile(std::string const &tilePath, std::vector<float> &outPixels,
                int &outW, int &outH, int &outComp)
{
  std::error_code ec;
  if (!std::filesystem::exists(tilePath, ec)) {
    return false;
  }

  HioImageSharedPtr image = HioImage::OpenForReading(tilePath);
  if (!image) {
    return false;
  }

  int srcW = image->GetWidth();
  int srcH = image->GetHeight();
  if (srcW <= 0 || srcH <= 0) {
    return false;
  }

  HioFormat srcFormat = image->GetFormat();
  int nComp = HioGetComponentCount(srcFormat);
  if (nComp <= 0) {
    return false;
  }
  HioType srcType = HioGetHioType(srcFormat);
  size_t compBytes = HioGetDataSizeOfType(srcType);
  if (compBytes == 0) {
    return false;
  }

  std::vector<uint8_t> rawPixels(size_t(srcW) * size_t(srcH) * size_t(nComp) * compBytes);
  HioImage::StorageSpec spec;
  spec.width = srcW;
  spec.height = srcH;
  spec.depth = 1;
  spec.format = srcFormat;
  spec.flipped = true;
  spec.data = rawPixels.data();
  if (!image->Read(spec)) {
    return false;
  }

  outPixels.resize(size_t(srcW) * size_t(srcH) * size_t(nComp));
  size_t texelBytes = size_t(nComp) * compBytes;
  size_t texelCount = size_t(srcW) * size_t(srcH);
  for (size_t t = 0; t < texelCount; ++t) {
    ConvertTexelToFloat(rawPixels.data() + t * texelBytes, srcType, nComp, outPixels.data() + t * size_t(nComp));
  }
  outW = srcW; outH = srcH; outComp = nComp;
  return true;
}

} // namespace

void
HdAkariTextureAtlas::EnsureGridSized(HdSceneDelegate *sceneDelegate)
{
  std::call_once(_sizeOnce, [this, sceneDelegate]() {
    HdRenderIndex &index = sceneDelegate->GetRenderIndex();
    SdfPathVector const &rprimIds = index.GetRprimIds();

    std::mutex mergeMutex;
    std::unordered_set<SdfPath, SdfPath::Hash> uniqueMaterials;
    size_t constOnlyCount = 0;
    WorkParallelForN(rprimIds.size(), [&](size_t begin, size_t end) {
      std::unordered_set<SdfPath, SdfPath::Hash> local;
      size_t localConst = 0;
      for (size_t i = begin; i < end; ++i) {
        // a material-less mesh gets a mini-slot (GetOrBakeCell's isConstOnly
        // path), not its own full cell, count it separately.
        SdfPath matId = sceneDelegate->GetMaterialId(rprimIds[i]);
        if (matId.IsEmpty()) ++localConst;
        else local.insert(matId);
      }
      std::lock_guard<std::mutex> lock(mergeMutex);
      if (!local.empty()) uniqueMaterials.insert(local.begin(), local.end());
      constOnlyCount += localConst;
    }, /*grainSize=*/64);

    size_t bigCellsForConst =
        (constOnlyCount + kConstSlotsPerBigCell - 1) / kConstSlotsPerBigCell;
    size_t totalBigCells = uniqueMaterials.size() + bigCellsForConst;
    size_t withHeadroom = totalBigCells + totalBigCells / 4 + 1;
    int grid = 1;
    while (size_t(grid) * size_t(grid) < withHeadroom) ++grid;
    grid = std::max(grid, kDefaultGridSize);
    _gridSize.store(grid, std::memory_order_relaxed);
  });
}

HdAkariAtlasCell
HdAkariTextureAtlas::GetOrBakeCell(std::string const &materialKey,
                                   std::string const &roughnessPath, float roughnessConst,
                                   std::string const &metallicPath, float metallicConst,
                                   std::string const &opacityPath, float opacityConst,
                                   float opacityThreshold,
                                   std::string const &colorPath, GfVec3f const &colorConst)
{
  HdAkariAtlasCell cell;
  int tileMinU = INT_MAX, tileMinV = INT_MAX, tileMaxU = INT_MIN, tileMaxV = INT_MIN;
  std::promise<HdAkariAtlasCell> promise;
  int gridSize = _gridSize.load(std::memory_order_relaxed);
  int width = gridSize * kCellPixels;

  // no texture bound anywhere -> this bakes to a flat fill sampled at a
  // single point (mesh.cpp's ComputeAtlasUvs), so it only needs a tiny
  // slot, densely packed into a shared reserved cell.
  bool isConstOnly = roughnessPath.empty() && metallicPath.empty() &&
                     opacityPath.empty() && colorPath.empty();
  int px0 = 0, py0 = 0, regionSize = kCellPixels;
  // baked content is inset from the cell's actual grid placement,
  // leaving a border for `AkariImaging::Atlas::fillCellBorder` to
  // replicate into.
  int contentPx0 = 0, contentPy0 = 0, contentSize = kCellPixels;

  {
    std::unique_lock<std::mutex> lock(_mutex);

    auto it = _cells.find(materialKey);
    if (it != _cells.end()) return it->second;

    auto pendingIt = _pending.find(materialKey);
    if (pendingIt != _pending.end()) {
      std::shared_future<HdAkariAtlasCell> future = pendingIt->second;
      lock.unlock(); // release before the blocking wait below.
      return future.get();
    }

    if (_pixels.empty()) {
      _pixels.assign(size_t(width) * size_t(width) * 4, uint8_t(0));
    }
    if (_colorPixels.empty()) {
      _colorPixels.assign(size_t(width) * size_t(width) * 4, uint8_t(0));
    }

    if (isConstOnly) {
      if (_nextConstBigCell < 0 || _nextConstSlot >= kConstSlotsPerBigCell) {
        _nextConstBigCell = _nextCell % (gridSize * gridSize);
        ++_nextCell;
        _nextConstSlot = 0;
      }
      int slot = _nextConstSlot++;
      int bigCellX = _nextConstBigCell % gridSize;
      int bigCellY = _nextConstBigCell / gridSize;
      px0 = bigCellX * kCellPixels + (slot % kConstCellsPerAxis) * kConstCellPixels;
      py0 = bigCellY * kCellPixels + (slot / kConstCellsPerAxis) * kConstCellPixels;
      regionSize = kConstCellPixels;
      contentPx0 = px0; contentPy0 = py0; contentSize = regionSize;
    } else {
      // share cells using round-robin.
      int cellIndex = _nextCell % (gridSize * gridSize);
      ++_nextCell;
      px0 = (cellIndex % gridSize) * kCellPixels;
      py0 = (cellIndex / gridSize) * kCellPixels;
      regionSize = kCellPixels;
      contentPx0 = px0 + kCellPadding;
      contentPy0 = py0 + kCellPadding;
      contentSize = regionSize - 2 * kCellPadding;
    }
    if (_nextCell > gridSize * gridSize && !_warnedOverflow) {
      _warnedOverflow = true;
      std::fprintf(stderr,
          "HdAkariTextureAtlas: exceeded its %dx%d grid - cells are now "
          "aliasing, unrelated meshes will share baked textures.\n",
          gridSize, gridSize);
    }

    // lookup the shared UDIM tile.
    auto scanTiles = [&](std::string const &path) {
      for (auto const &t : DiscoverUdimTiles(path)) {
        tileMinU = std::min(tileMinU, t.first);
        tileMaxU = std::max(tileMaxU, t.first);
        tileMinV = std::min(tileMinV, t.second);
        tileMaxV = std::max(tileMaxV, t.second);
      }
    };
    scanTiles(roughnessPath);
    scanTiles(metallicPath);
    scanTiles(opacityPath);
    scanTiles(colorPath);

    cell.u0 = float(contentPx0) / float(width);
    cell.v0 = float(contentPy0) / float(width);
    cell.u1 = cell.u0 + float(contentSize) / float(width);
    cell.v1 = cell.v0 + float(contentSize) / float(width);

    if (tileMinU == INT_MAX) {
      cell.tileU0 = 0.0f; cell.tileV0 = 0.0f;
      cell.tileUSpan = 1.0f; cell.tileVSpan = 1.0f;
    } else {
      cell.tileU0 = float(tileMinU);
      cell.tileV0 = float(tileMinV);
      cell.tileUSpan = float(tileMaxU - tileMinU + 1);
      cell.tileVSpan = float(tileMaxV - tileMinV + 1);
    }

    _pending.emplace(materialKey, promise.get_future().share());
  }

  // no locking from here down.
  BakeChannel(contentPx0, contentPy0, contentSize, /*R*/ 0, roughnessPath, roughnessConst,
              tileMinU, tileMinV, tileMaxU, tileMaxV);
  BakeChannel(contentPx0, contentPy0, contentSize, /*G*/ 1, metallicPath, metallicConst,
              tileMinU, tileMinV, tileMaxU, tileMaxV);
  BakeChannel(contentPx0, contentPy0, contentSize, /*B*/ 2, opacityPath, opacityConst,
              tileMinU, tileMinV, tileMaxU, tileMaxV);
  BakeChannel(contentPx0, contentPy0, contentSize, /*A*/ 3, std::string(), opacityThreshold,
              tileMinU, tileMinV, tileMaxU, tileMaxV);
  cell.opacityThreshold = opacityThreshold;

  BakeColorChannel(contentPx0, contentPy0, contentSize, colorPath, colorConst,
                   tileMinU, tileMinV, tileMaxU, tileMaxV);

  if (!isConstOnly) {
    AkariImaging::Atlas::fillCellBorder(_pixels.data(), _colorPixels.data(), width, px0, py0, regionSize, kCellPadding);
  }

  {
    std::lock_guard<std::mutex> lock(_mutex);
    _cells.emplace(materialKey, cell);
    _pending.erase(materialKey);
  }
  _dirty.store(true, std::memory_order_release);
  promise.set_value(cell);
  return cell;
}

void
HdAkariTextureAtlas::BakeChannel(int px0, int py0, int regionSize, int channelIndex,
                                 std::string const &texPath, float fallbackConst,
                                 int tileMinU, int tileMinV, int tileMaxU, int tileMaxV)
{
  int width = _gridSize.load(std::memory_order_relaxed) * kCellPixels;

  AkariImaging::Atlas::fillChannel(_pixels.data(), width, px0, py0, regionSize, channelIndex, fallbackConst);

  if (!texPath.empty() && tileMinU != INT_MAX) {
    int spanU = tileMaxU - tileMinU + 1;
    int spanV = tileMaxV - tileMinV + 1;

    for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
      for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
        std::string tilePath = AkariImaging::Atlas::resolveUdimTile(texPath, tu, tv);
        std::vector<float> srcPixels;
        int srcW = 0, srcH = 0, nComp = 0;
        if (!DecodeTile(tilePath, srcPixels, srcW, srcH, nComp)) continue;

        int subX0 = px0 + ((tu - tileMinU) * regionSize) / spanU;
        int subX1 = px0 + ((tu - tileMinU + 1) * regionSize) / spanU;
        int subY0 = py0 + ((tv - tileMinV) * regionSize) / spanV;
        int subY1 = py0 + ((tv - tileMinV + 1) * regionSize) / spanV;
        int subW = std::max(1, subX1 - subX0);
        int subH = std::max(1, subY1 - subY0);
        
        AkariImaging::Atlas::bakeChannelTile(_pixels.data(), width, srcPixels.data(),
                                             srcW, srcH, nComp,
                                             0, channelIndex,
                                             subX0, subY0, subW, subH);
      }
    }
  }
}

void
HdAkariTextureAtlas::BakeColorChannel(int px0, int py0, int regionSize,
                                      std::string const &texPath, GfVec3f const &fallbackConst,
                                      int tileMinU, int tileMinV, int tileMaxU, int tileMaxV)
{
  int width = _gridSize.load(std::memory_order_relaxed) * kCellPixels;

  AkariImaging::Atlas::fillColorRegion(_colorPixels.data(), width,
                                       px0, py0, regionSize,
                                       fallbackConst[0], fallbackConst[1], fallbackConst[2]);

  if (!texPath.empty() && tileMinU != INT_MAX) {
    int spanU = tileMaxU - tileMinU + 1;
    int spanV = tileMaxV - tileMinV + 1;

    for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
      for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
        std::string tilePath = AkariImaging::Atlas::resolveUdimTile(texPath, tu, tv);
        std::vector<float> srcPixels;
        int srcW = 0, srcH = 0, nComp = 0;
        if (!DecodeTile(tilePath, srcPixels, srcW, srcH, nComp)) continue;

        int subX0 = px0 + ((tu - tileMinU) * regionSize) / spanU;
        int subX1 = px0 + ((tu - tileMinU + 1) * regionSize) / spanU;
        int subY0 = py0 + ((tv - tileMinV) * regionSize) / spanV;
        int subY1 = py0 + ((tv - tileMinV + 1) * regionSize) / spanV;
        int subW = std::max(1, subX1 - subX0);
        int subH = std::max(1, subY1 - subY0);

        AkariImaging::Atlas::bakeColorTile(_colorPixels.data(), width,
                                           srcPixels.data(), srcW, srcW, nComp,
                                           subX0, subY0, subW, subH);
      }
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
