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
# include <Gf/vec2d.h>
# include <Gf/vec2f.h>
# include <Gf/vec3d.h>
# include <Gf/vec3f.h>
# include <Sdf/abstractData.h>
# include <Sdf/assetPath.h>
# include <Sdf/changeBlock.h>
# include <Sdf/layerStateDelegate.h>
# include <Tf/stringUtils.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec2d.h>
# include <pxr/base/gf/vec2f.h>
# include <pxr/base/gf/vec3d.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/usd/sdf/abstractData.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/usd/sdf/changeBlock.h>
# include <pxr/usd/sdf/layerStateDelegate.h>
# include <pxr/base/tf/stringUtils.h>
#endif

#include "HdAkari/authoring.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <mutex>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

class Journal;
TF_DECLARE_WEAK_AND_REF_PTRS(Journal);

// One change to a layer, how to take it back and how to make it again.
struct Change
{
  JournalPtr layer;
  std::function<void(Journal &)> undo, redo;
};

std::recursive_mutex journalMutex;
std::vector<Change> changes;
size_t position = 0;
bool replaying = false;

// Records each change before the layer makes it, while its old value is still there.
class Journal : public SdfLayerStateDelegateBase
{
public:
  static JournalRefPtr New(bool dirty) { return TfCreateRefPtr(new Journal(dirty)); }

protected:
  explicit Journal(bool dirty) : _dirty(dirty) {}

  bool _IsDirty() override { return _dirty; }
  void _MarkCurrentStateAsClean() override { _dirty = false; }
  void _MarkCurrentStateAsDirty() override { _dirty = true; }
  void _OnSetLayer(SdfLayerHandle const &) override {}

  void _OnSetField(SdfPath const &path, TfToken const &field, VtValue const &value) override
  {
    VtValue old = _GetLayer()->GetField(path, field);
    _Record([=](Journal &j) { j.SetField(path, field, old); }, [=](Journal &j) { j.SetField(path, field, value); });
  }

  void _OnSetField(SdfPath const &path, TfToken const &field, SdfAbstractDataConstValue const &value) override
  {
    VtValue v;
    value.GetValue(&v);
    _OnSetField(path, field, v);
  }

  void _OnSetFieldDictValueByKey(SdfPath const &path, TfToken const &field, TfToken const &key,
                                 VtValue const &value) override
  {
    VtValue old = _GetLayer()->GetFieldDictValueByKey(path, field, key);
    _Record([=](Journal &j) { j.SetFieldDictValueByKey(path, field, key, old); },
            [=](Journal &j) { j.SetFieldDictValueByKey(path, field, key, value); });
  }

  void _OnSetFieldDictValueByKey(SdfPath const &path, TfToken const &field, TfToken const &key,
                                 SdfAbstractDataConstValue const &value) override
  {
    VtValue v;
    value.GetValue(&v);
    _OnSetFieldDictValueByKey(path, field, key, v);
  }

  void _OnSetTimeSample(SdfPath const &path, double time, VtValue const &value) override
  {
    VtValue old;
    _GetLayer()->QueryTimeSample(path, time, &old);
    _Record([=](Journal &j) { j.SetTimeSample(path, time, old); }, [=](Journal &j) { j.SetTimeSample(path, time, value); });
  }

  void _OnSetTimeSample(SdfPath const &path, double time, SdfAbstractDataConstValue const &value) override
  {
    VtValue v;
    value.GetValue(&v);
    _OnSetTimeSample(path, time, v);
  }

  void _OnCreateSpec(SdfPath const &path, SdfSpecType type, bool inert) override
  {
    _Record([=](Journal &j) { j.DeleteSpec(path, inert); }, [=](Journal &j) { j.CreateSpec(path, type, inert); });
  }
  // a deletion takes the spec's whole subtree, which comes back field by field, parents first.
  void _OnDeleteSpec(SdfPath const &path, bool inert) override
  {
    struct Spec { SdfPath path; SdfSpecType type; std::vector<std::pair<TfToken, VtValue>> fields; };
    std::vector<Spec> subtree;
    SdfLayerHandle layer = _GetLayer();
    layer->Traverse(path, [&](SdfPath const &p) {
      Spec spec{p, layer->GetSpecType(p), {}};
      for (TfToken const &field : layer->ListFields(p)) spec.fields.emplace_back(field, layer->GetField(p, field));
      subtree.push_back(std::move(spec));
    });
    std::sort(subtree.begin(), subtree.end(),
              [](Spec const &a, Spec const &b) { return a.path.GetPathElementCount() < b.path.GetPathElementCount(); });
    _Record(
      [=](Journal &j) {
        for (Spec const &spec : subtree) {
          j.CreateSpec(spec.path, spec.type, inert);
          for (auto const &field : spec.fields) j.SetField(spec.path, field.first, field.second);
        }
      },
      [=](Journal &j) { j.DeleteSpec(path, inert); });
  }

  void _OnMoveSpec(SdfPath const &from, SdfPath const &to) override
  {
    _Record([=](Journal &j) { j.MoveSpec(to, from); }, [=](Journal &j) { j.MoveSpec(from, to); });
  }

  void _OnPushChild(SdfPath const &parent, TfToken const &field, TfToken const &value) override
  {
    _Record([=](Journal &j) { j.PopChild(parent, field, value); }, [=](Journal &j) { j.PushChild(parent, field, value); });
  }

  void _OnPushChild(SdfPath const &parent, TfToken const &field, SdfPath const &value) override
  {
    _Record([=](Journal &j) { j.PopChild(parent, field, value); }, [=](Journal &j) { j.PushChild(parent, field, value); });
  }

  void _OnPopChild(SdfPath const &parent, TfToken const &field, TfToken const &old) override
  {
    _Record([=](Journal &j) { j.PushChild(parent, field, old); }, [=](Journal &j) { j.PopChild(parent, field, old); });
  }

  void _OnPopChild(SdfPath const &parent, TfToken const &field, SdfPath const &old) override
  {
    _Record([=](Journal &j) { j.PushChild(parent, field, old); }, [=](Journal &j) { j.PopChild(parent, field, old); });
  }

private:
  void _Record(std::function<void(Journal &)> undo, std::function<void(Journal &)> redo)
  {
    _dirty = true;
    std::lock_guard<std::recursive_mutex> lock(journalMutex);
    if (replaying) return;
    changes.resize(position);
    changes.push_back({JournalPtr(this), std::move(undo), std::move(redo)});
    position = changes.size();
  }

  bool _dirty;
};

} // namespace

void
HdAkariJournalWatch(SdfLayerHandle const &layer)
{
  if (!layer || TfDynamic_cast<JournalPtr>(layer->GetStateDelegate())) return;
  layer->SetStateDelegate(Journal::New(layer->IsDirty()));
}

size_t
HdAkariJournalPosition()
{
  std::lock_guard<std::recursive_mutex> lock(journalMutex);
  return position;
}

void
HdAkariJournalSeek(size_t target)
{
  std::lock_guard<std::recursive_mutex> lock(journalMutex);
  target = std::min(target, changes.size());
  replaying = true;
  SdfChangeBlock block;
  while (position > target) {
    Change &change = changes[--position];
    if (change.layer) change.undo(*change.layer);
  }
  while (position < target) {
    Change &change = changes[position++];
    if (change.layer) change.redo(*change.layer);
  }

  replaying = false;
}

void
HdAkariJournalClear()
{
  std::lock_guard<std::recursive_mutex> lock(journalMutex);
  changes.clear();
  position = 0;
}

int
HdAkariValueNumbers(VtValue const &v, double *out)
{
  if (v.IsHolding<GfVec3f>()) { GfVec3f x = v.UncheckedGet<GfVec3f>(); out[0] = x[0]; out[1] = x[1]; out[2] = x[2]; return 3; }
  if (v.IsHolding<GfVec3d>()) { GfVec3d x = v.UncheckedGet<GfVec3d>(); out[0] = x[0]; out[1] = x[1]; out[2] = x[2]; return 3; }
  if (v.IsHolding<GfVec2f>()) { GfVec2f x = v.UncheckedGet<GfVec2f>(); out[0] = x[0]; out[1] = x[1]; return 2; }
  if (v.IsHolding<GfVec2d>()) { GfVec2d x = v.UncheckedGet<GfVec2d>(); out[0] = x[0]; out[1] = x[1]; return 2; }
  if (v.IsHolding<bool>()) { out[0] = v.UncheckedGet<bool>() ? 1 : 0; return 1; }
  if (v.CanCast<double>()) { out[0] = VtValue::Cast<double>(v).UncheckedGet<double>(); return 1; }
  return 0;
}

std::string
HdAkariDescribeValue(VtValue const &v)
{
  if (v.IsEmpty()) return std::string();
  if (v.IsHolding<std::string>()) return v.UncheckedGet<std::string>();
  if (v.IsHolding<TfToken>()) return v.UncheckedGet<TfToken>().GetString();
  if (v.IsHolding<SdfAssetPath>()) return v.UncheckedGet<SdfAssetPath>().GetAssetPath();
  if (v.IsArrayValued()) return "[" + std::to_string(v.GetArraySize()) + " " + v.GetTypeName() + "]";
  std::string s = TfStringify(v);
  return s.size() > 80 ? s.substr(0, 77) + "..." : s;
}

std::vector<double> HdAkariTimeSamples(UsdAttribute const &attribute)
{
  std::vector<double> times;
  if (attribute) attribute.GetTimeSamples(&times);
  return times;
}

bool HdAkariSetValue(UsdAttribute const &attribute, VtValue const &value, double time)
{
  if (!attribute || value.IsEmpty()) return false;
  return attribute.Set(value, std::isnan(time) ? UsdTimeCode::Default() : UsdTimeCode(time));
}

PXR_NAMESPACE_CLOSE_SCOPE
