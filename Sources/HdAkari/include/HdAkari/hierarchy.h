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

#ifndef HDAKARI_HIERARCHY_H
#define HDAKARI_HIERARCHY_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Usd/stage.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/usd/stage.h>
#endif

#include "HdAkari/api.h"

#include <string>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

/// moves a prim in the edit target layer and repoints what targets it, returns the new path or empty
HDAKARI_API std::string HdAkariMovePrim(UsdStage *stage, std::string const &path, std::string const &destination);

/// adds a variant and its set when new, selecting it when asked
HDAKARI_API bool HdAkariAddVariant(UsdStage *stage, std::string const &path, std::string const &set,
                                   std::string const &variant, bool select);

/// selects a variant in one of a prim's sets
HDAKARI_API bool HdAkariSelectVariant(UsdStage *stage, std::string const &path, std::string const &set,
                                      std::string const &variant);

/// a prim's variant sets, each as its name, selection and variants separated by tabs
HDAKARI_API std::vector<std::string> HdAkariVariantSets(UsdStage *stage, std::string const &path);

/// a prim's variant selection path
HDAKARI_API std::string HdAkariVariantSelectionPath(std::string const &path, std::string const &set,
                                                    std::string const &variant);

/// sets the root layer's up axis, default prim and documentation, leaving empty ones alone
HDAKARI_API bool HdAkariSetStageMetadata(UsdStage *stage, std::string const &upAxis, std::string const &defaultPrim,
                                         std::string const &documentation);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_HIERARCHY_H
