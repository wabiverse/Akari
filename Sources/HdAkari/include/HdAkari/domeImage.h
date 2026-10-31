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

#ifndef HDAKARI_DOME_IMAGE_H
#define HDAKARI_DOME_IMAGE_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
#else
# include <pxr/pxr.h>
#endif

#include "HdAkari/api.h"

#include <cstdint>
#include <string>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

/// A dome light's latlong image as half float RGBA, top row first, plus a
/// box filtered copy small enough to bake the environment cube from.
struct HdAkariDomeImage
{
  int width = 0;
  int height = 0;
  std::vector<uint16_t> pixels;
  int smallWidth = 0;
  int smallHeight = 0;
  std::vector<uint16_t> small;
  /// Sun extraction as radiance over the threshold, toward its energy
  /// weighted direction (dome space) with its summed irradiance.
  bool hasSun = false;
  float sunX = 0.0f, sunY = 1.0f, sunZ = 0.0f;
  float sunR = 0.0f, sunG = 0.0f, sunB = 0.0f;
};

/// Reads `path`, nullptr when it can't, free it with HdAkariFreeDomeImage.
HDAKARI_API
HdAkariDomeImage *HdAkariLoadDomeImage(std::string const &path, int smallWidth, float sunThreshold,
                                       float *progress);

HDAKARI_API
void HdAkariFreeDomeImage(HdAkariDomeImage *image);

/// The size and sun threshold the renderer loads domes with.
constexpr int HdAkariDomeSmallWidth = 1024;
constexpr float HdAkariDomeSunThreshold = 10.0f;

/// Starts reading `path` in the background for the next HdAkariLoadDomeImage of it.
HDAKARI_API
void HdAkariPrefetchDomeImage(std::string const &path, int smallWidth, float sunThreshold);

inline int HdAkariDomeImageWidth(HdAkariDomeImage const *image) { return image->width; }
inline int HdAkariDomeImageHeight(HdAkariDomeImage const *image) { return image->height; }
inline uint16_t const *HdAkariDomeImagePixels(HdAkariDomeImage const *image) { return image->pixels.data(); }
inline int HdAkariDomeImageSmallWidth(HdAkariDomeImage const *image) { return image->smallWidth; }
inline int HdAkariDomeImageSmallHeight(HdAkariDomeImage const *image) { return image->smallHeight; }
inline uint16_t const *HdAkariDomeImageSmall(HdAkariDomeImage const *image) { return image->small.data(); }
inline bool HdAkariDomeImageHasSun(HdAkariDomeImage const *image) { return image->hasSun; }
inline float HdAkariDomeImageSun(HdAkariDomeImage const *image, int i)
{
  float const v[6] = { image->sunX, image->sunY, image->sunZ, image->sunR, image->sunG, image->sunB };
  return v[i];
}

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_DOME_IMAGE_H
