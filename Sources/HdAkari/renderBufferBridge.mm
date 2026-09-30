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
# include <Hgi/texture.h>
# include <HgiMetal/hgi.h>
# include <HgiMetal/texture.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hgi/texture.h>
# include <pxr/imaging/hgiMetal/hgi.h>
# include <pxr/imaging/hgiMetal/texture.h>
#endif

#include "HdAkari/renderBufferBridge.h"

#include <cstdint>
#include <cstdio>
#include <mutex>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

const char *const kWriteIdsSource = R"(
#include <metal_stdlib>
using namespace metal;

kernel void akariWriteIds(texture2d<float> position [[texture(0)]],
                          texture2d<float> normal [[texture(1)]],
                          texture2d<int, access::write> primId [[texture(2)]],
                          texture2d<int, access::write> instanceId [[texture(3)]],
                          texture2d<float, access::write> depth [[texture(4)]],
                          constant float2 &projection [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
  if (gid.x >= primId.get_width() || gid.y >= primId.get_height()) { return; }
  uint2 src = min(gid, uint2(position.get_width(), position.get_height()) - 1u);
  bool hit = normal.read(src).a >= 0.5;
  float4 p = position.read(src);
  float ndc = (projection.x * p.z + projection.y) / max(-p.z, 1e-6);
  primId.write(int4(hit ? int(round(p.w)) : -1), gid);
  instanceId.write(int4(-1), gid);
  depth.write(float4(hit ? clamp(ndc * 0.5 + 0.5, 0.0, 0.999999) : 1.0), gid);
}
)";

id<MTLComputePipelineState> WriteIdsPipeline(id<MTLDevice> device)
{
  static id<MTLComputePipelineState> pipeline = nil;
  static std::once_flag once;
  std::call_once(once, [&] {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:kWriteIdsSource]
                                                  options:nil
                                                    error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"akariWriteIds"];
    pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
    if (!pipeline) {
      std::fprintf(stderr, "HdAkari: id AOV kernel failed: %s\n",
                   error ? error.localizedDescription.UTF8String : "unknown");
    }
  });
  return pipeline;
}

id<MTLTexture> MetalTexture(HdAkariRenderBuffer *renderBuffer)
{
  auto *texture = renderBuffer
    ? static_cast<HgiMetalTexture *>(static_cast<HgiTexture *>(renderBuffer->GetHgiTexture()))
    : nullptr;
  return texture ? texture->GetTextureId() : nil;
}

} // namespace

void
AkariRenderBufferSetExternalTexture(HdAkariRenderBuffer *renderBuffer,
                                    HgiMetal *hgi,
                                    uint64_t rawResource)
{
  if (!renderBuffer || !hgi || rawResource == 0) {
    return;
  }

  // the wrap is described from the AOV's own dims/format, so the creator's
  // texture must match the AOV descriptor (Float16Vec4 color, Float32 depth).
  HgiTextureDesc desc;
  desc.debugName = "HdAkari AOV (external)";
  desc.dimensions = GfVec3i((int)renderBuffer->GetWidth(), (int)renderBuffer->GetHeight(), 1);
  desc.format = HdAkariRenderBuffer::ToHgiFormat(renderBuffer->GetFormat());
  desc.layerCount = 1;
  desc.mipLevels = 1;
  desc.sampleCount = HgiSampleCount1;
  const bool isDepth = (renderBuffer->GetFormat() == HdFormatFloat32);
  desc.usage = (isDepth ? HgiTextureUsageBitsDepthTarget
                        : HgiTextureUsageBitsColorTarget) | HgiTextureUsageBitsShaderRead;
  
  renderBuffer->SetWrappedTexture(hgi->CreateExternalTexture(desc, rawResource));
}

void
AkariRenderBuffersWriteIds(HdAkariRenderBuffer *primId,
                           HdAkariRenderBuffer *instanceId,
                           HdAkariRenderBuffer *depth,
                           HgiMetal *hgi,
                           uint64_t position,
                           uint64_t normal,
                           float projectionZ,
                           float projectionW)
{
  id<MTLTexture> primTex = MetalTexture(primId);
  id<MTLTexture> instanceTex = MetalTexture(instanceId);
  id<MTLTexture> depthTex = MetalTexture(depth);
  if (!hgi || !primTex || !instanceTex || !depthTex || position == 0 || normal == 0) {
    return;
  }

  id<MTLComputePipelineState> pipeline = WriteIdsPipeline(hgi->GetPrimaryDevice());
  id<MTLCommandBuffer> commandBuffer = [hgi->GetQueue() commandBuffer];
  if (!pipeline || !commandBuffer) {
    return;
  }

  // on hydra's queue, so it lands after LabGL's frame and before the view reads it.
  id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
  [encoder setComputePipelineState:pipeline];
  [encoder setTexture:(__bridge id<MTLTexture>)(void *)position atIndex:0];
  [encoder setTexture:(__bridge id<MTLTexture>)(void *)normal atIndex:1];
  [encoder setTexture:primTex atIndex:2];
  [encoder setTexture:instanceTex atIndex:3];
  [encoder setTexture:depthTex atIndex:4];
  const float projection[2] = {projectionZ, projectionW};
  [encoder setBytes:projection length:sizeof(projection) atIndex:0];
  [encoder dispatchThreads:MTLSizeMake(primTex.width, primTex.height, 1)
     threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
  [encoder endEncoding];
  [commandBuffer commit];
}

PXR_NAMESPACE_CLOSE_SCOPE
