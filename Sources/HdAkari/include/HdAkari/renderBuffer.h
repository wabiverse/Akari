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

#include <pxr/pxrns.h>
#include <Hd/renderBuffer.h>
#include <Hgi/texture.h>

#include "HdAkari/api.h"

PXR_NAMESPACE_OPEN_SCOPE

class Hgi;

/// @class HdAkariRenderBuffer
///
/// An AOV render target backed by an Hgi texture, shared with
/// the Swift engine (which renders into it) and with Hydra's
/// present / compositing tasks.
///
class HdAkariRenderBuffer final : public HdRenderBuffer
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

  // GPU resident only, no CPU staging path yet.
  void *Map() override { return nullptr; }
  void Unmap() override {}
  bool IsMapped() const override { return false; }
  bool IsConverged() const override { return true; }
  void Resolve() override {}

  HDAKARI_API
  VtValue GetResource(bool multiSampled) const override;

  /// Raw `HgiTexture` for the Swift engine to render
  /// into (may be null until Allocate runs).
  HDAKARI_API
  void *GetHgiTexture() const;

  /// The Hgi texture handle (with its id). What the Hgi command
  /// recorders bind as a render target attachment. Invalid until
  /// Allocate runs.
  HgiTextureHandle const &GetTextureHandle() const { return _texture; }

  /// Adopt an externally-wrapped texture as the AOV texture
  /// (e.g. LabGL's final color buffer wrapped by HgiMetal's
  /// raw resource factory). The buffer takes over Hgi ownership
  /// of the passed handle, the Metal object itself remains owned
  /// by its creator, so it is not destroyed here. No-op if the
  /// passed value of `wrapped` is invalid or Sync has not captured
  /// he Hgi yet.
  HDAKARI_API
  void SetWrappedTexture(HgiTextureHandle const &wrapped);

  /// Minimal HdFormat -> HgiFormat mapping for the AOVs Akari produces.
  HDAKARI_API
  static HgiFormat ToHgiFormat(HdFormat format);

 protected:
  HDAKARI_API
  void _Deallocate() override;

 private:
  Hgi *_hgi = nullptr; // shared, not owned
  HgiTextureHandle _texture;
  unsigned int _width = 0;
  unsigned int _height = 0;
  HdFormat _format = HdFormatInvalid;
  bool _multiSampled = false;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_RENDER_BUFFER_H
