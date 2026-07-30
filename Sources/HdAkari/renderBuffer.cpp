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
#include "HdAkari/renderBuffer.h"
#include "HdAkari/renderParam.h"

#include <Hgi/hgiImpl.h>
#include <Hgi/texture.h>

PXR_NAMESPACE_OPEN_SCOPE

HdAkariRenderBuffer::HdAkariRenderBuffer(SdfPath const &id)
  : HdRenderBuffer(id)
{}

HgiFormat
HdAkariRenderBuffer::ToHgiFormat(HdFormat format)
{
  // minimal HdFormat -> HgiFormat for the AOVs Akari currently produces.
  switch (format) {
    case HdFormatUNorm8Vec4:   return HgiFormatUNorm8Vec4;
    case HdFormatFloat16Vec4:  return HgiFormatFloat16Vec4;
    case HdFormatFloat32Vec4:  return HgiFormatFloat32Vec4;
    case HdFormatFloat32:      return HgiFormatFloat32;
    case HdFormatInt32:        return HgiFormatInt32;  // primId / instanceId AOVs
    default:                   return HgiFormatFloat16Vec4;
  }
}

HdAkariRenderBuffer::~HdAkariRenderBuffer() = default;

void
HdAkariRenderBuffer::Sync(HdSceneDelegate *sceneDelegate,
                          HdRenderParam *renderParam,
                          HdDirtyBits *dirtyBits)
{
  // capture the shared Hgi so Allocate can build the texture.
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    _hgi = param->GetHgi();
  }
  HdRenderBuffer::Sync(sceneDelegate, renderParam, dirtyBits);
}

bool
HdAkariRenderBuffer::Allocate(GfVec3i const &dimensions, HdFormat format,
                              bool multiSampled)
{
  _Deallocate();
  _width = static_cast<unsigned int>(dimensions[0]);
  _height = static_cast<unsigned int>(dimensions[1]);
  _format = format;
  _multiSampled = multiSampled;

  if (!_hgi || _width == 0 || _height == 0) {
    return false;
  }

  HgiTextureDesc desc;
  desc.debugName = "HdAkari AOV";
  desc.dimensions = GfVec3i(dimensions[0], dimensions[1], 1);
  desc.format = ToHgiFormat(format);
  desc.layerCount = 1;
  desc.mipLevels = 1;
  desc.sampleCount = HgiSampleCount1;
  const bool isDepth = (format == HdFormatFloat32);
  desc.usage = (isDepth ? HgiTextureUsageBitsDepthTarget
                        : HgiTextureUsageBitsColorTarget) |
               HgiTextureUsageBitsShaderRead;
  _texture = _hgi->CreateTexture(desc);
  return bool(_texture);
}

VtValue
HdAkariRenderBuffer::GetResource(bool /*multiSampled*/) const
{
  return VtValue(_texture);
}

void *
HdAkariRenderBuffer::GetHgiTexture() const
{
  return _texture ? static_cast<void *>(_texture.Get()) : nullptr;
}

void
HdAkariRenderBuffer::SetWrappedTexture(HgiTextureHandle const &wrapped)
{
  if (!wrapped || !_hgi) {
    return;
  }
  if (_hgi && _texture) {
    _hgi->DestroyTexture(&_texture);
  }
  _texture = wrapped;
}

void
HdAkariRenderBuffer::_Deallocate()
{
  if (_hgi && _texture) {
    _hgi->DestroyTexture(&_texture);
  }
  _texture = HgiTextureHandle();
  _width = _height = 0;
  _format = HdFormatInvalid;
}

PXR_NAMESPACE_CLOSE_SCOPE
