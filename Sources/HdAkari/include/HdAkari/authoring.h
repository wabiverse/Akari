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

#ifndef HDAKARI_AUTHORING_H
#define HDAKARI_AUTHORING_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Sdf/layer.h>
# include <Usd/attribute.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/sdf/layer.h>
# include <pxr/usd/usd/attribute.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/api.h"

#include <cstddef>
#include <string>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

/// Journals every change to `layer` from now on, for undo, until the journal is cleared.
HDAKARI_API void HdAkariJournalWatch(SdfLayerHandle const &layer);

/// How many changes the journal holds before the current state.
HDAKARI_API size_t HdAkariJournalPosition();

/// Undoes or redoes the journaled changes until `position` of them are applied,
/// a change after an undo drops the ones past it.
HDAKARI_API void HdAkariJournalSeek(size_t position);

/// Forgets every journaled change.
HDAKARI_API void HdAkariJournalClear();

/// A value as the properties panel shows it.
HDAKARI_API std::string HdAkariDescribeValue(VtValue const &value);

/// A value's numbers into `out`, up to 3 of them, how many it has, 0 when it isn't numeric.
HDAKARI_API int HdAkariValueNumbers(VtValue const &value, double *out);

/// The times `attribute` has keys at.
HDAKARI_API std::vector<double> HdAkariTimeSamples(UsdAttribute const &attribute);

/// Writes `value` to `attribute` at `time`, or as its default when `time` is NaN.
HDAKARI_API bool HdAkariSetValue(UsdAttribute const &attribute, VtValue const &value, double time);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_AUTHORING_H
