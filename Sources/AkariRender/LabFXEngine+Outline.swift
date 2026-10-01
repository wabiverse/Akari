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
import LabFX
import LabGL

public extension Akari
{
  /// What the viewport outlines.
  struct Selection
  {
    /// Per prim id, the object its outline groups it into, `0` when unselected.
    public var labels: [Int32]
    /// Outlines every prim, `labels` only splits it into objects.
    public var all: Bool
    /// RGBA, 0...1.
    public var color: SIMD4<Float>
    /// In pixels.
    public var width: Int32

    public init(labels: [Int32], all: Bool, color: SIMD4<Float>, width: Int32)
    {
      self.labels = labels
      self.all = all
      self.color = color
      self.width = width
    }
  }
}

extension Akari.LabFXEngine
{
  /// The selection outline, drawn like an overlay.
  struct Outline
  {
    var labels: [Int32] = []
    var texture: GLuint = 0
    var textureWidth = 0
    var all = false
    var passesActive = true
    /// The selected meshes, rerecorded when the selection or one of them changes.
    var capture: LabGLCaptureBuffer?
    let recorder = Akari.Geom.Recorder()
    var batch = BatchSummary()
    var needsRecord = true
    var projection = Akari.Matrix4.identity
    var sceneProjection = Akari.Matrix4.identity
  }

  static let outlinePassNames = [
    "outline mask",
    "outline edge",
    "outline span",
    "outline"
  ]

  /// The texture the outline passes leave the final image in.
  var outlinedTexture: GLuint
  {
    outline.passesActive ? runtime.texture("outline", named: "outline") : runtime.texture("tonemap", named: "tonemap")
  }

  func createOutlineCapture() -> Bool
  {
    guard let capture = labgl.captureCreate() else { return false }
    outline.capture = capture
    runtime.setPassCallback("draw-outline-mask", callback: akariOutlineMaskCallback,
                            userdata: Unmanaged.passUnretained(self).toOpaque())
    return true
  }

  /// Uploads the selection's labels when they changed and toggles the outline passes.
  ///
  /// - Parameters:
  ///   - selection: what to outline, if anything.
  ///   - projection: the unjittered camera projection the mask is drawn with.
  ///   - sceneProjection: the jittered one the scene is drawn with.
  func updateOutline(_ selection: Akari.Selection?, projection: Akari.Matrix4, sceneProjection: Akari.Matrix4)
  {
    if (selection != nil) != outline.passesActive
    {
      outline.passesActive = selection != nil
      outline.needsRecord = true
      setPasses(Self.outlinePassNames, active: outline.passesActive)
    }
    guard let selection else { return }

    if outline.texture == 0 || selection.labels != outline.labels || selection.all != outline.all
    {
      uploadOutlineLabels(selection.labels)
      outline.all = selection.all
      outline.needsRecord = true
    }
    outline.projection = Akari.Matrix4.reversedDepth(projection)
    outline.sceneProjection = Akari.Matrix4.reversedDepth(sceneProjection)

    setSampler("u_outlineLabels", outline.texture)
    setVector("u_outline", SIMD4(0, Float(outline.textureWidth),
                                 Float(selection.labels.count), Float(selection.width)))
    setVector("u_outlineColor", selection.color)
  }

  /// Rerecords the selected meshes when the selection changed or one
  /// of them moved. Select all draws the scene captures instead.
  func recordOutline(_ meshes: [Akari.Geom.Recorder.RawMesh])
  {
    guard let capture = outline.capture, outline.passesActive else { return }
    guard !outline.all else { outline.needsRecord = false; return }

    let selected = meshes.filter
    { mesh in
      Int(mesh.primId) < outline.labels.count && mesh.primId >= 0 && outline.labels[Int(mesh.primId)] > 0
    }
    let moved = selected.contains { geometry.changes[$0.id]?.record == geometry.records }
    guard outline.needsRecord || moved else { return }

    outline.needsRecord = false
    outline.batch = recordBatch(selected, into: capture, recorder: outline.recorder)
  }

  func releaseOutline()
  {
    if outline.texture != 0
    {
      gl.deleteTextures(count: 1, textures: &outline.texture)
    }
    if let capture = outline.capture
    {
      labgl.captureDestroy(capture)
    }
    outline = Outline()
  }

  fileprivate func drawOutlineMask()
  {
    let captures = outline.all ? geometry.captures
                               : outline.batch.isEmpty ? [] : [outline.capture].compactMap(\.self)
    guard !captures.isEmpty else { return }

    gl.matrixMode(GL_PROJECTION)
    gl.loadMatrix(outline.projection.m)
    gl.matrixMode(GL_MODELVIEW)
    for capture in captures
    {
      labgl_capturePlaybackIndirect(capture)
    }
    gl.matrixMode(GL_PROJECTION)
    gl.loadMatrix(outline.sceneProjection.m)
    gl.matrixMode(GL_MODELVIEW)
  }

  private func uploadOutlineLabels(_ labels: [Int32])
  {
    outline.labels = labels

    let count = max(labels.count, 1)
    let width = min(count, 4096)
    let height = (count + width - 1) / width
    var pixels = [Float](repeating: 0, count: width * height)
    for (i, label) in labels.enumerated()
    {
      pixels[i] = Float(label)
    }

    if outline.texture == 0
    {
      gl.genTextures(count: 1, textures: &outline.texture)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: outline.texture)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
    }
    gl.bindTexture(target: GL_TEXTURE_2D, texture: outline.texture)

    pixels.withUnsafeBufferPointer
    { buf in
      gl.texImage2D(target: GL_TEXTURE_2D,
                    level: 0,
                    internalFormat: GLint(GL_R32F),
                    width: GLsizei(width),
                    height: GLsizei(height),
                    border: 0,
                    format: GLenum(GL_RED),
                    type: GL_FLOAT,
                    pixels: buf.baseAddress)
    }
    gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
    outline.textureWidth = width
  }
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariOutlineMaskCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawOutlineMask()
}
