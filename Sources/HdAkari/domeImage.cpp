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
# include <Gf/half.h>
# include <Hio/image.h>
# include <Hio/types.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/half.h>
# include <pxr/imaging/hio/image.h>
# include <pxr/imaging/hio/types.h>
#endif

#include <algorithm>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <future>
#include <mutex>
#include <thread>

#include "HdAkari/domeImage.h"

PXR_NAMESPACE_OPEN_SCOPE

namespace {

float Component(uint8_t const *p, HioType type, int c)
{
  switch (type)
  {
    case HioTypeFloat: { float f; std::memcpy(&f, p + c * 4, 4); return f; }
    case HioTypeHalfFloat: { GfHalf h; h.setBits(reinterpret_cast<uint16_t const *>(p)[c]); return float(h); }
    case HioTypeUnsignedByte: return p[c] / 255.0f;
    case HioTypeUnsignedShort: return reinterpret_cast<uint16_t const *>(p)[c] / 65535.0f;
    default: return 0.0f;
  }
}

HdAkariDomeImage *Load(std::string const &path, int smallWidth, float sunThreshold, float *progress);

struct Prefetch
{
  std::string path;
  int smallWidth = 0;
  float sunThreshold = 0.0f;
  std::shared_future<HdAkariDomeImage *> image;
};

std::mutex prefetchMutex;
Prefetch prefetch;

} // namespace

void
HdAkariPrefetchDomeImage(std::string const &path, int smallWidth, float sunThreshold)
{
  std::lock_guard<std::mutex> lock(prefetchMutex);
  if (path.empty() || (prefetch.path == path && prefetch.smallWidth == smallWidth && prefetch.sunThreshold == sunThreshold)) return;
  if (prefetch.image.valid()) std::thread([image = prefetch.image] { HdAkariFreeDomeImage(image.get()); }).detach();
  prefetch = {path, smallWidth, sunThreshold,
              std::async(std::launch::async, [=] { return Load(path, smallWidth, sunThreshold, nullptr); }).share()};
}

HdAkariDomeImage *
HdAkariLoadDomeImage(std::string const &path, int smallWidth, float sunThreshold, float *progress)
{
  std::shared_future<HdAkariDomeImage *> image;
  {
    std::lock_guard<std::mutex> lock(prefetchMutex);
    if (prefetch.path == path && prefetch.smallWidth == smallWidth && prefetch.sunThreshold == sunThreshold) {
      image = std::move(prefetch.image);
      prefetch = {};
    }
  }
  return image.valid() ? image.get() : Load(path, smallWidth, sunThreshold, progress);
}

namespace {

HdAkariDomeImage *
Load(std::string const &path, int smallWidth, float sunThreshold, float *progress)
{
  HioImageSharedPtr image = HioImage::OpenForReading(path, 0, 0, HioImage::SourceColorSpace::Raw);
  if (!image) return nullptr;
  const int w = image->GetWidth();
  const int h = image->GetHeight();
  const HioFormat format = image->GetFormat();
  const int comps = HioGetComponentCount(format);
  const HioType type = HioGetHioType(format);
  const size_t compBytes = HioGetDataSizeOfType(type);
  if (w <= 0 || h <= 0 || comps <= 0 || compBytes == 0) return nullptr;

  std::vector<uint8_t> raw(size_t(w) * size_t(h) * size_t(comps) * compBytes);
  HioImage::StorageSpec spec;
  spec.width = w;
  spec.height = h;
  spec.depth = 1;
  spec.format = format;
  spec.flipped = false;
  spec.data = raw.data();
  if (!image->Read(spec)) return nullptr;

  // Past this the dome is box filtered down by a whole factor.
  int maxWidth = 4096;
  if (const char *env = std::getenv("AKARI_DOME_MAX_WIDTH")) maxWidth = std::max(1, std::atoi(env));
  const int f = std::max(1, (w + maxWidth - 1) / maxWidth);
  const int ow = std::max(1, w / f), oh = std::max(1, h / f);
  std::vector<float> row(size_t(ow) * 3, 0.0f);

  auto *out = new HdAkariDomeImage;
  out->width = ow;
  out->height = oh;
  out->pixels.resize(size_t(ow) * size_t(oh) * 4);

  const int sw = std::max(1, smallWidth);
  const int sh = std::max(1, sw / 2);

  double sunDir[3] = {0, 0, 0}, sunE[3] = {0, 0, 0};
  const double pi = 3.14159265358979;
  const size_t texelBytes = size_t(comps) * compBytes;
  for (int y = 0; y < h; ++y)
  {
    if (progress && (y & 63) == 0) *progress = 0.25f + 0.7f * float(y) / float(h);
    const double theta = pi * (y + 0.5) / h;
    const double omega = (2.0 * pi / w) * (pi / h) * std::sin(theta);
    for (int x = 0; x < w; ++x)
    {
      uint8_t const *p = raw.data() + (size_t(y) * w + x) * texelBytes;
      float rgb[3];
      for (int c = 0; c < 3; ++c) rgb[c] = Component(p, type, std::min(c, comps - 1));
      if (x / f < ow)
      {
        for (int c = 0; c < 3; ++c) row[size_t(x / f) * 3 + c] += rgb[c];
      }

      if (sunThreshold > 0.0f)
      {
        const float lum = 0.2126f * rgb[0] + 0.7152f * rgb[1] + 0.0722f * rgb[2];
        if (lum > sunThreshold)
        {
          const double k = (lum - sunThreshold) / lum * omega;
          const double a = 2.0 * pi * (x + 0.5) / w - 0.5 * pi;
          const double d[3] = { std::sin(theta) * std::cos(a), std::cos(theta), std::sin(theta) * std::sin(a) };
          for (int c = 0; c < 3; ++c)
          {
            sunE[c] += rgb[c] * k;
            sunDir[c] += d[c] * (lum - sunThreshold) * omega;
          }
        }
      }
    }
    if (y % f == f - 1 && y / f < oh)
    {
      const float n = float(f * f);
      for (int ox = 0; ox < ow; ++ox)
      {
        uint16_t *dst = out->pixels.data() + (size_t(y / f) * ow + ox) * 4;
        for (int c = 0; c < 3; ++c) dst[c] = GfHalf(row[size_t(ox) * 3 + c] / n).bits();
        dst[3] = GfHalf(1.0f).bits();
      }
      std::fill(row.begin(), row.end(), 0.0f);
    }
  }
  raw = std::vector<uint8_t>();

  const double len = std::sqrt(sunDir[0] * sunDir[0] + sunDir[1] * sunDir[1] + sunDir[2] * sunDir[2]);
  if (len > 0.0)
  {
    out->hasSun = true;
    out->sunX = float(sunDir[0] / len); out->sunY = float(sunDir[1] / len); out->sunZ = float(sunDir[2] / len);
    out->sunR = float(sunE[0]); out->sunG = float(sunE[1]); out->sunB = float(sunE[2]);
  }

  out->smallWidth = sw;
  out->smallHeight = sh;
  out->small.resize(size_t(sw) * size_t(sh) * 4);
  for (int sy = 0; sy < sh; ++sy)
  {
    const int y0 = sy * oh / sh, y1 = std::max(y0 + 1, (sy + 1) * oh / sh);
    for (int sx = 0; sx < sw; ++sx)
    {
      const int x0 = sx * ow / sw, x1 = std::max(x0 + 1, (sx + 1) * ow / sw);
      float sum[3] = {0, 0, 0};
      for (int y = y0; y < y1; ++y)
      {
        for (int x = x0; x < x1; ++x)
        {
          uint16_t const *p = out->pixels.data() + (size_t(y) * ow + x) * 4;
          float rgb[3];
          for (int c = 0; c < 3; ++c) { GfHalf v; v.setBits(p[c]); rgb[c] = float(v); }
          const float lum = 0.2126f * rgb[0] + 0.7152f * rgb[1] + 0.0722f * rgb[2];
          const float k = sunThreshold > 0.0f && lum > sunThreshold ? sunThreshold / lum : 1.0f;
          for (int c = 0; c < 3; ++c) sum[c] += rgb[c] * k;
        }
      }
      const float n = float((y1 - y0) * (x1 - x0));
      uint16_t *d = out->small.data() + (size_t(sy) * sw + sx) * 4;
      for (int c = 0; c < 3; ++c) d[c] = GfHalf(sum[c] / n).bits();
      d[3] = GfHalf(1.0f).bits();
    }
  }
  return out;
}

} // namespace

void
HdAkariFreeDomeImage(HdAkariDomeImage *image)
{
  delete image;
}

PXR_NAMESPACE_CLOSE_SCOPE
