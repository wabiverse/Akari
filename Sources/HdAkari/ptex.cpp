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
# include <Gf/vec3f.h>
# include <Vt/array.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/vt/array.h>
#endif

#include "HdAkari/ptex.h"

#include <Ptexture.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <memory>
#include <mutex>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

float Linear(float c)
{
  return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
}

/// Max texture files the cache can hold open. Capped at 256 (or 25% of the system limit)
/// to leave room for background threads and prevent "too many open files" crashes.
int PtexOpenFiles()
{
  struct rlimit limit{};
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0 || limit.rlim_cur == RLIM_INFINITY)
  {
    return 256;
  }
  const long long soft = static_cast<long long>(limit.rlim_cur);
  return int(std::clamp<long long>(soft / 4, 16, 256));
}

/// The face averages and the streamed tiles share it, the files open at
/// once and their decoded data, a small share of the machine's memory.
PtexCache *Cache()
{
  static PtexCache *cache = [] {
    const int files = PtexOpenFiles();
    if (files < 256)
    {
      std::fprintf(stderr, "HdAkari: ptex keeps %d files open, the process's file limit is low\n", files);
    }
    return PtexCache::create(
        files,
        size_t(std::max<long long>((long long)sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGE_SIZE) / 64, 128ll << 20)));
  }();
  return cache;
}

struct Map
{
  VtIntArray res;
  GfVec3f average = GfVec3f(1.0f);
  int id = -1;
};

/// Releases a Ptex texture when the scope ends, however it ends.
struct TextureHold
{
  PtexTexture *texture;
  explicit TextureHold(PtexTexture *texture) : texture(texture) {}
  ~TextureHold()
  {
    if (texture) texture->release();
  }
  TextureHold(TextureHold const &) = delete;
  TextureHold &operator=(TextureHold const &) = delete;
};

std::mutex mapMutex;
std::unordered_map<std::string, Map> maps;
std::vector<std::string> mapPaths;

/// Lock the cache lookup so threads check one at a time to prevent
/// duplicate file counts that break the cache's tracking and cause
/// file limit crashes.
std::mutex cacheMutex;

Map const &LoadMap(std::string const &path)
{
  {
    std::lock_guard<std::mutex> lock(mapMutex);
    const auto found = maps.find(path);
    if (found != maps.end()) return found->second;
  }

  Map map;
  bool streams = false;
  Ptex::String error;
  // use a standalone reader to load and immediately close metadata files,
  // which avoids clogging the streaming cache with thousands of open file
  // handles.
  if (PtexTexture *texture = PtexTexture::open(path.c_str(), error)) {
    TextureHold hold(texture);
    const int channels = std::min(texture->numChannels(), 3);
    const int faces = std::max(texture->numFaces(), 0);
    map.res = VtIntArray(size_t(faces));
    for (int f = 0; f < faces; ++f) {
      Ptex::Res const &stored = texture->getFaceInfo(f).res;
      map.res[size_t(f)] = stored.ulog2 | stored.vlog2 << 4;
    }
    // the faces stream, what stands in for them until then is the map's average, from
    // up to a few thousand faces single texel levels.
    GfVec3f sum(0.0f);
    int sampled = 0;
    for (int f = 0; f < faces && channels > 0; f += std::max(faces / 4096, 1), ++sampled) {
      float texel[3] = {0.0f, 0.0f, 0.0f};
      texture->getPixel(f, 0, 0, texel, 0, channels, Ptex::Res(0, 0));
      for (int c = 0; c < 3; ++c) sum[c] += Linear(texel[std::min(c, channels - 1)]);
    }
    if (sampled > 0) map.average = sum / float(sampled);
    streams = channels > 0 && texture->numChannels() <= 4 && texture->meshType() == Ptex::mt_quad &&
              texture->numFaces() <= (1 << HdAkariPtexFaceBits);
  } else {
    std::fprintf(stderr, "HdAkari: can't read Ptex %s: %s\n", path.c_str(), error.c_str());
  }

  std::lock_guard<std::mutex> lock(mapMutex);
  auto [it, inserted] = maps.emplace(path, map);
  // the key holds map + 1 in 13 bits.
  if (inserted && streams && mapPaths.size() + 1 < (1u << 13)) {
    it->second.id = int(mapPaths.size());
    mapPaths.push_back(path);
  }
  return it->second;
}

/// One face's texels at one resolution, read as 8 bit rgba.
struct Texels
{
  PtexFaceData *data;
  Ptex::DataType type;
  int channels, width, height;

  Texels(PtexTexture *texture, int face, Ptex::Res res)
      : data(texture->getData(face, res)), type(texture->dataType()), channels(texture->numChannels()),
        width(res.u()), height(res.v())
  {
  }
  ~Texels()
  {
    if (data) data->release();
  }

  uint32_t Read(int u, int v) const
  {
    if (!data) return 0xFF000000u;
    uint8_t raw[64];
    data->getPixel(std::clamp(u, 0, width - 1), std::clamp(v, 0, height - 1), raw);
    uint8_t c[3];
    if (type == Ptex::dt_uint8) {
      for (int k = 0; k < 3; ++k) c[k] = raw[std::min(k, channels - 1)];
    } else {
      float f[4];
      Ptex::ConvertToFloat(f, raw, type, channels);
      for (int k = 0; k < 3; ++k) c[k] = uint8_t(std::clamp(f[std::min(k, channels - 1)], 0.0f, 1.0f) * 255.0f + 0.5f);
    }
    return uint32_t(c[0]) | uint32_t(c[1]) << 8 | uint32_t(c[2]) << 16 | 0xFF000000u;
  }
};

struct Tile
{
  uint64_t key = 0;
  uint32_t size = 0;
  std::vector<uint32_t> texels;
};

void Decode(Tile &tile)
{
  const uint32_t a = uint32_t(tile.key >> 32), b = uint32_t(tile.key);
  const int map = int(a >> HdAkariPtexFaceBits) - 1, face = int(a & ((1u << HdAkariPtexFaceBits) - 1));
  const int level = int(b >> 16), index = int(b & 0xFFFF);
  std::string path;
  {
    std::lock_guard<std::mutex> lock(mapMutex);
    if (map < 0 || size_t(map) >= mapPaths.size()) return;
    path = mapPaths[size_t(map)];
  }
  Ptex::String error;
  PtexTexture *texture = nullptr;
  {
    std::lock_guard<std::mutex> lock(cacheMutex);
    texture = Cache()->get(path.c_str(), error);
  }
  if (!texture) return;
  // released after the faces' data it hands out.
  TextureHold hold(texture);
  if (face >= texture->numFaces()) return;
  Ptex::FaceInfo const &info = texture->getFaceInfo(face);
  const Ptex::Res res(std::max(info.res.ulog2 - level, 0), std::max(info.res.vlog2 - level, 0));
  const int w = res.u(), h = res.v();
  const int tw = std::min(w, HdAkariPtexTileSize), th = std::min(h, HdAkariPtexTileSize);
  const int columns = w / tw, tx = index % columns, ty = index / columns;
  if (ty >= h / th) return;

  const Texels own(texture, face, res);
  std::unique_ptr<Texels> neighbours[4];
  int neighbourEdges[4] = {0, 0, 0, 0};
  // a texel past the face's edge comes from the face across it, at the resolution
  // whose texels along that edge match this level's.
  auto beyond = [&](int gx, int gy) -> uint32_t {
    const int cx = std::clamp(gx, 0, w - 1), cy = std::clamp(gy, 0, h - 1);
    int edge;
    float t;
    if (gy < 0) { edge = 0; t = (float(cx) + 0.5f) / float(w); }
    else if (gy >= h) { edge = 2; t = 1.0f - (float(cx) + 0.5f) / float(w); }
    else if (gx >= w) { edge = 1; t = (float(cy) + 0.5f) / float(h); }
    else { edge = 3; t = 1.0f - (float(cy) + 0.5f) / float(h); }
    const int adj = info.adjface(edge);
    if (adj < 0 || adj >= texture->numFaces()) return own.Read(cx, cy);
    if (!neighbours[edge]) {
      Ptex::FaceInfo const &other = texture->getFaceInfo(adj);
      const int adjEdge = info.adjedge(edge);
      const int along = edge & 1 ? res.vlog2 : res.ulog2;
      const int adjAlong = adjEdge & 1 ? other.res.vlog2 : other.res.ulog2;
      const int drop = adjAlong - std::min(along, adjAlong);
      neighbours[edge] = std::make_unique<Texels>(
          texture, adj, Ptex::Res(std::max(other.res.ulog2 - drop, 0), std::max(other.res.vlog2 - drop, 0)));
      neighbourEdges[edge] = adjEdge;
    }
    Texels const &n = *neighbours[edge];
    // the shared edge runs the other way round the neighbour.
    const float s = 1.0f - t;
    switch (neighbourEdges[edge]) {
      case 0: return n.Read(int(s * float(n.width)), 0);
      case 1: return n.Read(n.width - 1, int(s * float(n.height)));
      case 2: return n.Read(int((1.0f - s) * float(n.width)), n.height - 1);
      default: return n.Read(0, int((1.0f - s) * float(n.height)));
    }
  };

  tile.texels.resize(size_t(tw + 2) * size_t(th + 2));
  uint32_t *dst = tile.texels.data();
  for (int y = -1; y <= th; ++y) {
    for (int x = -1; x <= tw; ++x) {
      const int gx = tx * tw + x, gy = ty * th + y;
      *dst++ = gx >= 0 && gx < w && gy >= 0 && gy < h ? own.Read(gx, gy) : beyond(gx, gy);
    }
  }
  tile.size = uint32_t(tw) | uint32_t(th) << 16;
}

struct Streamer
{
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<uint64_t> queue;
  std::unordered_set<uint64_t> waiting;
  std::deque<Tile> done;
  int busy = 0;

  Streamer()
  {
    const int threads = std::clamp(int(std::thread::hardware_concurrency()) / 2, 2, 4);
    for (int i = 0; i < threads; ++i) std::thread([this] { Work(); }).detach();
  }

  void Work()
  {
    for (;;) {
      Tile tile;
      {
        std::unique_lock<std::mutex> lock(mutex);
        // decoded tiles wait on the frame to take them, past a few frames worth the decoding waits too.
        wake.wait(lock, [this] { return !queue.empty() && done.size() < 2048; });
        // the newest requests are what's on screen now.
        tile.key = queue.back();
        queue.pop_back();
        ++busy;
      }
      Decode(tile);
      std::lock_guard<std::mutex> lock(mutex);
      --busy;
      if (tile.size != 0) done.push_back(std::move(tile));
      else waiting.erase(tile.key);
    }
  }
};

Streamer &TheStreamer()
{
  static Streamer *streamer = new Streamer();
  return *streamer;
}

} // namespace

GfVec3f HdAkariPtexAverageColor(std::string const &path)
{
  return LoadMap(path).average;
}

VtIntArray HdAkariPtexFaceRes(std::string const &path)
{
  return LoadMap(path).res;
}

int HdAkariPtexMapId(std::string const &path)
{
  return LoadMap(path).id;
}

void HdAkariPtexRequestTiles(uint64_t const *keys, int count)
{
  Streamer &streamer = TheStreamer();
  std::lock_guard<std::mutex> lock(streamer.mutex);
  for (int i = 0; i < count; ++i) {
    if (streamer.waiting.insert(keys[i]).second) streamer.queue.push_back(keys[i]);
  }
  // past a few frames of requests, the oldest are off screen.
  while (streamer.queue.size() > 16384) {
    streamer.waiting.erase(streamer.queue.front());
    streamer.queue.pop_front();
  }
  streamer.wake.notify_all();
}

int HdAkariPtexTakeTiles(uint64_t *keys, uint32_t *sizes, uint32_t *offsets, uint32_t *texels, int maxTiles,
                         int maxTexels)
{
  Streamer &streamer = TheStreamer();
  std::lock_guard<std::mutex> lock(streamer.mutex);
  int taken = 0, used = 0;
  while (taken < maxTiles && !streamer.done.empty()) {
    Tile &tile = streamer.done.front();
    const int count = int(tile.texels.size());
    if (used + count > maxTexels) break;
    keys[taken] = tile.key;
    sizes[taken] = tile.size;
    offsets[taken] = uint32_t(used);
    std::copy(tile.texels.begin(), tile.texels.end(), texels + used);
    used += count;
    streamer.waiting.erase(tile.key);
    streamer.done.pop_front();
    ++taken;
  }
  if (taken > 0) streamer.wake.notify_all();
  return taken;
}

int HdAkariPtexPendingTiles()
{
  Streamer &streamer = TheStreamer();
  std::lock_guard<std::mutex> lock(streamer.mutex);
  return int(streamer.queue.size() + streamer.done.size()) + streamer.busy;
}

PXR_NAMESPACE_CLOSE_SCOPE
