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
#ifndef HDAKARI_SPHERE_H
#define HDAKARI_SPHERE_H

#include "pxr/pxrns.h"
#include "HdAkari/api.h"
#include "Hd/version.h"
#include "Hd/mesh.h"
#include "Hd/rprim.h"
#include "Hd/drawingCoord.h"
#include "Hd/enums.h"
#include "Hd/perfLog.h"

#include "Sdf/path.h"
#include "Vt/array.h"

PXR_NAMESPACE_OPEN_SCOPE

/// @class HdAkariSphere
///
/// Represents a sphere prim that can be rendered natively by Akari.
///
class HdAkariSphere final : public HdRprim
{
public:
  HDAKARI_API
  explicit HdAkariSphere(SdfPath const& id);

  ~HdAkariSphere() override;

  HDAKARI_API
  TfTokenVector const &GetBuiltinPrimvarNames() const override;
  
  HDAKARI_API
  HdDirtyBits GetInitialDirtyBitsMask() const override;

  HDAKARI_API
  void Sync(HdSceneDelegate *delegate,
            HdRenderParam   *renderParam,
            HdDirtyBits     *dirtyBits,
            TfToken const   &reprToken) override;

  HDAKARI_API
  void Finalize(HdRenderParam *renderParam) override;

protected:
  HDAKARI_API
  void _InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits) override;

  HDAKARI_API
  HdDirtyBits _PropagateDirtyBits(HdDirtyBits bits) const override;

  HdAkariSphere(const HdAkariSphere &) = delete;
  HdAkariSphere &operator=(const HdAkariSphere &) = delete;
  
private:
  uint64_t _dataGeneration = 0; // bumped each Sync for GPU cache invalidation
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_SPHERE_H
