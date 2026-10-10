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
import LabGL

public extension Akari
{
  /// Uploads the shared material, color, normal and emissive texture atlases to the GPU.
  final class MaterialAtlas
  {
    private var materialTexture: GLuint = 0
    private var colorTexture: GLuint = 0
    private var normalTexture: GLuint = 0
    private var emissiveTexture: GLuint = 0
    /// The textures uploaded as BC7, a quarter of RGBA8's memory, their mips built here.
    private var compressedTextures = Set<GLuint>()

    /// Mips sampled, as `GL_TEXTURE_MAX_LEVEL` 3 had them.
    private static let levels = 4

    public init() {}

    /// Reuploads when the atlas is dirty, returns every
    /// texture name (0 until the first upload).
    public func uploadIfNeeded(_ atlas: Pixar.HdAkariTextureAtlas) -> (material: GLuint, color: GLuint, normal: GLuint, emissive: GLuint)
    {
      if atlas.ConsumeDirty()
      {
        let width = GLsizei(atlas.Width())
        let height = GLsizei(atlas.Height())
        let rects = Array(atlas.DrainDirtyRects())
        upload(&materialTexture, pixels: atlas.PixelData(), width: width, height: height, rects: rects)
        upload(&colorTexture, pixels: atlas.ColorPixelData(), width: width, height: height, rects: rects)
        upload(&normalTexture, pixels: atlas.NormalPixelData(), width: width, height: height, rects: rects)
        upload(&emissiveTexture, pixels: atlas.EmissivePixelData(), width: width, height: height, rects: rects)
      }
      atlas.ReleasePixelsIfIdle()
      return (materialTexture, colorTexture, normalTexture, emissiveTexture)
    }

    /// Uploads a texture atlas's pixels to `texture`, the
    /// whole atlas the first time and just `rects` after.
    private func upload(_ texture: inout GLuint, pixels: UnsafePointer<UInt8>?,
                        width: Int32, height: Int32, rects: [Pixar.HdAkariAtlasRect])
    {
      guard let pixels else { return }
      if uploadCompressed(&texture, pixels: pixels, width: Int(width), height: Int(height), rects: rects) { return }
      if texture != 0
      {
        guard !rects.isEmpty else { return }
        gl.bindTexture(target: GL_TEXTURE_2D, texture: texture)
        var region: [UInt8] = []
        for rect in rects
        {
          let size = Int(rect.size)
          region.removeAll(keepingCapacity: true)
          for row in 0 ..< size
          {
            let start = ((Int(rect.y) + row) * Int(width) + Int(rect.x)) * 4
            region.append(contentsOf: UnsafeBufferPointer(start: pixels + start, count: size * 4))
          }
          gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: rect.x, yOffset: rect.y,
                           width: rect.size, height: rect.size, format: GL_RGBA, type: GL_UNSIGNED_BYTE,
                           pixels: region)
        }
        gl.generateMipmap(GL_TEXTURE_2D)
        return
      }

      var tex: GLuint = 0
      gl.genTextures(count: 1, textures: &tex)
      texture = tex

      gl.bindTexture(target: GL_TEXTURE_2D, texture: texture)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GL_LINEAR_MIPMAP_LINEAR)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GL_LINEAR)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GL_CLAMP_TO_EDGE)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GL_CLAMP_TO_EDGE)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAX_LEVEL, param: GLint(3))
      gl.texImage2D(target: GL_TEXTURE_2D,
                    level: 0,
                    internalFormat: GL_RGBA,
                    width: width,
                    height: height,
                    border: 0,
                    format: GL_RGBA,
                    type: GL_UNSIGNED_BYTE,
                    pixels: pixels)
      gl.generateMipmap(GL_TEXTURE_2D)
    }

    /// BC7 uploads where the backend has them and every mip divides into whole blocks,
    /// false to fall back to RGBA8.
    private func uploadCompressed(_ texture: inout GLuint, pixels: UnsafePointer<UInt8>,
                                  width: Int, height: Int, rects: [Pixar.HdAkariAtlasRect]) -> Bool
    {
      if texture != 0
      {
        guard compressedTextures.contains(texture) else { return false }
        for rect in rects
        {
          for level in 0 ..< Self.levels
          {
            encode(texture, pixels, width: width, height: height, level: level,
                   x: Int(rect.x), y: Int(rect.y), size: (Int(rect.size), Int(rect.size)), late: true)
          }
        }
        return true
      }

      let block = 4 << (Self.levels - 1)
      guard
        width % block == 0,
        height % block == 0,
        labgl.textureCompressionSupported() != 0
      else { return false }

      var tex: GLuint = 0
      gl.genTextures(count: 1, textures: &tex)
      guard labgl.textureImageBC7(tex, width: Int32(width), height: Int32(height), levels: Int32(Self.levels)) != 0
      else
      {
        gl.deleteTextures(count: 1, textures: &tex)
        return false
      }
      texture = tex
      compressedTextures.insert(tex)
      for level in 0 ..< Self.levels
      {
        encode(tex, pixels, width: width, height: height, level: level, x: 0, y: 0, size: (width, height),
               late: false)
      }
      return true
    }

    /// Encodes what a level-0 region covers at `level`, grown to whole blocks. A `late` region's
    /// pixels may be all the atlas still holds, its neighbors then come back from the texture.
    private func encode(_ texture: GLuint, _ pixels: UnsafePointer<UInt8>, width: Int, height: Int, level: Int,
                        x: Int, y: Int, size: (Int, Int), late: Bool)
    {
      let levelWidth = width >> level, levelHeight = height >> level
      let x0 = (x >> level) & ~3, y0 = (y >> level) & ~3
      let x1 = min((((x + size.0 + (1 << level) - 1) >> level) + 3) & ~3, levelWidth)
      let y1 = min((((y + size.1 + (1 << level) - 1) >> level) + 3) & ~3, levelHeight)
      let w = x1 - x0, h = y1 - y0
      guard w > 0, h > 0 else { return }

      var blocks = [UInt8](repeating: 0, count: w * h)
      blocks.withUnsafeMutableBufferPointer
      { out in
        if level == 0
        {
          BC7.encode(pixels + (y0 * width + x0) * 4, stride: width, width: w, height: h, into: out.baseAddress!)
          return
        }
        var mip = [UInt8](repeating: 0, count: w * h * 4)
        if late
        {
          let source = Self.lateSource(texture, pixels, width: width, level: level, x0: x0, y0: y0, w: w, h: h,
                                       rect: (x, y, size.0, size.1))
          mip.withUnsafeMutableBufferPointer
          { dst in
            source.withUnsafeBufferPointer
            {
              Self.downsample($0.baseAddress!, width: w << level, height: h << level, level: level,
                              x0: 0, y0: 0, w: w, h: h, into: dst.baseAddress!)
            }
          }
        }
        else
        {
          mip.withUnsafeMutableBufferPointer
          { dst in
            Self.downsample(pixels, width: width, height: height, level: level, x0: x0, y0: y0, w: w, h: h,
                            into: dst.baseAddress!)
          }
        }
        mip.withUnsafeBufferPointer
        {
          BC7.encode($0.baseAddress!, stride: w, width: w, height: h, into: out.baseAddress!)
        }
      }
      _ = labgl.textureSubImageBC7(texture, level: Int32(level), x: Int32(x0), y: Int32(y0),
                                   width: Int32(w), height: Int32(h), blocks: blocks)
    }

    /// The level-0 pixels a late region's mip filters down from: what level 0
    /// already holds on the GPU, the region itself fresh from `pixels`.
    private static func lateSource(_ texture: GLuint, _ pixels: UnsafePointer<UInt8>, width: Int, level: Int,
                                   x0: Int, y0: Int, w: Int, h: Int, rect: (Int, Int, Int, Int)) -> [UInt8]
    {
      let sx = x0 << level, sy = y0 << level
      let sw = w << level, sh = h << level
      var source = [UInt8](repeating: 0, count: sw * sh * 4)
      var blocks = [UInt8](repeating: 0, count: sw * sh)
      if labgl.textureGetBC7(texture, level: 0, x: Int32(sx), y: Int32(sy), width: Int32(sw), height: Int32(sh),
                             blocks: &blocks) != 0
      {
        blocks.withUnsafeBufferPointer
        { b in
          source.withUnsafeMutableBufferPointer
          {
            BC7.decode(b.baseAddress!, width: sw, height: sh, into: $0.baseAddress!, stride: sw)
          }
        }
      }
      let rx0 = max(rect.0, sx), rx1 = min(rect.0 + rect.2, sx + sw)
      let ry0 = max(rect.1, sy), ry1 = min(rect.1 + rect.3, sy + sh)
      guard rx1 > rx0 else { return source }
      source.withUnsafeMutableBufferPointer
      { dst in
        for row in ry0 ..< ry1
        {
          (dst.baseAddress! + ((row - sy) * sw + rx0 - sx) * 4)
            .update(from: pixels + (row * width + rx0) * 4, count: (rx1 - rx0) * 4)
        }
      }
      return source
    }

    /// The box filtered mip `level` of a region, straight from level 0.
    private static func downsample(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, level: Int,
                                   x0: Int, y0: Int, w: Int, h: Int, into dst: UnsafeMutablePointer<UInt8>)
    {
      let f = 1 << level
      let count = UInt32(f * f)
      nonisolated(unsafe) let pixels = pixels, dst = dst
      DispatchQueue.concurrentPerform(iterations: h)
      { row in
        let sy = (y0 + row) * f
        for col in 0 ..< w
        {
          let sx = (x0 + col) * f
          var sum = SIMD4<UInt32>.zero
          for yy in sy ..< min(sy + f, height)
          {
            var p = pixels + (yy * width + sx) * 4
            for _ in sx ..< min(sx + f, width)
            {
              sum &+= SIMD4(UInt32(p[0]), UInt32(p[1]), UInt32(p[2]), UInt32(p[3]))
              p += 4
            }
          }
          let avg = (sum &+ count / 2) / count
          let d = dst + (row * w + col) * 4
          d[0] = UInt8(avg.x)
          d[1] = UInt8(avg.y)
          d[2] = UInt8(avg.z)
          d[3] = UInt8(avg.w)
        }
      }
    }
  }
}
