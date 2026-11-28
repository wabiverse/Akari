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
# include <Hd/rendererPluginRegistry.h>
# include <Hd/sceneIndexPlugin.h>
# include <Hd/sceneIndexPluginRegistry.h>
# include <Hd/filteringSceneIndex.h>
# include <Hd/legacyDisplayStyleSchema.h>
# include <Hd/materialBindingsSchema.h>
# include <Hd/meshSchema.h>
# include <Tf/registryManager.h>
# include <Tf/type.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/rendererPluginRegistry.h>
# include <pxr/imaging/hd/sceneIndexPlugin.h>
# include <pxr/imaging/hd/sceneIndexPluginRegistry.h>
# include <pxr/imaging/hd/filteringSceneIndex.h>
# include <pxr/imaging/hd/legacyDisplayStyleSchema.h>
# include <pxr/imaging/hd/materialBindingsSchema.h>
# include <pxr/imaging/hd/meshSchema.h>
# include <pxr/base/tf/registryManager.h>
# include <pxr/base/tf/type.h>
#endif

#include "HdAkari/rendererPlugin.h"
#include "HdAkari/renderDelegate.h"
#include "HdAkari/akariBridge.h"
#include "HdAkari/prototypeMerging.h"
#include "HdAkari/stageInfo.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

// register akari with the hydra renderer plugin registry
TF_REGISTRY_FUNCTION(TfType)
{
  HdRendererPluginRegistry::Define<HdAkariRendererPlugin>();
}

// merges each instancer prototype's meshes ahead of the render index, `AKARI_MERGE_PROTOTYPES=0` leaves them as authored
TF_REGISTRY_FUNCTION(HdSceneIndexPlugin)
{
  HdSceneIndexPluginRegistry::GetInstance().RegisterSceneIndexForRenderer(
    "Akari",
    [](std::string const &, HdSceneIndexBaseRefPtr const &input, HdContainerDataSourceHandle const &)
      -> HdSceneIndexBaseRefPtr {
      const char *env = std::getenv("AKARI_MERGE_PROTOTYPES");
      if (env && std::strcmp(env, "0") == 0) return input;

      return HdAkariPrototypeMergingSceneIndex::New(input);
    },
    nullptr, 0, HdSceneIndexPluginRegistry::InsertionOrderAtEnd);
}

namespace {

TF_DECLARE_WEAK_AND_REF_PTRS(HdAkariMeshDirtyingSceneIndex);

/// passes the scene through and tells hydra a mesh changed when kraken edits something hydra does not track
class HdAkariMeshDirtyingSceneIndex final : public HdSingleInputFilteringSceneIndexBase
{
public:
  static HdAkariMeshDirtyingSceneIndexRefPtr New(HdSceneIndexBaseRefPtr const &input)
  {
    return TfCreateRefPtr(new HdAkariMeshDirtyingSceneIndex(input));
  }

  HdSceneIndexPrim GetPrim(SdfPath const &primPath) const override { return _GetInputSceneIndex()->GetPrim(primPath); }

  SdfPathVector GetChildPrimPaths(SdfPath const &primPath) const override
  {
    return _GetInputSceneIndex()->GetChildPrimPaths(primPath);
  }

  void Dirty(SdfPath const &path, HdDataSourceLocatorSet const &locators, bool meshesOnly)
  {
    if (!_IsObserved()) return;

    const TfToken type = GetPrim(path).primType;
    if (type.IsEmpty() || (meshesOnly && type != HdPrimTypeTokens->mesh)) return;
    _SendPrimsDirtied({{path, locators}});
  }

protected:
  explicit HdAkariMeshDirtyingSceneIndex(HdSceneIndexBaseRefPtr const &input) : HdSingleInputFilteringSceneIndexBase(input) {}

  void _PrimsAdded(HdSceneIndexBase const &, HdSceneIndexObserver::AddedPrimEntries const &entries) override
  {
    _SendPrimsAdded(entries);
  }

  void _PrimsRemoved(HdSceneIndexBase const &, HdSceneIndexObserver::RemovedPrimEntries const &entries) override
  {
    _SendPrimsRemoved(entries);
  }

  void _PrimsDirtied(HdSceneIndexBase const &, HdSceneIndexObserver::DirtiedPrimEntries const &entries) override
  {
    _SendPrimsDirtied(entries);
  }
};

std::mutex dirtyingLock;
std::vector<HdAkariMeshDirtyingSceneIndexPtr> dirtying;

}

namespace {

/// tells every live akari scene index that these meshes changed where `locators` say
void markDirty(SdfPathVector const &paths, HdDataSourceLocatorSet const &locators, bool meshesOnly)
{
  std::vector<HdAkariMeshDirtyingSceneIndexPtr> live;
  {
    std::lock_guard<std::mutex> lock(dirtyingLock);
    dirtying.erase(std::remove_if(dirtying.begin(), dirtying.end(), [](auto const &index) { return !index; }),
                   dirtying.end());
    live = dirtying;
  }

  for (auto const &index : live) {
    if (!index) continue;
    for (SdfPath const &path : paths) {
      index->Dirty(path, locators, meshesOnly);
    }
  }
}

}

void
HdAkariMarkMeshDirty(std::string const &path)
{
  if (!SdfPath::IsValidPathString(path)) return;

  HdDataSourceLocatorSet locators;
  locators.insert(HdMeshSchema::GetTopologyLocator());
  locators.insert(HdLegacyDisplayStyleSchema::GetRefineLevelLocator());
  markDirty({SdfPath(path)}, locators, true);
}

void
HdAkariMarkMaterialUsersDirty(SdfPathVector const &paths)
{
  markDirty(paths, HdDataSourceLocatorSet{HdMaterialBindingsSchema::GetDefaultLocator()}, false);
}

// lets kraken resync a mesh after edits hydra ignores, like its own subdivision levels
TF_REGISTRY_FUNCTION(HdSceneIndexPlugin)
{
  HdSceneIndexPluginRegistry::GetInstance().RegisterSceneIndexForRenderer(
    "Akari",
    [](std::string const &, HdSceneIndexBaseRefPtr const &input, HdContainerDataSourceHandle const &)
      -> HdSceneIndexBaseRefPtr {
      HdAkariMeshDirtyingSceneIndexRefPtr index = HdAkariMeshDirtyingSceneIndex::New(input);
      std::lock_guard<std::mutex> lock(dirtyingLock);
      dirtying.push_back(HdAkariMeshDirtyingSceneIndexPtr(index));
      return index;
    },
    nullptr, 0, HdSceneIndexPluginRegistry::InsertionOrderAtEnd);
}

PXR_NAMESPACE_CLOSE_SCOPE

/// linked statically nothing references this file, so swift calls this to keep the linker from dropping its registry functions
extern "C" void AkariHdEnsureLinked(void) {}

PXR_NAMESPACE_OPEN_SCOPE

HdRenderDelegate *
HdAkariRendererPlugin::CreateRenderDelegate()
{
  return new HdAkariRenderDelegate();
}

HdRenderDelegate *
HdAkariRendererPlugin::CreateRenderDelegate(
    HdRenderSettingsMap const &settingsMap)
{
  return new HdAkariRenderDelegate(settingsMap);
}

void
HdAkariRendererPlugin::DeleteRenderDelegate(HdRenderDelegate *renderDelegate)
{
  delete renderDelegate;
}

bool
HdAkariRendererPlugin::IsSupported(
    const HdRendererCreateArgsSchema & /*rendererCreateArgs*/,
    std::string * /*reasonWhyNot*/) const
{
  // akari is available wherever hydra runs
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
