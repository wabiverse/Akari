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
#include "HdAkari/akariImaging.h" // swift to c++ interop, see `Sources/AkariImaging`

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <filesystem>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// empty atlas space reads fully opaque so filtering into it never dithers an opaque material
void AssignMaterialPixels(std::vector<uint8_t> &pixels, size_t size)
{
  pixels.assign(size, uint8_t(0));
  for (size_t i = size_t(AkariImaging::Atlas::physicalChannel(2)); i < size; i += 4) pixels[i] = 255;
}

/// whether the asset resolver can open the asset, so package paths like `a.usdz[b.png]` resolve too
bool AssetExists(std::string const &path)
{
  return ArGetResolver().OpenAsset(ArResolvedPath(path)) != nullptr;
}

/// finds every udim tile that exists on disk for a templated path
std::vector<std::pair<int, int>> DiscoverUdimTiles(std::string const &templatePath)
{
  std::vector<std::pair<int, int>> tiles;
  if (templatePath.empty()) return tiles;

  const auto pos = templatePath.find("<UDIM>");
  if (pos == std::string::npos) {
    if (AssetExists(templatePath)) tiles.push_back({0, 0});
    return tiles;
  }

  const std::filesystem::path full(templatePath);
  const std::string dir = full.parent_path().string();
  const std::string prefix = std::filesystem::path(templatePath.substr(0, pos)).filename().string();
  const std::string suffix = templatePath.substr(pos + 6);

  std::error_code ec;
  for (auto const &entry : std::filesystem::directory_iterator(dir, ec)) {
    if (ec) break;

    const std::string name = entry.path().filename().string();
    if (name.size() < prefix.size() + suffix.size() + 4) continue;
    if (name.compare(0, prefix.size(), prefix) != 0) continue;
    if (name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) continue;

    const std::string tileStr = name.substr(prefix.size(), 4);
    if (tileStr.size() != 4 || !std::all_of(tileStr.begin(), tileStr.end(), ::isdigit)) continue;

    const int tileNum = std::stoi(tileStr);
    if (tileNum < 1001) continue;

    tiles.push_back({(tileNum - 1001) % 10, (tileNum - 1001) / 10});
  }

  return tiles;
}

/// converts a texel of raw bytes into `nComp` floats, decoding srgb to linear when asked
void ConvertTexelToFloat(uint8_t const *raw, HioType type, int nComp, bool decodeSRGB, float *out)
{
  switch (type) {
    case HioTypeUnsignedByte:
      for (int c = 0; c < nComp; ++c) out[c] = float(raw[c]) / 255.0f;
      return;
    case HioTypeUnsignedByteSRGB:
      for (int c = 0; c < nComp; ++c) {
        float v = float(raw[c]) / 255.0f;

        // alpha stays linear
        if (decodeSRGB && c < 3) {
          v = v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
        }

        out[c] = v;
      }

      return;
    case HioTypeSignedByte:
      for (int c = 0; c < nComp; ++c) {
        out[c] = std::max(float(reinterpret_cast<int8_t const *>(raw)[c]) / 127.0f, -1.0f);
      }

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
        const uint16_t h = p[c];
        const uint32_t sign = uint32_t(h & 0x8000) << 16;
        const uint32_t exp = (h >> 10) & 0x1F;
        uint32_t mant = h & 0x3FF;
        uint32_t bits;

        if (exp == 0) {
          if (mant == 0) {
            bits = sign;
          } else {
            // a subnormal half becomes a normalized float
            int shift = 0;
            while ((mant & 0x400) == 0) { mant <<= 1; ++shift; }
            mant &= 0x3FF;
            const uint32_t fexp = uint32_t(127 - 15 - shift + 1);
            bits = sign | (fexp << 23) | (mant << 13);
          }
        } else if (exp == 0x1F) {
          bits = sign | 0x7F800000u | (mant << 13); // inf or nan
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

/// fills a rect of one semantic channel with a constant
void FillChannelRect(uint8_t *pixels, int width, int x0, int y0, int w, int h, int channel, float value)
{
  const uint8_t byte = AkariImaging::Atlas::quantize(value);
  const size_t phys = size_t(AkariImaging::Atlas::physicalChannel(channel));

  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) pixels[(size_t(y0 + y) * width + size_t(x0 + x)) * 4 + phys] = byte;
  }
}

/// fills a rect of a color atlas with a constant rgb and full alpha
void FillColorRect(uint8_t *pixels, int width, int x0, int y0, int w, int h, GfVec3f const &color)
{
  const uint8_t r = AkariImaging::Atlas::quantize(color[0]), g = AkariImaging::Atlas::quantize(color[1]),
                b = AkariImaging::Atlas::quantize(color[2]);
  const size_t pr = size_t(AkariImaging::Atlas::physicalChannel(0)), pb = size_t(AkariImaging::Atlas::physicalChannel(2));

  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      uint8_t *px = pixels + (size_t(y0 + y) * width + size_t(x0 + x)) * 4;
      px[pr] = r;
      px[1] = g;
      px[pb] = b;
      px[3] = 255;
    }
  }
}

/// copies a region's baked interior out into its padding ring so mips never bleed between neighbours
void FillBorderRect(uint8_t *pixels, int width, int x0, int y0, int w, int h, int padding)
{
  const int cx0 = x0 + padding, cx1 = x0 + w - padding, cy0 = y0 + padding, cy1 = y0 + h - padding;
  if (cx1 <= cx0 || cy1 <= cy0) return;

  for (int py = y0; py < y0 + h; ++py) {
    const int sy = std::clamp(py, cy0, cy1 - 1);
    for (int px = x0; px < x0 + w; ++px) {
      if (px >= cx0 && px < cx1 && py >= cy0 && py < cy1) continue;

      const int sx = std::clamp(px, cx0, cx1 - 1);
      std::memcpy(pixels + (size_t(py) * width + size_t(px)) * 4, pixels + (size_t(sy) * width + size_t(sx)) * 4, 4);
    }
  }
}

/// grows the rgb of opaque texels `passes` deep into the transparent ones around them, leaving alpha as baked
void DilateUnderAlpha(uint8_t const *material, std::initializer_list<uint8_t *> buffers, int stride,
                      int x0, int y0, int w, int h, int passes)
{
  const size_t opacity = size_t(AkariImaging::Atlas::physicalChannel(2));

  std::vector<uint8_t> solid(size_t(w) * size_t(h));
  size_t hollow = 0;
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      solid[size_t(y) * w + x] = material[(size_t(y0 + y) * stride + size_t(x0 + x)) * 4 + opacity] != 0;
      hollow += solid[size_t(y) * w + x] == 0;
    }
  }

  if (hollow == 0 || hollow == solid.size()) return;

  std::vector<uint8_t> next = solid;
  std::vector<int> source(solid.size(), -1);
  for (int pass = 0; pass < passes; ++pass) {
    bool grew = false;
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < w; ++x) {
        const size_t i = size_t(y) * w + x;
        if (solid[i]) continue;

        int from = -1;
        if (x > 0 && solid[i - 1]) from = int(i - 1);
        else if (x + 1 < w && solid[i + 1]) from = int(i + 1);
        else if (y > 0 && solid[i - w]) from = int(i - w);
        else if (y + 1 < h && solid[i + w]) from = int(i + w);
        if (from < 0) continue;

        source[i] = from;
        next[i] = 1;
        grew = true;
      }
    }

    if (!grew) break;

    for (size_t i = 0; i < solid.size(); ++i) {
      if (solid[i] || !next[i]) continue;

      const size_t from = size_t(source[i]);
      const size_t dst = (size_t(y0) + i / w) * stride + size_t(x0) + i % w;
      const size_t src = (size_t(y0) + from / w) * stride + size_t(x0) + from % w;
      for (uint8_t *buffer : buffers) std::memcpy(buffer + dst * 4, buffer + src * 4, 3);
    }

    solid = next;
  }
}

/// a texture's native size from its header alone, a udim set counts 1024 per tile, zero when it can't be read
std::pair<int, int> TextureSize(std::string const &path)
{
  if (path.empty()) return {0, 0};

  if (path.find("<UDIM>") != std::string::npos) {
    int minU = INT_MAX, minV = INT_MAX, maxU = INT_MIN, maxV = INT_MIN;
    for (auto const &t : DiscoverUdimTiles(path)) {
      minU = std::min(minU, t.first); maxU = std::max(maxU, t.first);
      minV = std::min(minV, t.second); maxV = std::max(maxV, t.second);
    }

    if (minU == INT_MAX) return {0, 0};

    return {(maxU - minU + 1) * 1024, (maxV - minV + 1) * 1024};
  }

  HioImageSharedPtr image = HioImage::OpenForReading(path);
  if (!image || image->GetWidth() <= 0 || image->GetHeight() <= 0) return {0, 0};

  return {image->GetWidth(), image->GetHeight()};
}

/// a material's padded region for a texture, its area held to `cap` squared and sides to `maxSide`, so text strips keep their size
std::pair<int, int> RegionSize(int w, int h, int cap, int padding, int align, int maxSide = 16384 - 64)
{
  const float area = std::sqrt(float(std::max(w, 1)) * float(std::max(h, 1)));
  const float scale = std::min({1.0f, float(cap) / area, float(maxSide) / float(std::max({w, h, 1}))});
  const int cw = std::max(int(std::lround(float(w) * scale)), 16);
  const int ch = std::max(int(std::lround(float(h) * scale)), 16);

  auto up = [align](int v) { return (v + align - 1) / align * align; };
  return {up(cw + 2 * padding), up(ch + 2 * padding)};
}

/// shelf packs `sizes` tallest first into `width`, false once they pass `maxHeight`
bool PackShelves(std::vector<std::pair<int, int>> const &sizes, int width, int maxHeight,
                 std::vector<HdAkariAtlasRegion> &out, int &usedHeight)
{
  std::vector<size_t> order(sizes.size());
  for (size_t i = 0; i < order.size(); ++i) order[i] = i;

  std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
    return sizes[a].second != sizes[b].second ? sizes[a].second > sizes[b].second : sizes[a].first > sizes[b].first;
  });

  out.assign(sizes.size(), HdAkariAtlasRegion{});

  int x = 0, y = 0, rowH = 0;
  for (size_t i : order) {
    const int w = sizes[i].first, h = sizes[i].second;
    if (w > width) return false;
    if (x + w > width) {
      y += rowH;
      x = 0;
      rowH = 0;
    }

    if (y + h > maxHeight) return false;

    out[i] = {x, y, w, h};
    x += w;
    rowH = std::max(rowH, h);
  }

  usedHeight = y + rowH;
  return true;
}

/// decodes one udim tile file into a flat float buffer with `outComp` components per texel
bool DecodeTile(std::string const &tilePath, bool decodeSRGB, std::vector<float> &outPixels,
                int &outW, int &outH, int &outComp)
{
  HioImageSharedPtr image = HioImage::OpenForReading(
      tilePath, 0, 0, decodeSRGB ? HioImage::SourceColorSpace::Auto : HioImage::SourceColorSpace::Raw);
  if (!image) {
    return false;
  }

  const int srcW = image->GetWidth();
  const int srcH = image->GetHeight();
  if (srcW <= 0 || srcH <= 0) {
    return false;
  }

  const HioFormat srcFormat = image->GetFormat();
  const int nComp = HioGetComponentCount(srcFormat);
  if (nComp <= 0) {
    return false;
  }

  const HioType srcType = HioGetHioType(srcFormat);
  const size_t compBytes = HioGetDataSizeOfType(srcType);
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

  const size_t texelBytes = size_t(nComp) * compBytes;
  const size_t texelCount = size_t(srcW) * size_t(srcH);
  for (size_t t = 0; t < texelCount; ++t) {
    ConvertTexelToFloat(rawPixels.data() + t * texelBytes, srcType, nComp, decodeSRGB,
                        outPixels.data() + t * size_t(nComp));
  }

  outW = srcW;
  outH = srcH;
  outComp = nComp;
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

    // isolated so waiting here can't steal a sync task
    WorkWithScopedParallelism([&]() {
      HdAkariApplyMaterialId(sceneDelegate, _sizeMaterials[i], color, opacity, roughness, metallic, opacityThreshold,
                             textures, resolved);
    });

    if (textures.hasAny) {
      ++_sizeTextured;

      std::pair<int, int> size{0, 0};
      for (std::string const *path : {&textures.colorPath, &textures.emissivePath, &textures.opacityPath,
                                      &textures.normalPath, &textures.roughnessPath, &textures.metallicPath}) {
        const std::pair<int, int> next = TextureSize(*path);
        if (next.first * next.second > size.first * size.second) size = next;
      }

      if (size.first <= 0) size = {256, 256};

      std::lock_guard<std::mutex> lock(_sizeMutex);
      _sizeItems.push_back({_sizeMaterials[i].GetString(), HdAkariAtlasRegion{0, 0, size.first, size.second}});
    }
  }

  std::unique_lock<std::mutex> lock(_sizeMutex);
  _sizeFinished += finished;
  if (_sized) return;
  if (_sizeFinished < count) {
    _sizeDone.wait(lock, [&] { return _sized.load(); });
    return;
  }

  // picks the smallest atlas that holds every material at its own size, capping the largest only when nothing fits
  std::vector<std::pair<int, int>> sizes;
  std::vector<HdAkariAtlasRegion> placed;

  // a scene with no textures yet still has room for the ones that load later
  int width = 2048, height = 2048, used = 0, cap = kMaxTexturePixels;
  bool packed = _sizeItems.empty();
  for (int tryCap : {16384, 8192, 4096, 3072, 2048, 1536, 1024, 768, 512, 256, 128, 64}) {
    if (packed) break;

    sizes.clear();
    for (auto const &item : _sizeItems) {
      sizes.push_back(RegionSize(item.second.width, item.second.height, tryCap, kCellPadding, kRegionAlign));
    }

    for (int tryWidth = 1024; tryWidth <= kMaxTexturePixels && !packed; tryWidth *= 2) {
      // a sixteenth stays free for materials that load later
      if (PackShelves(sizes, tryWidth, tryWidth - std::max(tryWidth / 16, 256), placed, used)) {
        packed = true;
        width = tryWidth;
        cap = tryCap;
      }
    }
  }

  if (!_sizeItems.empty() && packed) {
    for (size_t i = 0; i < _sizeItems.size(); ++i) _plan.emplace(_sizeItems[i].first, placed[i]);

    const int headroom = std::max(used / 16, 1024);
    height = std::min((used + headroom + kRegionAlign - 1) / kRegionAlign * kRegionAlign, width);
  }

  _planCap = cap;
  _shelfY = used;
  _width.store(width, std::memory_order_relaxed);
  _height.store(height, std::memory_order_relaxed);

  std::fprintf(stderr, "[akari/atlas] %zu textured materials packed into %dx%d, each held to %d squared texels\n",
               _sizeItems.size(), width, height, cap);

  std::vector<std::pair<std::string, HdAkariAtlasRegion>>().swap(_sizeItems);
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
                                   HdAkariScalarSources const &sources,
                                   GfVec3f const &specularConst)
{
  HdAkariAtlasCell cell;
  int tileMinU = INT_MAX, tileMinV = INT_MAX, tileMaxU = INT_MIN, tileMaxV = INT_MIN;
  std::promise<HdAkariAtlasCell> promise;

  // with no texture bound anywhere the material gets a constants row instead of a region
  const bool isConstOnly = roughnessPath.empty() && metallicPath.empty() &&
                     opacityPath.empty() && colorPath.empty() &&
                     normalPath.empty() && emissivePath.empty();

  int px0 = 0, py0 = 0, regionW = 0, regionH = 0;

  // baked content is inset from the region, leaving a border for `FillBorderRect` to replicate into
  int contentPx0 = 0, contentPy0 = 0, contentW = 0, contentH = 0;
  std::string const &shapePath = !colorPath.empty() ? colorPath : !emissivePath.empty() ? emissivePath
                               : !opacityPath.empty() ? opacityPath : !normalPath.empty() ? normalPath
                               : !roughnessPath.empty() ? roughnessPath : metallicPath;

  bool planned = false;
  {
    // a baked or planned material skips the header read below
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _cells.find(materialKey);
    if (it != _cells.end()) return it->second;

    planned = _plan.count(materialKey) != 0;
  }

  std::pair<int, int> lateSize{0, 0};
  if (!isConstOnly && !planned) {
    lateSize = TextureSize(shapePath);
    if (lateSize.first <= 0) lateSize = {256, 256};
  }

  const int width = _width.load(std::memory_order_relaxed);
  const int height = _height.load(std::memory_order_relaxed);
  {
    std::unique_lock<std::mutex> lock(_mutex);

    auto it = _cells.find(materialKey);
    if (it != _cells.end()) return it->second;

    auto pendingIt = _pending.find(materialKey);
    if (pendingIt != _pending.end()) {
      std::shared_future<HdAkariAtlasCell> future = pendingIt->second;
      lock.unlock(); // release before the blocking wait below
      return future.get();
    }

    HdAkariAtlasRegion region{};
    bool placedRegion = false;
    if (!isConstOnly) {
      auto plannedIt = _plan.find(materialKey);
      if (plannedIt != _plan.end()) {
        region = plannedIt->second;
        placedRegion = true;
      } else {
        // a material the plan never saw shelves into the headroom, shrinking until it fits
        for (int cap = _planCap; cap >= 64 && !placedRegion; cap /= 2) {
          const std::pair<int, int> size = RegionSize(lateSize.first, lateSize.second, cap, kCellPadding, kRegionAlign);

          int x = _shelfX, y = _shelfY, rowH = _shelfRowH;
          if (x + size.first > width) { y += rowH; x = 0; rowH = 0; }
          if (size.first > width || y + size.second > height) continue;

          region = {x, y, size.first, size.second};
          _shelfX = x + size.first;
          _shelfY = y;
          _shelfRowH = std::max(rowH, size.second);
          placedRegion = true;
        }

        if (!placedRegion && !_warnedFull) {
          _warnedFull = true;
          std::fprintf(stderr, "HdAkariTextureAtlas: no room left for late materials, they draw their constants.\n");
        }
      }
    }

    if (!placedRegion) {
      const int index = int(_constantIndex.size());
      _constantIndex.emplace(materialKey, index);
      _constants.resize(size_t(index + 1) * kConstantTexels * 4, 0.0f);
      WriteConstants(index, colorConst, opacityConst, roughnessConst, metallicConst, opacityThreshold, emissiveConst,
                     specularConst);

      cell.constantIndex = index;
      cell.opacityThreshold = opacityThreshold;
      _cells.emplace(materialKey, cell);
      return cell;
    }

    px0 = region.x;
    py0 = region.y;
    regionW = region.width;
    regionH = region.height;
    contentPx0 = px0 + kCellPadding;
    contentPy0 = py0 + kCellPadding;
    contentW = regionW - 2 * kCellPadding;
    contentH = regionH - 2 * kCellPadding;

    // find the udim tile range shared by every map
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
    cell.v0 = float(contentPy0) / float(height);
    cell.u1 = cell.u0 + float(contentW) / float(width);
    cell.v1 = cell.v0 + float(contentH) / float(height);

    if (tileMinU == INT_MAX) {
      cell.tileU0 = 0.0f;
      cell.tileV0 = 0.0f;
      cell.tileUSpan = 1.0f;
      cell.tileVSpan = 1.0f;
    } else {
      cell.tileU0 = float(tileMinU);
      cell.tileV0 = float(tileMinV);
      cell.tileUSpan = float(tileMaxU - tileMinU + 1);
      cell.tileVSpan = float(tileMaxV - tileMinV + 1);
    }

    _pending.emplace(materialKey, promise.get_future().share());
  }

  // no locking from here down
  BakeInputs in;
  in.roughnessPath = roughnessPath;
  in.metallicPath = metallicPath;
  in.opacityPath = opacityPath;
  in.colorPath = colorPath;
  in.normalPath = normalPath;
  in.emissivePath = emissivePath;

  in.roughnessConst = roughnessConst;
  in.metallicConst = metallicConst;
  in.specularConst = specularConst;
  in.opacityConst = opacityConst;
  in.opacityThreshold = opacityThreshold;
  in.colorConst = colorConst;
  in.emissiveConst = emissiveConst;

  in.px0 = px0;
  in.py0 = py0;
  in.regionW = regionW;
  in.regionH = regionH;
  in.contentPx0 = contentPx0;
  in.contentPy0 = contentPy0;
  in.contentW = contentW;
  in.contentH = contentH;

  in.tileMinU = tileMinU;
  in.tileMinV = tileMinV;
  in.tileMaxU = tileMaxU;
  in.tileMaxV = tileMaxV;
  in.sources = sources;

  BakeRegion(in);
  cell.opacityThreshold = opacityThreshold;

  {
    std::lock_guard<std::mutex> lock(_mutex);
    _cells.emplace(materialKey, cell);
    _pending.erase(materialKey);
  }

  _dirty.store(true, std::memory_order_release);
  promise.set_value(cell);
  return cell;
}

int
HdAkariTextureAtlas::TakeBakedRegions()
{
  std::lock_guard<std::mutex> lock(_mutex);
  _uploading.clear();
  _uploading.swap(_baked);
  return int(_uploading.size());
}

HdAkariAtlasRegion
HdAkariTextureAtlas::BakedRegion(int i) const
{
  return _uploading[size_t(i)].rect;
}

uint8_t const *
HdAkariTextureAtlas::BakedPixels(int i, int atlas) const
{
  return _uploading[size_t(i)].pixels[atlas].data();
}

void
HdAkariTextureAtlas::ReleaseUploaded()
{
  std::vector<Baked>().swap(_uploading);
}

void
HdAkariTextureAtlas::BakeRegion(BakeInputs const &in)
{
  // each region bakes into its own buffers which are uploaded then freed, only the gpu holds the full atlas
  Baked baked;
  baked.rect = {in.px0, in.py0, in.regionW, in.regionH};

  const size_t bytes = size_t(in.regionW) * size_t(in.regionH) * 4;
  AssignMaterialPixels(baked.pixels[0], bytes);
  for (int i = 1; i < 4; ++i) baked.pixels[i].assign(bytes, uint8_t(0));

  uint8_t *material = baked.pixels[0].data();
  const int stride = in.regionW, x0 = in.contentPx0 - in.px0, y0 = in.contentPy0 - in.py0;

  BakeChannel(material, stride, x0, y0, in.contentW, in.contentH, /*r*/ 0, in.roughnessPath, in.roughnessConst,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV, in.sources.roughness);
  BakeChannel(material, stride, x0, y0, in.contentW, in.contentH, /*g*/ 1, in.metallicPath, in.metallicConst,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV, in.sources.metallic);
  BakeChannel(material, stride, x0, y0, in.contentW, in.contentH, /*b*/ 2, in.opacityPath, in.opacityConst,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV, in.sources.opacity);
  BakeChannel(material, stride, x0, y0, in.contentW, in.contentH, /*a*/ 3, std::string(), in.opacityThreshold,
              in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);

  BakeColorChannel(baked.pixels[1].data(), stride, true, x0, y0, in.contentW, in.contentH, in.colorPath, in.colorConst,
                   in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);
  BakeColorChannel(baked.pixels[2].data(), stride, false, x0, y0, in.contentW, in.contentH, in.normalPath,
                   GfVec3f(0.5f, 0.5f, 1.0f), in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);

  // the normal map's alpha is free, so a textured material keeps its facing reflectance there
  const float specularLevel = std::max({in.specularConst[0], in.specularConst[1], in.specularConst[2]});
  const uint8_t specularByte = uint8_t(std::clamp(std::lround(specularLevel * 255.0f), 0L, 255L));
  for (int y = 0; y < in.contentH; ++y) {
    for (int x = 0; x < in.contentW; ++x) {
      baked.pixels[2][(size_t(y0 + y) * stride + size_t(x0 + x)) * 4 + 3] = specularByte;
    }
  }

  // emission brighter than 1 keeps its scale in alpha and is read back as one over alpha
  GfVec3f emissive = in.emissiveConst;
  uint8_t emissiveAlpha = 255;
  const float peak = std::max(emissive[0], std::max(emissive[1], emissive[2]));
  if (in.emissivePath.empty() && peak > 1.0f) {
    emissiveAlpha = uint8_t(std::clamp(std::lround(255.0f / peak), 1L, 255L));
    emissive *= float(emissiveAlpha) / 255.0f;
  }

  BakeColorChannel(baked.pixels[3].data(), stride, true, x0, y0, in.contentW, in.contentH, in.emissivePath, emissive,
                   in.tileMinU, in.tileMinV, in.tileMaxU, in.tileMaxV);

  if (emissiveAlpha != 255) {
    for (int y = 0; y < in.contentH; ++y) {
      for (int x = 0; x < in.contentW; ++x) {
        baked.pixels[3][(size_t(y0 + y) * stride + size_t(x0 + x)) * 4 + 3] = emissiveAlpha;
      }
    }
  }

  // cut out texels take their nearest solid neighbor's color so filtering blends text into its own color rather than black
  if (!in.opacityPath.empty()) {
    DilateUnderAlpha(baked.pixels[0].data(), {baked.pixels[1].data(), baked.pixels[2].data(), baked.pixels[3].data()},
                     stride, x0, y0, in.contentW, in.contentH, 1 << kMaxMipLevel);
  }

  for (std::vector<uint8_t> &buffer : baked.pixels) {
    FillBorderRect(buffer.data(), stride, 0, 0, in.regionW, in.regionH, kCellPadding);
  }

  std::lock_guard<std::mutex> lock(_mutex);
  _baked.push_back(std::move(baked));
}

void
HdAkariTextureAtlas::WriteConstants(int index, GfVec3f const &color, float opacity, float roughness, float metallic,
                                    float opacityThreshold, GfVec3f const &emissive, GfVec3f const &specular)
{
  float *row = _constants.data() + size_t(index) * kConstantTexels * 4;
  const float values[kConstantTexels * 4] = {color[0], color[1], color[2], opacity,
                                             roughness, metallic, opacityThreshold, 0.0f,
                                             emissive[0], emissive[1], emissive[2], 0.0f,
                                             specular[0], specular[1], specular[2], 0.0f};

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
                                            GfVec3f const &emissive, GfVec3f const &specular)
{
  std::lock_guard<std::mutex> lock(_mutex);
  auto it = _constantIndex.find(materialKey);
  if (it == _constantIndex.end()) return false;

  // the ptex map id lives in the last constant slot and survives a rewrite
  const float ptexMap = _constants[size_t(it->second) * kConstantTexels * 4 + 11];
  WriteConstants(it->second, color, opacity, roughness, metallic, opacityThreshold, emissive, specular);
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
HdAkariTextureAtlas::BakeChannel(uint8_t *target, int stride, int px0, int py0, int regionW, int regionH,
                                 int channelIndex, std::string const &texPath, float fallbackConst,
                                 int tileMinU, int tileMinV, int tileMaxU, int tileMaxV, int sourceChannel)
{
  FillChannelRect(target, stride, px0, py0, regionW, regionH, channelIndex, fallbackConst);
  if (texPath.empty() || tileMinU == INT_MAX) return;

  const int spanU = tileMaxU - tileMinU + 1;
  const int spanV = tileMaxV - tileMinV + 1;

  for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
    for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
      std::string tilePath = AkariImaging::Atlas::resolveUdimTile(texPath, tu, tv);
      std::vector<float> srcPixels;
      int srcW = 0, srcH = 0, nComp = 0;
      if (!DecodeTile(tilePath, false, srcPixels, srcW, srcH, nComp)) continue;

      // an alpha read from a texture without one is opaque, so the constant stands
      if (sourceChannel >= nComp && nComp != 1) continue;

      const int subX0 = px0 + ((tu - tileMinU) * regionW) / spanU;
      const int subX1 = px0 + ((tu - tileMinU + 1) * regionW) / spanU;
      const int subY0 = py0 + ((tv - tileMinV) * regionH) / spanV;
      const int subY1 = py0 + ((tv - tileMinV + 1) * regionH) / spanV;
      const int subW = std::max(1, subX1 - subX0);
      const int subH = std::max(1, subY1 - subY0);

      AkariImaging::Atlas::bakeChannelTile(target, stride, srcPixels.data(),
                                           srcW, srcH, nComp,
                                           sourceChannel, channelIndex,
                                           subX0, subY0, subW, subH);
    }
  }
}

void
HdAkariTextureAtlas::BakeColorChannel(uint8_t *target, int stride, bool decodeSRGB,
                                      int px0, int py0, int regionW, int regionH,
                                      std::string const &texPath, GfVec3f const &fallbackConst,
                                      int tileMinU, int tileMinV, int tileMaxU, int tileMaxV)
{
  FillColorRect(target, stride, px0, py0, regionW, regionH, fallbackConst);
  if (texPath.empty() || tileMinU == INT_MAX) return;

  const int spanU = tileMaxU - tileMinU + 1;
  const int spanV = tileMaxV - tileMinV + 1;

  for (int tv = tileMinV; tv <= tileMaxV; ++tv) {
    for (int tu = tileMinU; tu <= tileMaxU; ++tu) {
      std::string tilePath = AkariImaging::Atlas::resolveUdimTile(texPath, tu, tv);
      std::vector<float> srcPixels;
      int srcW = 0, srcH = 0, nComp = 0;
      if (!DecodeTile(tilePath, decodeSRGB, srcPixels, srcW, srcH, nComp)) continue;

      const int subX0 = px0 + ((tu - tileMinU) * regionW) / spanU;
      const int subX1 = px0 + ((tu - tileMinU + 1) * regionW) / spanU;
      const int subY0 = py0 + ((tv - tileMinV) * regionH) / spanV;
      const int subY1 = py0 + ((tv - tileMinV + 1) * regionH) / spanV;
      const int subW = std::max(1, subX1 - subX0);
      const int subH = std::max(1, subY1 - subY0);

      AkariImaging::Atlas::bakeColorTile(target, stride,
                                         srcPixels.data(), srcW, srcH, nComp,
                                         subX0, subY0, subW, subH);
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
