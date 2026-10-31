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
import HdAkari
import LabGL

extension Akari.LabFXEngine
{
  /// Each prim's stylized shading, four texels a prim by prim id, for the mesh pass and the resolve.
  struct Styles
  {
    var revision: UInt64 = .max
    var texture: GLuint = 0
    var capacity = -1
    var assembling = false
    var transparent: Set<Int32> = []
    var emitters: Set<Int32> = []
    var opacity: [Int32: Float] = [:]
  }

  static let stylePrimsPerRow = 512

  /// Uploads the scene's stylized shading when it changed, true when the deformer has to rerun.
  func syncStyles(_ scene: Pixar.HdAkariScene) -> Bool
  {
    let revision = scene.StyleRevision()
    let maxPrimId = Int(geometry.primIds.values.max() ?? 0)
    let capacity = (maxPrimId / Self.stylePrimsPerRow + 1) * Self.stylePrimsPerRow
    guard revision != styles.revision || capacity > styles.capacity || geometry.transparent != styles.transparent
      || geometry.emitters != styles.emitters || geometry.opacity != styles.opacity
    else
    {
      bindStyles()
      return styles.assembling
    }
    styles.revision = revision
    styles.capacity = capacity
    styles.transparent = geometry.transparent
    styles.emitters = geometry.emitters
    styles.opacity = geometry.opacity

    let snapshot = scene.StyleSnapshot()
    let defaults: [Float] = [5, 1, 0, 0.04, 0, 0, 0, -1] + [Float](repeating: 0, count: 24)
    var texels = [Float](repeating: 0, count: capacity * 32)
    for i in 0 ..< capacity
    {
      for k in 0 ..< 32
      {
        texels[i * 32 + k] = defaults[k]
      }
    }
    for id in geometry.transparent where id >= 0 && Int(id) < capacity
    {
      texels[Int(id) * 32 + 17] = 1
    }
    for id in geometry.emitters where id >= 0 && Int(id) < capacity
    {
      texels[Int(id) * 32 + 18] = 1
    }
    for (id, opacity) in geometry.opacity where id >= 0 && Int(id) < capacity
    {
      texels[Int(id) * 32 + 19] = opacity
    }
    var styled = Set<Int32>()
    var assembly: [Int32: SIMD4<Float>] = [:]
    var spacing: [Int32: Float] = [:]
    var sizes: [Int32: Float] = [:]
    for style in snapshot where style.primId >= 0 && Int(style.primId) < capacity
    {
      let values: [Float] = [style.shadingModel, style.color, style.unlit, style.frontBand,
                             style.frontX, style.frontY, style.frontZ, style.frontRadius,
                             style.wireR, style.wireG, style.wireB, style.wireGlow,
                             style.frontGlowR, style.frontGlowG, style.frontGlowB, style.frontGlow,
                             style.wireSpacing, 0, 0, 0]
      for k in 0 ..< values.count where k < 17 || k > 19
      {
        texels[Int(style.primId) * 32 + k] = values[k]
      }
      styled.insert(style.primId)
      assembly[style.primId] = SIMD4(style.assemble, style.centerX, style.centerY, style.centerZ)
      sizes[style.primId] = style.hasCenter ? style.size : -style.size
      if style.wireSpacing > 0 { spacing[style.primId] = style.wireSpacing }
    }
    if styled != geometry.styled
    {
      geometry.styled = styled
      geometry.restyled = true
    }
    geometry.deformer.assembly = assembly
    geometry.deformer.assemblySize = sizes
    if spacing != geometry.deformer.wireSpacing
    {
      geometry.deformer.wireSpacing = spacing
      geometry.restyled = true
      geometry.deformer.relayout = true
    }
    styles.assembling = assembly.values.contains { $0.x < 0.9999 }

    if styles.texture == 0 { gl.genTextures(count: 1, textures: &styles.texture) }
    gl.bindTexture(target: GL_TEXTURE_2D, texture: styles.texture)
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
    gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F,
                  width: GLsizei(Self.stylePrimsPerRow * 8), height: GLsizei(capacity / Self.stylePrimsPerRow), border: 0,
                  format: GL_RGBA, type: GL_FLOAT, pixels: texels)
    bindStyles()
    return true
  }

  private func bindStyles()
  {
    setSampler("u_primStyle", styles.texture)
    shadowAtlas.styles = styles.texture
  }
}
