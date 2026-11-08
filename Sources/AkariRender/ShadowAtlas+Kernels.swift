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
  enum Kernel: Akari.ComputeKernelName
  {
    case beginFrame, tilemapShift
    case tagUsagePunctual, tagUsageDirectional, tagUsageVolume, dilateUsageDirectional, dilateUsagePunctual
    case maskLod, free, defrag, allocate, pageTable, pageClear, pageCopy, retireDrawn
    case cull, cullPunctual, renderMapClear, buildClearList, clipmapClear, tilemapBounds
    case tagUpdate, tagUpdateStatic, tagUpdatePunctual, tagPropagate, buildRenderViews, countDirty, allotBudget

    static let label = "shadow"

    /// What the pipeline can't run without, the rest are skipped when they fail.
    static let required: Set<Kernel> = [.beginFrame, .tilemapShift, .tagUsagePunctual, .tagUsageDirectional,
                                        .dilateUsageDirectional, .dilateUsagePunctual, .maskLod, .free, .defrag,
                                        .allocate, .pageTable, .pageCopy]

    var glsl: String
    {
      source.glsl
    }

    var msl: String
    {
      source.msl
    }

    private var source: (glsl: String, msl: String)
    {
      switch self
      {
        case .beginFrame: (beginFrameGLSL, beginFrameMSL)
        case .tilemapShift: (tilemapShiftGLSL, tilemapShiftMSL)
        case .tagUsagePunctual: (tagUsagePunctualGLSL, tagUsagePunctualMSL)
        case .tagUsageDirectional: (tagUsageDirectionalGLSL, tagUsageDirectionalMSL)
        case .tagUsageVolume: (tagUsageVolumeGLSL, tagUsageVolumeMSL)
        case .dilateUsageDirectional: (dilateUsageDirectionalGLSL, dilateUsageDirectionalMSL)
        case .dilateUsagePunctual: (dilateUsagePunctualGLSL, dilateUsagePunctualMSL)
        case .maskLod: (maskLodGLSL, maskLodMSL)
        case .free: (freeGLSL, freeMSL)
        case .defrag: (defragGLSL, defragMSL)
        case .allocate: (allocateGLSL, allocateMSL)
        case .pageTable: (pageTableGLSL, pageTableMSL)
        case .pageClear: (pageClearGLSL, pageClearMSL)
        case .pageCopy: (pageCopyGLSL, pageCopyMSL)
        case .retireDrawn: (retireDrawnGLSL, retireDrawnMSL)
        case .cull: (cullGLSL, cullMSL)
        case .cullPunctual: (cullPunctualGLSL, cullPunctualMSL)
        case .renderMapClear: (renderMapClearGLSL, renderMapClearMSL)
        case .buildClearList: (buildClearListGLSL, buildClearListMSL)
        case .clipmapClear: (clipmapClearGLSL, clipmapClearMSL)
        case .tilemapBounds: (tilemapBoundsGLSL, tilemapBoundsMSL)
        case .tagUpdate: (tagUpdateGLSL(flagDynamicUpdate), tagUpdateMSL(flagDynamicUpdate))
        case .tagUpdateStatic: (tagUpdateGLSL(flagDoUpdate), tagUpdateMSL(flagDoUpdate))
        case .tagUpdatePunctual: (tagUpdatePunctualGLSL, tagUpdatePunctualMSL)
        case .tagPropagate: (tagPropagateGLSL, tagPropagateMSL)
        case .buildRenderViews: (buildRenderViewsGLSL, buildRenderViewsMSL)
        case .countDirty: (countDirtyGLSL, countDirtyMSL)
        case .allotBudget: (allotBudgetGLSL, allotBudgetMSL)
      }
    }

    var threadgroup: SIMD3<Int>
    {
      switch self
      {
        case .tilemapShift, .dilateUsageDirectional, .dilateUsagePunctual, .maskLod, .tagPropagate:
          SIMD3(tilemapRes, tilemapRes, 1)
        case .free, .allocate:
          SIMD3(tilemapRes * tilemapRes, 1, 1)
        case .tagUsagePunctual, .tagUsageDirectional, .tagUsageVolume:
          SIMD3(8, 8, 1)
        case .pageClear, .pageCopy:
          SIMD3(16, 16, 1)
        case .defrag, .allotBudget:
          SIMD3(1, 1, 1)
        default:
          SIMD3(64, 1, 1)
      }
    }
  }
}
