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
# include <Ar/asset.h>
# include <Ar/resolvedPath.h>
# include <Ar/resolver.h>
# include <Hd/material.h>
# include <Hd/mesh.h>
# include <Hd/renderIndex.h>
# include <Hd/sceneDelegate.h>
# include <Hio/image.h>
# include <Hio/types.h>
# include <Work/loops.h>
# include <Work/withScopedParallelism.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/ar/asset.h>
# include <pxr/usd/ar/resolvedPath.h>
# include <pxr/usd/ar/resolver.h>
# include <pxr/imaging/hd/material.h>
# include <pxr/imaging/hd/mesh.h>
# include <pxr/imaging/hd/renderIndex.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hio/image.h>
# include <pxr/imaging/hio/types.h>
# include <pxr/base/work/loops.h>
# include <pxr/base/work/withScopedParallelism.h>
#endif

#include <atomic>
#include "HdAkari/textureAtlas.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/akariImaging.h" // swift -> c++ interop, see Sources/AkariImaging.

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// Empty atlas space reads fully opaque, so filtering into it never dithers an opaque material.
void AssignMaterialPixels(std::vector<uint8_t> &pixels, size_t size)
{
  pixels.assign(size, uint8_t(0));
  for (size_t i = size_t(AkariImaging::Atlas::physicalChannel(2)); i < size; i += 4) pixels[i] = 255;
}

} // namespace

namespace {

/// Whether Ar can open the asset, so package
/// paths like `a.usdz[b.png]` resolve too.
bool AssetExists(std::string const &path)
{
  return ArGetResolver().OpenAsset(ArResolvedPath(path)) != nullptr;
}

/// Finds every UDIM tile that exists on disk for a templated path.
std::vector<std::pair<int, int>> DiscoverUdimTiles(std::string const &templatePath)
{
  std::vector<std::pair<int, int>> tiles;
  if (templatePath.empty()) return tiles;

  auto pos = templatePath.find("<UDIM>");
  if (pos == std::string::npos) {
    if (AssetExists(templatePath)) tiles.push_back({0, 0});
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

/// Converts one texel of raw bytes into `nComp` floats,
/// sRGB bytes decoded to linear when `decodeSRGB` is set.
void ConvertTexelToFloat(uint8_t const *raw, HioType type, int nComp, bool decodeSRGB, float *out)
{
  switch (type) {
    case HioTypeUnsignedByte:
      for (int c = 0; c < nComp; ++c) out[c] = float(raw[c]) / 255.0f;
      return;
    case HioTypeUnsignedByteSRGB:
      for (int c = 0; c < nComp; ++c) {
        float v = float(raw[c]) / 255.0f;
        // alpha stays linear.
        if (decodeSRGB && c < 3) {
          v = v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
        }

        out[c] = v;
      }

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
bool DecodeTile(std::string const &tilePath, bool decodeSRGB, std::vector<float> &outPixels,
                int &outW, int &outH, int &outComp)
{
  HioImageSharedPtr image = HioImage::OpenForReading(
      tilePath, 0, 0, decodeSRGB ? HioImage::SourceColorSpace::Auto : HioImage::SourceColorSpace::Raw);
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
    ConvertTexelToFloat(rawPixels.data() + t * texelBytes, srcType, nComp, decodeSRGB,
                        outPixels.data() + t * size_t(nComp));
  }

  outW = srcW; outH = srcH; outComp = nComp;
  return true;
}

} // namespace

void
HdAkariTextureAtlas::EnsureGridSized(HdSceneDelegate *sceneDelegate)
{
  if (_sized.load(std::memory_order_acquire)) return;
  std::call_once(_sizeOnce, [this, sceneDelegate]() {
    _sizeMaterials =
      sceneDelegate->GetRenderIndex().GetSprimSubtree(HdPrimTypeTokens->material, SdfPath::AbsoluteRootPath());
  });
  const size_t count = _sizeMaterials.size();
  size_t finished = 0;
  for (size_t i; (i = _sizeNext.fetch_add(1)) < count; ++finished) {
    GfVec3f color(0.0f);
    float opacity = 1.0f, roughness = 0.5f, metallic = 0.0f, opacityThreshold = 0.0f;
    HdAkariMaterialTextures textures;
    SdfPath resolved;
    // isolated, so waiting here can't steal a Sync task.
    WorkWithScopedParallelism([&]() {
      HdAkariApplyMaterialId(sceneDelegate, _sizeMaterials[i], color, opacity, roughness, metallic, opacityThreshold,
                             textures, resolved);
    });
    if (textures.hasAny) ++_sizeTextured;
  }

  std::unique_lock<std::mutex> lock(_sizeMutex);
  _sizeFinished += finished;
  if (_sized) return;
  if (_sizeFinished < count) {
    _sizeDone.wait(lock, [&] { return _sized.load(); });
    return;
  }

  const size_t texturedCount = _sizeTextured.load();
  size_t withHeadroom = texturedCount + texturedCount / 4 + 1;
  int grid = 1;
  while (size_t(grid) * size_t(grid) < withHeadroom) ++grid;
  // if a stage exceeds the maximum texture size, extra materials will share
  // existing slots instead of creating an oversized texture that crashes.
  grid = std::min(grid, kMaxGridSize);
  int cellPixels = kCellPixels;
  if (texturedCount == 0) {
    grid = std::max(grid, kDefaultGridSize);
  } else {
    while (cellPixels < kMaxCellPixels && grid * cellPixels * 2 <= kMaxAtlasPixels) cellPixels *= 2;
  }

  _cellPixels.store(cellPixels, std::memory_order_relaxed);
  _gridSize.store(grid, std::memory_order_relaxed);
  _sized.store(true, std::memory_order_release);
  _sizeDone.notify_all();
}

HdAkariAtlasCell
HdAkariTextureAtlas::GetOrBakeCell(std::string const &materialKey,
                                   std::string const &roughnessPath, float roughnessConst,
                                   std::string const &metallicPath, float metallicConst,
                                   std::string const &opacityPath, float opacityConst,
                                   float opacityThreshold,
                                   std::string const &colorPath, GfVec3f const &colorConst,
                                   std::string const &normalPath,
                                   std::string const &emissivePath, GfVec3f const &emissiveConst,
                                   HdAkariScalarSources const &sources)
{
  HdAkariAtlasCell cell;
  int tileMinU = INT_MAX, tileMinV = INT_MAX, tileMaxU = INT_MIN, tileMaxV = INT_MIN;
  std::promise<HdAkariAtlasCell> promise;
  int gridSize = _gridSize.load(std::memory_order_relaxed);
  int cellPixels = _cellPixels.load(std::memory_order_relaxed);
  int width = gridSize * cellPixels;

  // no texture bound anywhere -> a constants row, not a cell.
  bool isConstOnly = roughnessPath.empty() && metallicPath.empty() &&
                     opacityPath.empty() && colorPath.empty() &&
                     normalPath.empty() && emissivePath.empty();
  int px0 = 0, py0 = 0, regionSize = cellPixels;
  // baked content is inset from the cell's actual grid placement,
  // leaving a border for `AkariImaging::Atlas::fillCellBorder` to
  // replicate into.
  int contentPx0 = 0, contentPy0 = 0, contentSize = cellPixels;

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

    if (isConstOnly) {
      const int index = int(_constantIndex.size());
      _constantIndex.emplace(materialKey, index);
      _constants.resize(size_t(index + 1) * kConstantTexels * 4, 0.0f);
      WriteConstants(index, colorConst, opacityConst, roughnessConst, metallicConst, opacityThreshold, emissiveConst);
      cell.constantIndex = index;
      cell.opacityThreshold = opacityThreshold;
      _cells.emplace(materialKey, cell);
      return cell;
    }

    if (_pixels.empty()) {
      AssignMaterialPixels(_pixels, size_t(width) * size_t(width) * 4);
    }

    if (_colorPixels.empty()) {
      _colorPixels.assign(size_t(width) * size_t(width) * 4, uint8_t(0));
    }

    if (_normalPixels.empty()) {
      _normalPixels.assign(size_t(width) * size_t(width) * 4, uint8_t(0));
    }

    if (_emissivePixels.empty()) {
      _emissivePixels.assign(size_t(width) * size_t(width) * 4, uint8_t(0));
    }

    // share cells using round-robin.
    int cellIndex = _nextCell % (gridSize * gridSize);
    ++_nextCell;
    px0 = (cellIndex % gridSize) * cellPixels;
    py0 = (cellIndex / gridSize) * cellPixels;
    regionSize = cellPixels;
    contentPx0 = px0 + kCellPadding;
    contentPy0 = py0 + kCellPadding;
    contentSize = regionSize - 2 * kCellPadding;
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
    scanTiles(normalPath);
    scanTiles(emissivePath);

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
  BakeInputs in;
  in.roughnessPath = roughnessPath; in.metallicPath = metallicPath; in.opacityPath = opacityPath;
  in.colorPath = colorPath; in.normalPath = normalPath; in.emissivePath = emissivePath;
  in.roughnessConst = roughnessConst; in.metallicConst = metallicConst; in.opacityConst = opacityConst;
  in.opacityThreshold = opacityThreshold; in.colorConst = colorConst; in.emissiveConst = emissiveConst;
  in.px0 = px0; in.py0 = py0; in.regionSize = regionSize;
  in.contentPx0 = contentPx0; in.contentPy0 = contentPy0; in.contentSize = contentSize;
  in.tileMinU = tileMinU; in.tileMinV = tileMinV; in.tileMaxU = tileMaxU; in.tileMaxV = tileMaxV;
  in.sources = sources;
  BakeRegion(in);
  cell.opacityThreshold = opacityThreshold;

  {
    std::lock_guard<std::mutex> lock(_mutex);
    _cells.emplace(materialKey, cell);
    _pending.erase(materialKey);
    _dirtyRects.push_back({px0, py0, regionSize});
  }

  _dirty.store(true, std::memory_order_release);
  promise.set_value(cell);
  return cell;
}

void
HdAkariTextureAtlas::BakeRegion(BakeInputs const &in)
{
  int width = _gridSize.load(std::memory_order_relaxed) * _cellPixels.load(std::memory_order_relaxed);
  BakeChannel(in.contentPx0, in.contentPy0, in.contentSize, /*R*/ 0, in.roughnessPath, in.roughnessConst,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV, in.sources.roughness);
  BakeChannel(in.contentPx0, in.contentPy0, in.contentSize, /*G*/ 1, in.metallicPath, in.metallicConst,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV, in.sources.metallic);
  BakeChannel(in.contentPx0, in.contentPy0, in.contentSize, /*B*/ 2, in.opacityPath, in.opacityConst,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV, in.sources.opacity);
  BakeChannel(in.contentPx0, in.contentPy0, in.contentSize, /*A*/ 3, std::string(), in.opacityThreshold,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);

  BakeColorChannel(_colorPixels, true, in.contentPx0, in.contentPy0, in.contentSize, in.colorPath, in.colorConst,
                   in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);
  BakeColorChannel(_normalPixels, false, in.contentPx0, in.contentPy0, in.contentSize, in.normalPath,
                   GfVec3f(0.5f, 0.5f, 1.0f), in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);
  // emission past 1 keeps its scale in alpha, read back as 1 / alpha.
  GfVec3f emissive = in.emissiveConst;
  uint8_t emissiveAlpha = 255;
  const float peak = std::max(emissive[0], std::max(emissive[1], emissive[2]));
  if (in.emissivePath.empty() && peak > 1.0f) {
    emissiveAlpha = uint8_t(std::clamp(std::lround(255.0f / peak), 1L, 255L));
    emissive *= float(emissiveAlpha) / 255.0f;
  }

  BakeColorChannel(_emissivePixels, true, in.contentPx0, in.contentPy0, in.contentSize, in.emissivePath, emissive,
                   in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);
  if (emissiveAlpha != 255) {
    for (int y = 0; y < in.contentSize; ++y)
      for (int x = 0; x < in.contentSize; ++x)
        _emissivePixels[(size_t(in.contentPy0 + y) * width + size_t(in.contentPx0 + x)) * 4 + 3] = emissiveAlpha;
  }

  AkariImaging::Atlas::fillCellBorder(_pixels.data(), _colorPixels.data(), width, in.px0, in.py0, in.regionSize, kCellPadding);
  AkariImaging::Atlas::fillCellBorder(_normalPixels.data(), _emissivePixels.data(), width, in.px0, in.py0, in.regionSize,
                                      kCellPadding);
}

void
HdAkariTextureAtlas::WriteConstants(int index, GfVec3f const &color, float opacity, float roughness, float metallic,
                                    float opacityThreshold, GfVec3f const &emissive)
{
  float *row = _constants.data() + size_t(index) * kConstantTexels * 4;
  const float values[kConstantTexels * 4] = {color[0], color[1], color[2], opacity,
                                             roughness, metallic, opacityThreshold, 0.0f,
                                             emissive[0], emissive[1], emissive[2], 0.0f};
  std::copy(values, values + kConstantTexels * 4, row);
  _constantsDirtyLo = std::min(_constantsDirtyLo, index);
  _constantsDirtyHi = std::max(_constantsDirtyHi, index + 1);
}

bool
HdAkariTextureAtlas::UpdateConstants(std::string const &materialKey, GfVec3f const *emissive, float const *opacity)
{
  std::lock_guard<std::mutex> lock(_mutex);
  auto it = _constantIndex.find(materialKey);
  if (it == _constantIndex.end()) return false;
  float *row = _constants.data() + size_t(it->second) * kConstantTexels * 4;
  const bool emissiveChanged = emissive && GfVec3f(row[8], row[9], row[10]) != *emissive;
  const bool opacityChanged = opacity && row[3] != *opacity;
  if (!emissiveChanged && !opacityChanged) return false;
  if (emissiveChanged) { row[8] = (*emissive)[0]; row[9] = (*emissive)[1]; row[10] = (*emissive)[2]; }
  if (opacityChanged) row[3] = *opacity;
  _constantsDirtyLo = std::min(_constantsDirtyLo, it->second);
  _constantsDirtyHi = std::max(_constantsDirtyHi, it->second + 1);
  return true;
}

bool
HdAkariTextureAtlas::UpdateConstantMaterial(std::string const &materialKey, GfVec3f const &color, float opacity,
                                            float roughness, float metallic, float opacityThreshold,
                                            GfVec3f const &emissive)
{
  std::lock_guard<std::mutex> lock(_mutex);
  auto it = _constantIndex.find(materialKey);
  if (it == _constantIndex.end()) return false;
  const float ptexMap = _constants[size_t(it->second) * kConstantTexels * 4 + 11];
  WriteConstants(it->second, color, opacity, roughness, metallic, opacityThreshold, emissive);
  _constants[size_t(it->second) * kConstantTexels * 4 + 11] = ptexMap;
  auto cell = _cells.find(materialKey);
  if (cell != _cells.end()) cell->second.opacityThreshold = opacityThreshold;
  return true;
}

bool
HdAkariTextureAtlas::GetConstants(std::string const &materialKey, float *out)
{
  std::lock_guard<std::mutex> lock(_mutex);
  auto it = _constantIndex.find(materialKey);
  if (it == _constantIndex.end()) return false;
  const float *row = _constants.data() + size_t(it->second) * kConstantTexels * 4;
  std::copy(row, row + kConstantTexels * 4, out);
  return true;
}

void
HdAkariTextureAtlas::ForgetCell(std::string const &materialKey)
{
  std::lock_guard<std::mutex> lock(_mutex);
  if (_constantIndex.count(materialKey) == 0) _cells.erase(materialKey);
}

void
HdAkariTextureAtlas::SetConstantsPtexMap(std::string const &materialKey, int map)
{
  std::lock_guard<std::mutex> lock(_mutex);
  auto it = _constantIndex.find(materialKey);
  if (it == _constantIndex.end()) return;
  float *row = _constants.data() + size_t(it->second) * kConstantTexels * 4;
  if (row[11] == float(map + 1)) return;
  row[11] = float(map + 1);
  _constantsDirtyLo = std::min(_constantsDirtyLo, it->second);
  _constantsDirtyHi = std::max(_constantsDirtyHi, it->second + 1);
}

void
HdAkariTextureAtlas::BakeChannel(int px0, int py0, int regionSize, int channelIndex,
                                 std::string const &texPath, float fallbackConst,
                                 int tileMinU, int tileMinV, int tileMaxU, int tileMaxV, int sourceChannel)
{
  int width = _gridSize.load(std::memory_order_relaxed) * _cellPixels.load(std::memory_order_relaxed);

  AkariImaging::Atlas::fillChannel(_pixels.data(), width, px0, py0, regionSize, channelIndex, fallbackConst);

  if (!texPath.empty() && tileMinU != INT_MAX) {
    int spanU = tileMaxU - tileMinU + 1;
    int spanV = tileMaxV - tileMinV + 1;

    for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
      for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
        std::string tilePath = AkariImaging::Atlas::resolveUdimTile(texPath, tu, tv);
        std::vector<float> srcPixels;
        int srcW = 0, srcH = 0, nComp = 0;
        if (!DecodeTile(tilePath, false, srcPixels, srcW, srcH, nComp)) continue;
        // an alpha read from a texture without one is opaque, the constant stands.
        if (sourceChannel >= nComp && nComp != 1) continue;

        int subX0 = px0 + ((tu - tileMinU) * regionSize) / spanU;
        int subX1 = px0 + ((tu - tileMinU + 1) * regionSize) / spanU;
        int subY0 = py0 + ((tv - tileMinV) * regionSize) / spanV;
        int subY1 = py0 + ((tv - tileMinV + 1) * regionSize) / spanV;
        int subW = std::max(1, subX1 - subX0);
        int subH = std::max(1, subY1 - subY0);
        
        AkariImaging::Atlas::bakeChannelTile(_pixels.data(), width, srcPixels.data(),
                                             srcW, srcH, nComp,
                                             sourceChannel, channelIndex,
                                             subX0, subY0, subW, subH);
      }
    }
  }
}

void
HdAkariTextureAtlas::BakeColorChannel(std::vector<uint8_t> &target, bool decodeSRGB,
                                      int px0, int py0, int regionSize,
                                      std::string const &texPath, GfVec3f const &fallbackConst,
                                      int tileMinU, int tileMinV, int tileMaxU, int tileMaxV)
{
  int width = _gridSize.load(std::memory_order_relaxed) * _cellPixels.load(std::memory_order_relaxed);

  AkariImaging::Atlas::fillColorRegion(target.data(), width,
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
        if (!DecodeTile(tilePath, decodeSRGB, srcPixels, srcW, srcH, nComp)) continue;

        int subX0 = px0 + ((tu - tileMinU) * regionSize) / spanU;
        int subX1 = px0 + ((tu - tileMinU + 1) * regionSize) / spanU;
        int subY0 = py0 + ((tv - tileMinV) * regionSize) / spanV;
        int subY1 = py0 + ((tv - tileMinV + 1) * regionSize) / spanV;
        int subW = std::max(1, subX1 - subX0);
        int subH = std::max(1, subY1 - subY0);

        AkariImaging::Atlas::bakeColorTile(target.data(), width,
                                           srcPixels.data(), srcW, srcH, nComp,
                                           subX0, subY0, subW, subH);
      }
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
