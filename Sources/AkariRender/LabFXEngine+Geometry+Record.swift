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
import Foundation
import HdAkari
import HydraKit
import LabFX
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// Deforms the dynamic meshes on the GPU, and rerecords
  /// the static ones only when which meshes are static changed.
  func recordCaptures(changed: [Akari.Geom.Recorder.RawMesh], removed: [UInt64], camera: RecordCamera)
  {
    guard
      geometry.staticCapture != nil,
      let dynamicCapture = geometry.dynamicCapture
    else { return }

    let reframes = geometry.view.reframe && changed.isEmpty && removed.isEmpty && !geometry.record.restyled
    // only looking in on a reframe building in the background isn't a record.
    if geometry.view.reframing == nil || geometry.view.reframe || !changed.isEmpty || !removed.isEmpty || geometry.record.restyled
    {
      geometry.record.count += 1
      geometry.record.at = Date()
    }

    var dirty = Dirty(statics: geometry.record.count == 1 || geometry.view.reframe, dynamics: geometry.deformer.relayout)
    geometry.view.reframe = false

    let removed = releaseExpansions(changed: changed, removed: removed)
    var changed = expandFallbackInstances(changed, dirty: &dirty)
    changed = takeWater(changed, removed: removed)
    changed = decimateTransparent(changed)

    applyRemovals(removed, dirty: &dirty)
    applyRestyle(dirty: &dirty)
    applyChanges(changed, dirty: &dirty)

    chooseStatic(statics: dirty.statics, camera: camera, reframes: reframes)
    deformDynamic(dynamics: dirty.dynamics, into: dynamicCapture)
    updateSceneBounds()
  }

  /// What a record has to rebuild, the static captures and the deformer.
  struct Dirty
  {
    var statics: Bool
    var dynamics: Bool
  }

  /// The removed keys plus the per instance fallbacks of every mesh that changed or left.
  private func releaseExpansions(changed: [Akari.Geom.Recorder.RawMesh], removed: [UInt64]) -> [UInt64]
  {
    // a meshes old per instance fallbacks go with it whenever it
    // changes or leaves, the fresh copies if still needed, are
    // added below.
    var removed = removed
    for key in Array(removed)
    {
      if let copies = geometry.expansions.removeValue(forKey: key) { removed += copies }
    }

    for mesh in changed
    {
      if let copies = geometry.expansions.removeValue(forKey: mesh.key) { removed += copies }
    }

    return removed
  }

  private func expandFallbackInstances(_ changed: [Akari.Geom.Recorder.RawMesh], dirty: inout Dirty) -> [Akari.Geom.Recorder.RawMesh]
  {
    // the deformer has no instance path, so an instanced mesh that is
    // transparent, styled, skinned or animated falls back to one raw
    // mesh per instance. the rest draw as one prototype with GPU
    // instancing.
    changed.flatMap
    { mesh -> [Akari.Geom.Recorder.RawMesh] in
      guard !mesh.instances.isEmpty else { return [mesh] }
      let seen = geometry.changes[mesh.key]
      let animates = geometry.animated.contains(mesh.key)
        || (seen != nil && seen != Self.changeKey(mesh))
      let instancedFallback = mesh.transparent || mesh.skinInfluencesPerPoint > 0
        || geometry.flags.styled.contains(mesh.primId) || animates
      guard instancedFallback else { return [mesh] }

      // the prototype itself must not also draw at its root transform.
      if geometry.meshes.removeValue(forKey: mesh.key) != nil
      {
        geometry.primIds[mesh.key] = nil
        geometry.changes[mesh.key] = nil
        if geometry.animated.remove(mesh.key) != nil { dirty.dynamics = true }
        else { dirty.statics = true }
      }

      let copies = Self.expandInstances(mesh)
      geometry.expansions[mesh.key] = copies.map(\.key)
      return copies
    }
  }

  private func takeWater(_ changed: [Akari.Geom.Recorder.RawMesh], removed: [UInt64]) -> [Akari.Geom.Recorder.RawMesh]
  {
    // a large flat transparent sheet is water, which the composite shades as a plane.
    if removed.contains(where: waterKeys.contains)
    {
      water = nil
      waterKeys.subtract(removed)
    }

    return changed.filter
    { mesh in
      guard mesh.transparent, let plane = waterPlane(mesh) else { return true }
      waterKeys.insert(mesh.key)
      // the most finely modeled sheet is the one by the shore, where its level shows.
      if let water
      {
        self.water = plane.detail > water.detail ? plane : water
        self.water?.lo = pointwiseMin(water.lo, plane.lo)
        self.water?.hi = pointwiseMax(water.hi, plane.hi)
      }
      else
      {
        water = plane
      }

      return false
    }
  }

  private func decimateTransparent(_ changed: [Akari.Geom.Recorder.RawMesh]) -> [Akari.Geom.Recorder.RawMesh]
  {
    // the transparency pass draws every triangle its given, which we can cheat for water.
    changed.map
    { mesh in
      guard mesh.transparent, mesh.tris.size() > Self.maxTransparentTriangles else { return mesh }
      var points = Pixar.VtVec3fArray(), tris = Pixar.VtVec3iArray(), uvs = Pixar.VtVec2fArray()
      var sources = Pixar.VtIntArray()
      guard Pixar.HdAkariDecimate(mesh.points, mesh.tris, mesh.uvs, Self.maxTransparentTriangles,
                                  &points, &tris, &uvs, &sources) else { return mesh }
      var simplified = mesh
      simplified.points = points
      simplified.tris = tris
      simplified.uvs = uvs
      return simplified
    }
  }

  private func applyRemovals(_ removed: [UInt64], dirty: inout Dirty)
  {
    for key in removed
    {
      if geometry.animated.contains(key), geometry.meshes[key] != nil
      {
        geometry.primIds[key] = nil
        if geometry.hidden.insert(key).inserted { dirty.dynamics = true }
        continue
      }

      guard geometry.meshes.removeValue(forKey: key) != nil else { continue }
      geometry.primIds[key] = nil
      geometry.changes[key] = nil
      dirty.statics = true
    }
  }

  /// Styled meshes only ever exist deformed.
  private func applyRestyle(dirty: inout Dirty)
  {
    if geometry.record.restyled
    {
      geometry.record.restyled = false
      dirty.dynamics = true
      for (key, mesh) in geometry.meshes where geometry.flags.styled.contains(mesh.primId) && !geometry.animated.contains(key)
      {
        geometry.animated.insert(key)
        dirty.statics = true
      }
    }
  }

  private func applyChanges(_ changed: [Akari.Geom.Recorder.RawMesh], dirty: inout Dirty)
  {
    for mesh in changed
    {
      if mesh.transparent { geometry.flags.transparent.insert(mesh.primId) } else { geometry.flags.transparent.remove(mesh.primId) }
      if mesh.emitter { geometry.flags.emitters.insert(mesh.primId) } else { geometry.flags.emitters.remove(mesh.primId) }
      geometry.flags.opacity[mesh.primId] = mesh.transparent ? mesh.opacity : nil
      let key = Self.changeKey(mesh)
      let isNew = geometry.meshes.updateValue(mesh, forKey: mesh.key) == nil
      if geometry.hidden.remove(mesh.key) != nil { dirty.dynamics = true }
      geometry.primIds[mesh.key] = mesh.primId
      let last = geometry.changes.updateValue(key, forKey: mesh.key)
      if geometry.animated.contains(mesh.key)
      {
        dirty.dynamics = true
      }
      else if mesh.skinInfluencesPerPoint > 0 || geometry.flags.styled.contains(mesh.primId) || mesh.transparent
      {
        // GPU skinned meshes only ever exist deformed.
        geometry.animated.insert(mesh.key)
        dirty.dynamics = true
        if !isNew { dirty.statics = true }
      }
      else if isNew
      {
        // new meshes start static, so loading
        // a scene isn't one long animation.
        dirty.statics = true
      }
      else if last != key
      {
        geometry.animated.insert(mesh.key)
        dirty.statics = true
        dirty.dynamics = true
      }
    }
  }

  /// Picks up a finished background reframe, and chooses the static geometry again when it changed.
  private func chooseStatic(statics: Bool, camera: RecordCamera, reframes: Bool)
  {
    if let job = geometry.view.reframing, !statics, job.done.wait(timeout: .now()) == .success
    {
      geometry.view.reframing = nil
      if let chosen = job.chosen
      {
        apply(chosen)
      }
    }

    if statics
    {
      // what the meshes are changed under a reframe still choosing, so it's chosen again here.
      if let job = geometry.view.reframing
      {
        job.done.wait()
        geometry.view.reframing = nil
      }

      geometry.view.camera = camera
      let staticMeshes = geometry.meshes.values.filter { !geometry.animated.contains($0.key) }
      let inUse = Set(geometry.meshes.values.map(\.instancesKey))
      geometry.instanceSets = geometry.instanceSets.filter { inUse.contains($0.key) }
      let inputs = ChooseInputs(meshes: staticMeshes, camera: camera, budget: uniqueTriangleBudget(),
                                details: geometry.details, staticKey: geometry.record.staticKey,
                                instancedKey: geometry.staticInstancedCapture == nil ? nil : geometry.record.instancedKey,
                                faces: ptex.faces.count, expands: geometry.staticShadowCapture != nil,
                                staticRecorder: geometry.staticRecorder, instancedRecorder: geometry.instancedRecorder,
                                ptexFaces: ptex.faces)
      if reframes, geometry.record.count > 1
      {
        // the captures keep drawing what they were chosen for while a camera's reframe chooses and builds.
        let job = Reframing()
        geometry.view.reframing = job
        job.done.enter()
        DispatchQueue.global(qos: .userInitiated).async
        {
          job.chosen = Self.choose(inputs)
          job.done.leave()
        }
      }
      else
      {
        apply(Self.choose(inputs))
      }
    }
  }

  private func deformDynamic(dynamics: Bool, into dynamicCapture: LabGLCaptureBuffer)
  {
    if !dynamics
    {
      geometry.deformer.settle()
    }
    else
    {
      let dynamicMeshes = geometry.animated.compactMap { geometry.meshes[$0] }
      let shownMeshes = geometry.hidden.isEmpty ? dynamicMeshes : dynamicMeshes.filter { !geometry.hidden.contains($0.key) }
      if geometry.deformer.needsRebuild(dynamicMeshes)
      {
        geometry.deformer.rebuild(dynamicMeshes, into: dynamicCapture)
        geometry.record.rebuilds += 1
        geometry.record.rebuiltAt = Date()
      }

      let deformed = geometry.deformer.update(shownMeshes)
      geometry.dynamicBatch = BatchSummary(bounds: deformed.bounds, casterBounds: deformed.casterBounds,
                                           casterKeys: deformed.casterKeys)
    }
  }

  private func updateSceneBounds()
  {
    let batches = [geometry.staticBatch, geometry.instancedBatch, geometry.dynamicBatch]
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    for next in batches.compactMap(\.bounds)
    {
      bounds = bounds.map { (min: pointwiseMin($0.min, next.min), max: pointwiseMax($0.max, next.max)) } ?? next
    }
    // building and simplifying leave gigabytes of freed scratch the allocator would otherwise keep.
    malloc_zone_pressure_relief(nil, 0)
    sceneBounds = bounds
    shadows.staticCasters = [(geometry.staticBatch.casterBounds, geometry.staticBatch.casterKeys),
                     (geometry.instancedBatch.casterBounds, geometry.instancedBatch.casterKeys)]
    shadows.dynamicCasters = [(geometry.dynamicBatch.casterBounds, geometry.dynamicBatch.casterKeys)]
  }
}
