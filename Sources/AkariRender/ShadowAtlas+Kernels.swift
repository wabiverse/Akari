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

import AkariCore
import LabGL

extension Akari.ShadowAtlas
{
  struct Kernels
  {
    var beginFrame: GLuint = 0
    var tilemapShift: GLuint = 0
    var tagUsagePunctual: GLuint = 0
    var tagUsageDirectional: GLuint = 0
    var tagUsageVolume: GLuint = 0
    var dilateUsageDirectional: GLuint = 0
    var dilateUsagePunctual: GLuint = 0
    var maskLod: GLuint = 0
    var free: GLuint = 0
    var defrag: GLuint = 0
    var allocate: GLuint = 0
    var pageTable: GLuint = 0
    var pageClear: GLuint = 0
    var retireDrawn: GLuint = 0
    var cull: GLuint = 0
    var cullPunctual: GLuint = 0
    var renderMapClear: GLuint = 0
    var buildClearList: GLuint = 0
    var clipmapClear: GLuint = 0
    var tilemapBounds: GLuint = 0
    var tagUpdate: GLuint = 0
    var tagPropagate: GLuint = 0
    var buildRenderViews: GLuint = 0

    var all: [GLuint]
    {
      [beginFrame, tilemapShift, tagUsagePunctual, tagUsageDirectional, tagUsageVolume,
       dilateUsageDirectional, dilateUsagePunctual, maskLod, free, defrag, allocate,
       pageTable, pageClear, retireDrawn, cull, cullPunctual, renderMapClear, buildClearList,
       clipmapClear, tilemapBounds, tagUpdate, tagPropagate, buildRenderViews]
    }

    /// The kernels the pipeline can't run without.
    var isComplete: Bool
    {
      [beginFrame, tilemapShift, tagUsagePunctual, tagUsageDirectional, dilateUsageDirectional,
       dilateUsagePunctual, maskLod, free, defrag, allocate, pageTable].allSatisfy { $0 != 0 }
    }

    func setThreadgroupSizes()
    {
      let res = GLuint(tilemapRes)
      gl.setComputeShaderThreadgroupSize(beginFrame, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(tilemapShift, x: res, y: res, z: 1)
      gl.setComputeShaderThreadgroupSize(dilateUsageDirectional, x: res, y: res, z: 1)
      gl.setComputeShaderThreadgroupSize(dilateUsagePunctual, x: res, y: res, z: 1)
      gl.setComputeShaderThreadgroupSize(tagUsagePunctual, x: 8, y: 8, z: 1)
      gl.setComputeShaderThreadgroupSize(tagUsageDirectional, x: 8, y: 8, z: 1)
      if tagUsageVolume != 0
      {
        gl.setComputeShaderThreadgroupSize(tagUsageVolume, x: 8, y: 8, z: 1)
      }
      gl.setComputeShaderThreadgroupSize(maskLod, x: res, y: res, z: 1)
      gl.setComputeShaderThreadgroupSize(free, x: res * res, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(allocate, x: res * res, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(defrag, x: 1, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(pageTable, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(pageClear, x: 16, y: 16, z: 1)
      gl.setComputeShaderThreadgroupSize(retireDrawn, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(cull, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(cullPunctual, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(buildClearList, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(renderMapClear, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(clipmapClear, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(tilemapBounds, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(tagUpdate, x: 64, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(tagPropagate, x: res, y: res, z: 1)
      gl.setComputeShaderThreadgroupSize(buildRenderViews, x: 64, y: 1, z: 1)
    }
  }

  static func compileKernels() -> Kernels
  {
    func compile(_ name: String, _ glsl: String, _ msl: String) -> GLuint
    {
      gl.defineComputeShader(name: "akari-shadow-\(name)", glsl: glsl, msl: msl)
    }

    var k = Kernels()
    k.beginFrame = compile("begin-frame", beginFrameGLSL, beginFrameMSL)
    k.tilemapShift = compile("tilemap-shift", tilemapShiftGLSL, tilemapShiftMSL)
    k.tagUsagePunctual = compile("tag-usage-punctual", tagUsagePunctualGLSL, tagUsagePunctualMSL)
    k.tagUsageDirectional = compile("tag-usage-directional", tagUsageDirectionalGLSL, tagUsageDirectionalMSL)
    k.tagUsageVolume = compile("tag-usage-volume", tagUsageVolumeGLSL, tagUsageVolumeMSL)
    if k.tagUsageVolume == 0
    {
      print("[akari/shadow] volume usage tagging failed to compile, fog shadows fall back to surface pages")
    }
    k.dilateUsageDirectional = compile("dilate-usage-directional", dilateUsageDirectionalGLSL, dilateUsageDirectionalMSL)
    k.dilateUsagePunctual = compile("dilate-usage-punctual", dilateUsagePunctualGLSL, dilateUsagePunctualMSL)
    k.maskLod = compile("mask-lod", maskLodGLSL, maskLodMSL)
    k.free = compile("free", freeGLSL, freeMSL)
    k.defrag = compile("defrag", defragGLSL, defragMSL)
    k.allocate = compile("allocate", allocateGLSL, allocateMSL)
    k.pageTable = compile("page-table", pageTableGLSL, pageTableMSL)
    k.pageClear = compile("page-clear", pageClearGLSL, pageClearMSL)
    k.retireDrawn = compile("retire-drawn", retireDrawnGLSL, retireDrawnMSL)
    k.cull = compile("cull", cullGLSL, cullMSL)
    k.cullPunctual = compile("cull-punctual", cullPunctualGLSL, cullPunctualMSL)
    k.renderMapClear = compile("render-map-clear", renderMapClearGLSL, renderMapClearMSL)
    k.buildClearList = compile("build-clear-list", buildClearListGLSL, buildClearListMSL)
    k.clipmapClear = compile("clipmap-clear", clipmapClearGLSL, clipmapClearMSL)
    k.tilemapBounds = compile("tilemap-bounds", tilemapBoundsGLSL, tilemapBoundsMSL)
    k.tagUpdate = compile("tag-update", tagUpdateGLSL, tagUpdateMSL)
    k.tagPropagate = compile("tag-propagate", tagPropagateGLSL, tagPropagateMSL)
    k.buildRenderViews = compile("build-render-views", buildRenderViewsGLSL, buildRenderViewsMSL)

    return k
  }
}
