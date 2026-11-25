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
#ifndef HDAKARI_RENDER_BUFFER_H
#define HDAKARI_RENDER_BUFFER_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Arch/swiftInterop.h>
# include <Hd/renderBuffer.h>
# include <Hgi/texture.h>
#else
# include <pxr/pxr.h>
# include <HdAkari/swiftInterop.h>
# include <pxr/imaging/hd/renderBuffer.h>
# include <pxr/imaging/hgi/texture.h>
#endif

#ifndef SWIFT_UNSAFE_REFERENCE
# if __has_include(<swift/bridging>)
#  include <swift/bridging>
# else
#  define SWIFT_UNSAFE_REFERENCE
# endif
#endif

#include "HdAkari/api.h"

#include <cstdint>

PXR_NAMESPACE_OPEN_SCOPE

class Hgi;

/// an aov render target backed by an hgi texture, shared with the swift engine and hydra's present tasks
class SWIFT_UNSAFE_REFERENCE HdAkariRenderBuffer final : public HdRenderBuffer
{
 public:
  HDAKARI_API
  explicit HdAkariRenderBuffer(SdfPath const &id);

  HDAKARI_API
  ~HdAkariRenderBuffer() override;

  HDAKARI_API
  void Sync(HdSceneDelegate *sceneDelegate,
            HdRenderParam *renderParam,
            HdDirtyBits *dirtyBits) override;

  HDAKARI_API
  bool Allocate(GfVec3i const &dimensions, HdFormat format,
                bool multiSampled) override;

  unsigned int GetWidth() const override { return _width; }
  unsigned int GetHeight() const override { return _height; }
  unsigned int GetDepth() const override { return 1; }
  HdFormat GetFormat() const override { return _format; }
  bool IsMultiSampled() const override { return _multiSampled; }

  // gpu resident only, there is no cpu staging path yet
  void *Map() override { return nullptr; }
  void Unmap() override {}
  bool IsMapped() const override { return false; }
  bool IsConverged() const override { return true; }
  void Resolve() override {}

  HDAKARI_API
  VtValue GetResource(bool multiSampled) const override;

  /// the raw `HgiTexture` the swift engine renders into, null until `Allocate` runs
  HDAKARI_API
  void *GetHgiTexture() const;

  /// the hgi texture handle the command recorders bind as an attachment, invalid until `Allocate` runs
  HgiTextureHandle const &GetTextureHandle() const { return _texture; }

  /// adopts an externally wrapped texture as the aov, hgi owns the handle but its creator keeps the metal object
  HDAKARI_API
  void SetWrappedTexture(HgiTextureHandle const &wrapped, uint64_t rawResource);

  /// whether the aov texture already wraps `rawResource`
  bool Wraps(uint64_t rawResource) const { return _wrappedResource == rawResource; }

  /// maps an `HdFormat` to an `HgiFormat` for the aovs akari produces
  HDAKARI_API
  static HgiFormat ToHgiFormat(HdFormat format);

 protected:
  HDAKARI_API
  void _Deallocate() override;

 private:
  Hgi *_hgi = nullptr; // shared, not owned

  HgiTextureHandle _texture;
  uint64_t _wrappedResource = 0;

  unsigned int _width = 0;
  unsigned int _height = 0;
  HdFormat _format = HdFormatInvalid;
  bool _multiSampled = false;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_RENDER_BUFFER_H
