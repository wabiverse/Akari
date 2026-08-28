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

/// Substitutes a UDIM tile number into a "<UDIM>"-templated path.
/// `u`/`v` are tile grid coordinates (tile 1001 is u=0,v=0).
std::string ResolveUdimTile(std::string const &templatePath, int u, int v)
{
  auto pos = templatePath.find("<UDIM>");
  if (pos == std::string::npos) return templatePath;
  int tileNum = 1001 + u + v * 10;
  char buf[8];
  std::snprintf(buf, sizeof(buf), "%04d", tileNum);
  return templatePath.substr(0, pos) + buf + templatePath.substr(pos + 6);
}

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

/// Quantizes a [0,1] float channel value to an 8-bit UNORM byte.
uint8_t Quantize(float v)
{
  v = std::clamp(v, 0.0f, 1.0f);
  return uint8_t(v * 255.0f + 0.5f);
}

/// Maps a semantic RGBA channel index (0=R, 1=G, 2=B, 3=A) to its physical
/// byte offset within a texel.
int PhysicalChannel(int semanticIndex)
{
  switch (semanticIndex) {
    case 0: return 2;
    case 2: return 0;
    default: return semanticIndex;
  }
}

/// Averages one destination texel's footprint in source space.
float BoxFilterSample(std::vector<float> const &srcPixels, int srcW, int srcH, int nComp,
                      int comp, int destX, int destW, int destY, int destH)
{
  int sx0 = (destX * srcW) / destW;
  int sx1 = std::min(srcW, std::max(sx0 + 1, ((destX + 1) * srcW) / destW));
  int sy0 = (destY * srcH) / destH;
  int sy1 = std::min(srcH, std::max(sy0 + 1, ((destY + 1) * srcH) / destH));

  double accum = 0.0;
  int count = 0;
  for (int sy = sy0; sy < sy1; ++sy) {
    for (int sx = sx0; sx < sx1; ++sx) {
      accum += srcPixels[(size_t(sy) * size_t(srcW) + size_t(sx)) * size_t(nComp) + size_t(comp)];
      ++count;
    }
  }
  return count > 0 ? float(accum / double(count)) : 0.0f;
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
    WorkParallelForN(rprimIds.size(), [&](size_t begin, size_t end) {
      std::unordered_set<SdfPath, SdfPath::Hash> local;
      for (size_t i = begin; i < end; ++i) {
        SdfPath matId = sceneDelegate->GetMaterialId(rprimIds[i]);
        if (!matId.IsEmpty()) local.insert(matId);
      }
      if (!local.empty()) {
        std::lock_guard<std::mutex> lock(mergeMutex);
        uniqueMaterials.insert(local.begin(), local.end());
      }
    }, /*grainSize=*/64);

    size_t withHeadroom = uniqueMaterials.size() + uniqueMaterials.size() / 4 + 1;
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
  int cellX = 0, cellY = 0;
  HdAkariAtlasCell cell;
  int tileMinU = INT_MAX, tileMinV = INT_MAX, tileMaxU = INT_MIN, tileMaxV = INT_MIN;
  std::promise<HdAkariAtlasCell> promise;
  int gridSize = _gridSize.load(std::memory_order_relaxed);
  int width = gridSize * kCellPixels;

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

    // share cells using round-robin.
    int cellIndex = _nextCell % (gridSize * gridSize);
    ++_nextCell;
    cellX = cellIndex % gridSize;
    cellY = cellIndex / gridSize;

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

    float cellPix = float(kCellPixels);
    cell.u0 = float(cellX) * cellPix / float(width);
    cell.v0 = float(cellY) * cellPix / float(width);
    cell.u1 = cell.u0 + cellPix / float(width);
    cell.v1 = cell.v0 + cellPix / float(width);

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
  float avgOpacity = opacityConst;
  BakeChannel(cellX, cellY, /*R*/ 0, roughnessPath, roughnessConst,
              tileMinU, tileMinV, tileMaxU, tileMaxV, nullptr);
  BakeChannel(cellX, cellY, /*G*/ 1, metallicPath, metallicConst,
              tileMinU, tileMinV, tileMaxU, tileMaxV, nullptr);
  BakeChannel(cellX, cellY, /*B*/ 2, opacityPath, opacityConst,
              tileMinU, tileMinV, tileMaxU, tileMaxV, &avgOpacity);
  cell.averageOpacity = avgOpacity;

  BakeChannel(cellX, cellY, /*A*/ 3, std::string(), opacityThreshold,
              tileMinU, tileMinV, tileMaxU, tileMaxV, nullptr);
  cell.opacityThreshold = opacityThreshold;

  BakeColorChannel(cellX, cellY, colorPath, colorConst,
                   tileMinU, tileMinV, tileMaxU, tileMaxV);

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
HdAkariTextureAtlas::BakeChannel(int cellX, int cellY, int channelIndex,
                                 std::string const &texPath, float fallbackConst,
                                 int tileMinU, int tileMinV, int tileMaxU, int tileMaxV,
                                 float *outAverage)
{
  int width = _gridSize.load(std::memory_order_relaxed) * kCellPixels;
  int cellPx0 = cellX * kCellPixels;
  int cellPy0 = cellY * kCellPixels;

  double sum = 0.0;
  uint8_t fallbackByte = Quantize(fallbackConst);
  int physChannel = PhysicalChannel(channelIndex);
  for (int y = 0; y < kCellPixels; ++y) {
    for (int x = 0; x < kCellPixels; ++x) {
      size_t idx = (size_t(cellPy0 + y) * size_t(width) + size_t(cellPx0 + x)) * 4 + physChannel;
      _pixels[idx] = fallbackByte;
    }
  }
  sum = double(fallbackByte) / 255.0 * double(kCellPixels) * double(kCellPixels);
  size_t count = size_t(kCellPixels) * size_t(kCellPixels);

  if (!texPath.empty() && tileMinU != INT_MAX) {
    int spanU = tileMaxU - tileMinU + 1;
    int spanV = tileMaxV - tileMinV + 1;

    for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
      for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
        std::string tilePath = ResolveUdimTile(texPath, tu, tv);
        std::vector<float> srcPixels;
        int srcW = 0, srcH = 0, nComp = 0;
        if (!DecodeTile(tilePath, srcPixels, srcW, srcH, nComp)) continue;

        int subX0 = cellPx0 + ((tu - tileMinU) * kCellPixels) / spanU;
        int subX1 = cellPx0 + ((tu - tileMinU + 1) * kCellPixels) / spanU;
        int subY0 = cellPy0 + ((tv - tileMinV) * kCellPixels) / spanV;
        int subY1 = cellPy0 + ((tv - tileMinV + 1) * kCellPixels) / spanV;
        int subW = std::max(1, subX1 - subX0);
        int subH = std::max(1, subY1 - subY0);

        for (int y = 0; y < subH; ++y) {
          for (int x = 0; x < subW; ++x) {
            float v = BoxFilterSample(srcPixels, srcW, srcH, nComp, 0, x, subW, y, subH);
            uint8_t b = Quantize(v);
            size_t idx = (size_t(subY0 + y) * size_t(width) + size_t(subX0 + x)) * 4 + physChannel;
            sum += double(b) / 255.0 - double(_pixels[idx]) / 255.0;
            _pixels[idx] = b;
          }
        }
      }
    }
  }

  if (outAverage) {
    *outAverage = count > 0 ? float(sum / double(count)) : fallbackConst;
  }
}

void
HdAkariTextureAtlas::BakeColorChannel(int cellX, int cellY,
                                      std::string const &texPath, GfVec3f const &fallbackConst,
                                      int tileMinU, int tileMinV, int tileMaxU, int tileMaxV)
{
  int width = _gridSize.load(std::memory_order_relaxed) * kCellPixels;
  int cellPx0 = cellX * kCellPixels;
  int cellPy0 = cellY * kCellPixels;

  uint8_t fbR = Quantize(fallbackConst[0]);
  uint8_t fbG = Quantize(fallbackConst[1]);
  uint8_t fbB = Quantize(fallbackConst[2]);
  for (int y = 0; y < kCellPixels; ++y) {
    for (int x = 0; x < kCellPixels; ++x) {
      size_t idx = (size_t(cellPy0 + y) * size_t(width) + size_t(cellPx0 + x)) * 4;
      _colorPixels[idx + PhysicalChannel(0)] = fbR;
      _colorPixels[idx + 1] = fbG;
      _colorPixels[idx + PhysicalChannel(2)] = fbB;
      _colorPixels[idx + 3] = 255;
    }
  }

  if (!texPath.empty() && tileMinU != INT_MAX) {
    int spanU = tileMaxU - tileMinU + 1;
    int spanV = tileMaxV - tileMinV + 1;

    for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
      for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
        std::string tilePath = ResolveUdimTile(texPath, tu, tv);
        std::vector<float> srcPixels;
        int srcW = 0, srcH = 0, nComp = 0;
        if (!DecodeTile(tilePath, srcPixels, srcW, srcH, nComp)) continue;

        int subX0 = cellPx0 + ((tu - tileMinU) * kCellPixels) / spanU;
        int subX1 = cellPx0 + ((tu - tileMinU + 1) * kCellPixels) / spanU;
        int subY0 = cellPy0 + ((tv - tileMinV) * kCellPixels) / spanV;
        int subY1 = cellPy0 + ((tv - tileMinV + 1) * kCellPixels) / spanV;
        int subW = std::max(1, subX1 - subX0);
        int subH = std::max(1, subY1 - subY0);

        for (int y = 0; y < subH; ++y) {
          for (int x = 0; x < subW; ++x) {
            float r = BoxFilterSample(srcPixels, srcW, srcH, nComp, 0, x, subW, y, subH);
            float g = nComp >= 2 ? BoxFilterSample(srcPixels, srcW, srcH, nComp, 1, x, subW, y, subH) : r;
            float b = nComp >= 3 ? BoxFilterSample(srcPixels, srcW, srcH, nComp, 2, x, subW, y, subH) : r;
            size_t idx = (size_t(subY0 + y) * size_t(width) + size_t(subX0 + x)) * 4;
            _colorPixels[idx + PhysicalChannel(0)] = Quantize(r);
            _colorPixels[idx + 1] = Quantize(g);
            _colorPixels[idx + PhysicalChannel(2)] = Quantize(b);
            _colorPixels[idx + 3] = 255;
          }
        }
      }
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
