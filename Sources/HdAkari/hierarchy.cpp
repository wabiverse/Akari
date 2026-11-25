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
# include <Sdf/attributeSpec.h>
# include <Sdf/layer.h>
# include <Sdf/namespaceEdit.h>
# include <Sdf/primSpec.h>
# include <Sdf/relationshipSpec.h>
# include <Usd/editContext.h>
# include <Usd/editTarget.h>
# include <Usd/prim.h>
# include <Usd/variantSets.h>
# include <UsdGeom/metrics.h>
# include <UsdGeom/tokens.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/sdf/attributeSpec.h>
# include <pxr/usd/sdf/layer.h>
# include <pxr/usd/sdf/namespaceEdit.h>
# include <pxr/usd/sdf/primSpec.h>
# include <pxr/usd/sdf/relationshipSpec.h>
# include <pxr/usd/usd/editContext.h>
# include <pxr/usd/usd/editTarget.h>
# include <pxr/usd/usd/prim.h>
# include <pxr/usd/usd/variantSets.h>
# include <pxr/usd/usdGeom/metrics.h>
# include <pxr/usd/usdGeom/tokens.h>
#endif

#include "HdAkari/hierarchy.h"

#include <optional>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// repoints every target and connection in the layer from one path to another
void
_Repoint(SdfLayerHandle const &layer, SdfPath const &from, SdfPath const &to)
{
  std::vector<SdfPath> specs;
  layer->Traverse(SdfPath::AbsoluteRootPath(), [&specs](SdfPath const &p) { specs.push_back(p); });
  auto fix = [&from, &to](SdfPath const &p) -> std::optional<SdfPath> {
    return p.HasPrefix(from) ? p.ReplacePrefix(from, to) : p;
  };
  for (SdfPath const &p : specs) {
    if (!p.IsPropertyPath()) {
      continue;
    }
    switch (layer->GetSpecType(p)) {
      case SdfSpecTypeRelationship:
        if (SdfRelationshipSpecHandle rel = layer->GetRelationshipAtPath(p)) {
          rel->GetTargetPathList().ModifyItemEdits(fix);
        }
        break;
      case SdfSpecTypeAttribute:
        if (SdfAttributeSpecHandle attr = layer->GetAttributeAtPath(p)) {
          if (attr->HasConnectionPaths()) {
            attr->GetConnectionPathList().ModifyItemEdits(fix);
          }
        }
        break;
      default:
        break;
    }
  }
}

} // namespace

std::string
HdAkariMovePrim(UsdStage *stage, std::string const &path, std::string const &destination)
{
  if (!stage || !SdfPath::IsValidPathString(path) || !SdfPath::IsValidPathString(destination)) {
    return {};
  }
  SdfPath const from(path), to(destination);
  if (from == to) {
    return path;
  }
  if (!from.IsPrimPath() || !to.IsPrimPath() || to.HasPrefix(from) || stage->GetPrimAtPath(to)) {
    return {};
  }

  // the edit target may be a variant whose specs live under its selection path
  UsdEditTarget const target = stage->GetEditTarget();
  SdfLayerHandle const layer = target.GetLayer();
  SdfPath const specFrom = target.MapToSpecPath(from), specTo = target.MapToSpecPath(to);
  if (!layer || specFrom.IsEmpty() || specTo.IsEmpty() || !layer->GetPrimAtPath(specFrom) ||
      layer->GetPrimAtPath(specTo)) {
    return {};
  }
  SdfPath const parent = specTo.GetParentPath();
  if (!parent.IsAbsoluteRootPath() && !layer->GetPrimAtPath(parent)) {
    SdfCreatePrimInLayer(layer, parent);
  }
  SdfBatchNamespaceEdit edits;
  edits.Add(SdfNamespaceEdit::ReparentAndRename(specFrom, parent, specTo.GetNameToken(), SdfNamespaceEdit::AtEnd));
  if (!layer->CanApply(edits) || !layer->Apply(edits)) {
    return {};
  }
  _Repoint(layer, from, to);
  SdfLayerHandle const root = stage->GetRootLayer();
  if (root->HasDefaultPrim() && SdfPath::AbsoluteRootPath().AppendChild(root->GetDefaultPrim()) == from) {
    root->SetDefaultPrim(to.IsRootPrimPath() ? to.GetNameToken() : TfToken());
  }
  return to.GetString();
}

bool
HdAkariAddVariant(UsdStage *stage, std::string const &path, std::string const &set, std::string const &variant,
                  bool select)
{
  if (!stage || !SdfPath::IsValidPathString(path) || set.empty() || variant.empty()) {
    return false;
  }
  UsdPrim prim = stage->GetPrimAtPath(SdfPath(path));
  if (!prim) {
    return false;
  }
  UsdVariantSet variants = prim.GetVariantSets().AddVariantSet(set);
  if (!variants.IsValid() || !variants.AddVariant(variant)) {
    return false;
  }
  return !select || variants.SetVariantSelection(variant);
}

bool
HdAkariSelectVariant(UsdStage *stage, std::string const &path, std::string const &set, std::string const &variant)
{
  if (!stage || !SdfPath::IsValidPathString(path)) {
    return false;
  }
  UsdPrim prim = stage->GetPrimAtPath(SdfPath(path));
  if (!prim || !prim.GetVariantSets().HasVariantSet(set)) {
    return false;
  }
  return prim.GetVariantSet(set).SetVariantSelection(variant);
}

std::vector<std::string>
HdAkariVariantSets(UsdStage *stage, std::string const &path)
{
  std::vector<std::string> out;
  if (!stage || !SdfPath::IsValidPathString(path)) {
    return out;
  }
  UsdPrim prim = stage->GetPrimAtPath(SdfPath(path));
  if (!prim) {
    return out;
  }
  UsdVariantSets sets = prim.GetVariantSets();
  for (std::string const &name : sets.GetNames()) {
    UsdVariantSet set = sets.GetVariantSet(name);
    std::string entry = name + "\t" + set.GetVariantSelection();
    for (std::string const &v : set.GetVariantNames()) {
      entry += "\t" + v;
    }
    out.push_back(entry);
  }
  return out;
}

std::string
HdAkariVariantSelectionPath(std::string const &path, std::string const &set, std::string const &variant)
{
  if (!SdfPath::IsValidPathString(path)) {
    return {};
  }
  return SdfPath(path).AppendVariantSelection(set, variant).GetString();
}

bool
HdAkariSetStageMetadata(UsdStage *stage, std::string const &upAxis, std::string const &defaultPrim,
                        std::string const &documentation)
{
  if (!stage) {
    return false;
  }
  bool ok = true;
  UsdStagePtr const weak(stage);
  UsdEditContext context(weak, UsdEditTarget(stage->GetRootLayer()));
  if (upAxis == "Z" || upAxis == "z") {
    ok = UsdGeomSetStageUpAxis(weak, UsdGeomTokens->z) && ok;
  }
  else if (upAxis == "Y" || upAxis == "y") {
    ok = UsdGeomSetStageUpAxis(weak, UsdGeomTokens->y) && ok;
  }
  if (defaultPrim == "/") {
    stage->ClearDefaultPrim();
  }
  else if (!defaultPrim.empty() && SdfPath::IsValidPathString(defaultPrim)) {
    UsdPrim prim = stage->GetPrimAtPath(SdfPath(defaultPrim));
    if (prim && prim.GetPath().IsRootPrimPath()) {
      stage->SetDefaultPrim(prim);
    }
    else {
      ok = false;
    }
  }
  if (!documentation.empty()) {
    stage->GetRootLayer()->SetDocumentation(documentation);
  }
  return ok;
}

PXR_NAMESPACE_CLOSE_SCOPE
