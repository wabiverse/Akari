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
#ifndef HDAKARI_PROTOTYPE_MERGING_H
#define HDAKARI_PROTOTYPE_MERGING_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Hd/filteringSceneIndex.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/filteringSceneIndex.h>
#endif

#include "HdAkari/api.h"

#include <future>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

TF_DECLARE_REF_PTRS(HdAkariPrototypeMergingSceneIndex);

/// Merges the meshes of each instancer prototype into a few meshes.
class HDAKARI_API HdAkariPrototypeMergingSceneIndex final : public HdSingleInputFilteringSceneIndexBase
{
public:
  static HdAkariPrototypeMergingSceneIndexRefPtr New(HdSceneIndexBaseRefPtr const &inputSceneIndex);

  HdSceneIndexPrim GetPrim(SdfPath const &primPath) const override;
  SdfPathVector GetChildPrimPaths(SdfPath const &primPath) const override;

protected:
  explicit HdAkariPrototypeMergingSceneIndex(HdSceneIndexBaseRefPtr const &inputSceneIndex);

  void _PrimsAdded(HdSceneIndexBase const &sender,
                   HdSceneIndexObserver::AddedPrimEntries const &entries) override;
  void _PrimsRemoved(HdSceneIndexBase const &sender,
                     HdSceneIndexObserver::RemovedPrimEntries const &entries) override;
  void _PrimsDirtied(HdSceneIndexBase const &sender,
                     HdSceneIndexObserver::DirtiedPrimEntries const &entries) override;
  void _PrimsRenamed(HdSceneIndexBase const &sender,
                     HdSceneIndexObserver::RenamedPrimEntries const &entries) override;

public:
  struct Group;
  struct Root;

private:
  std::shared_ptr<Root> _GetRoot(SdfPath const &rootPath) const;
  std::shared_ptr<Root> _FindBuiltRoot(SdfPath const &path) const;
  bool _IsRoot(SdfPath const &path) const;
  void _Rebuild(std::vector<SdfPath> const &rootPaths,
                HdSceneIndexObserver::AddedPrimEntries *added,
                HdSceneIndexObserver::RemovedPrimEntries *removed);

  mutable std::mutex _mutex;
  mutable std::unordered_map<SdfPath, std::shared_ptr<Root>, SdfPath::Hash> _roots;
  mutable std::unordered_map<SdfPath, std::shared_future<std::shared_ptr<Root>>, SdfPath::Hash> _building;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_PROTOTYPE_MERGING_H
