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
  /// uploads the shared material, color, normal and emissive texture atlases to the gpu.
  final class MaterialAtlas
  {
    private var materialTexture: GLuint = 0
    private var colorTexture: GLuint = 0
    private var normalTexture: GLuint = 0
    private var emissiveTexture: GLuint = 0
    /// the block format each compressed texture uploads as, a quarter of rgba8's memory, their mips built here
    private var compressedTextures: [GLuint: Akari.GPU.Capabilities.TextureCompression] = [:]
    /// each atlas texture's storage size, so a resized atlas gets new storage.
    private var storageSize: [GLuint: SIMD2<Int>] = [:]
    /// untextured materials constants, `HdAkariConstantTexels()` RGBA32F texels a row.
    private var constantsTexture: GLuint = 0
    private var constantsRows = 0
    /// small stand ins until a textured material bakes a cell, so everything binding the atlas has a texture
    private var placeholders = Set<GLuint>()

    /// constant rows whose glow already lights the scene as a mesh light, so light gathering leaves it out
    public var directRows: Set<Int> = []
    private var uploadedDirectRows: Set<Int> = []

    /// packs material rows across a texture line to stay far under metal's texture height limit however many materials there are
    static let constantsRowsPerLine = 128

    /// mips sampled, as `GL_TEXTURE_MAX_LEVEL` 3 had them.
    private static let levels = 4

    public init() {}

    /// uploads when the atlas is dirty and returns every texture name, 0 until the first upload
    public func uploadIfNeeded(_ atlas: Pixar.HdAkariTextureAtlas) -> (material: GLuint, color: GLuint, normal: GLuint, emissive: GLuint)
    {
      if atlas.ConsumeDirty()
      {
        let width = Int(atlas.Width()), height = Int(atlas.Height())
        let count = Int(atlas.TakeBakedRegions())
        if count > 0
        {
          for (index, texture) in [\MaterialAtlas.materialTexture, \.colorTexture, \.normalTexture, \.emissiveTexture].enumerated()
          {
            ensureStorage(texture, width: width, height: height)
            for i in 0 ..< count
            {
              let region = atlas.BakedRegion(Int32(i))
              guard let pixels = atlas.BakedPixels(Int32(i), Int32(index)) else { continue }
              upload(self[keyPath: texture], pixels: pixels, region: region)
            }

            // labgl only writes level 0 of an uncompressed texture, so its mips are built on the gpu from the uploaded level
            let name = self[keyPath: texture]
            if compressedTextures[name] == nil
            {
              gl.bindTexture(target: GL_TEXTURE_2D, texture: name)
              gl.generateMipmap(GL_TEXTURE_2D)
            }
          }

          // only what was taken lives on the cpu, and only until it's on the gpu.
          atlas.ReleaseUploaded()
        }
      }

      // roughness 1, metallic 0, opaque, white, a flat normal and no emission, in the bgra order labgl lays out
      if materialTexture == 0 { materialTexture = placeholder([255, 0, 255, 0]) }
      if colorTexture == 0 { colorTexture = placeholder([255, 255, 255, 255]) }
      if normalTexture == 0 { normalTexture = placeholder([255, 128, 128, 255]) }
      if emissiveTexture == 0 { emissiveTexture = placeholder([0, 0, 0, 255]) }
      return (materialTexture, colorTexture, normalTexture, emissiveTexture)
    }

    private func placeholder(_ texel: [UInt8]) -> GLuint
    {
      var texture: GLuint = 0
      gl.genTextures(count: 1, textures: &texture)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: texture)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GL_LINEAR)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GL_LINEAR)
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA, width: 4, height: 4, border: 0,
                    format: GL_RGBA, type: GL_UNSIGNED_BYTE, pixels: Array([[UInt8]](repeating: texel, count: 16).joined()))
      placeholders.insert(texture)
      return texture
    }

    /// uploads the constant rows written since the last call, every row when the table outgrew the texture, 0 until there's a row
    public func uploadConstants(_ atlas: Pixar.HdAkariTextureAtlas) -> GLuint
    {
      let texels = Int(Pixar.HdAkariConstantTexels())
      let perLine = Self.constantsRowsPerLine
      let lineTexels = texels * perLine
      let count = Int(atlas.ConstantCount())
      var range = atlas.DrainDirtyConstants()
      guard count > 0 else { return constantsTexture }

      if count > constantsRows
      {
        if constantsTexture != 0 { gl.deleteTextures(count: 1, textures: &constantsTexture) }
        constantsRows = max(constantsRows, perLine)
        while constantsRows < count
        {
          constantsRows *= 2
        }

        gl.genTextures(count: 1, textures: &constantsTexture)
        gl.bindTexture(target: GL_TEXTURE_2D, texture: constantsTexture)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
        gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F,
                      width: GLsizei(lineTexels), height: GLsizei(constantsRows / perLine), border: 0,
                      format: GL_RGBA, type: GL_FLOAT, pixels: nil)
        range.first = 0
        range.count = Int32(count)
      }

      // a row starting or stopping to light the scene goes up again with its mark
      if directRows != uploadedDirectRows
      {
        let changed = directRows.symmetricDifference(uploadedDirectRows).filter { $0 < count }
        uploadedDirectRows = directRows
        if let lo = changed.min(), let hi = changed.max()
        {
          let start = range.count > 0 ? min(Int(range.first), lo) : lo
          let end = range.count > 0 ? max(Int(range.first + range.count), hi + 1) : hi + 1
          range.first = Int32(start)
          range.count = Int32(end - start)
        }
      }

      guard range.count > 0 else { return constantsTexture }

      // upload full rows if any part changed, pad any extra space with zeros.
      let first = Int(range.first)
      let firstLine = first / perLine
      let lastLine = (first + Int(range.count) - 1) / perLine
      let lineCount = lastLine - firstLine + 1
      let lineFirst = firstLine * perLine
      let lineRows = min((lastLine + 1) * perLine, count) - lineFirst
      var rows = [Float](repeating: 0, count: lineCount * lineTexels * 4)
      rows.withUnsafeMutableBufferPointer
      {
        atlas.CopyConstants(Int32(lineFirst), Int32(lineRows), $0.baseAddress!)
      }

      // the last texel's alpha marks a glow that lights the scene directly
      for row in directRows where row >= lineFirst && row < lineFirst + lineRows
      {
        rows[(row - lineFirst) * texels * 4 + texels * 4 - 1] = 1
      }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: constantsTexture)
      gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: 0, yOffset: GLint(firstLine),
                       width: GLsizei(lineTexels), height: GLsizei(lineCount),
                       format: GL_RGBA, type: GL_FLOAT, pixels: rows)
      return constantsTexture
    }

    /// gives `texture` empty storage for the whole atlas, in the best block format this device samples
    private func ensureStorage(_ texture: ReferenceWritableKeyPath<MaterialAtlas, GLuint>, width: Int, height: Int)
    {
      var name = self[keyPath: texture]
      if name != 0, placeholders.remove(name) == nil, storageSize[name] == SIMD2(width, height) { return }
      if name != 0
      {
        compressedTextures[name] = nil
        storageSize[name] = nil
        gl.deleteTextures(count: 1, textures: &name)
      }

      gl.genTextures(count: 1, textures: &name)
      self[keyPath: texture] = name
      storageSize[name] = SIMD2(width, height)
      let block = 4 << (Self.levels - 1)
      if width % block == 0, height % block == 0
      {
        let (w, h, levels) = (Int32(width), Int32(height), Int32(Self.levels))
        switch Akari.GPU.Capabilities.current.textureCompression
        {
          case .bc7 where labgl.textureImageBC7(name, width: w, height: h, levels: levels) != 0:
            compressedTextures[name] = .bc7
            return
          case .astc where ASTC.isAvailable && labgl.textureImageASTC(name, width: w, height: h, levels: levels) != 0:
            compressedTextures[name] = .astc
            return
          default:
            break
        }
      }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: name)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GL_LINEAR_MIPMAP_LINEAR)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GL_LINEAR)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GL_CLAMP_TO_EDGE)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GL_CLAMP_TO_EDGE)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAX_LEVEL, param: GLint(Self.levels - 1))
      for level in 0 ..< Self.levels
      {
        gl.texImage2D(target: GL_TEXTURE_2D, level: GLint(level), internalFormat: GL_RGBA,
                      width: GLsizei(width >> level), height: GLsizei(height >> level), border: 0,
                      format: GL_RGBA, type: GL_UNSIGNED_BYTE, pixels: nil)
      }
    }

    /// uploads one baked region, with its mips when block compressed, whole cells keep every level on whole 4x4 blocks
    private func upload(_ texture: GLuint, pixels: UnsafePointer<UInt8>, region: Pixar.HdAkariAtlasRegion)
    {
      let width = Int(region.width), height = Int(region.height)
      let format = compressedTextures[texture]
      let compressed = format != nil
      if !compressed { gl.bindTexture(target: GL_TEXTURE_2D, texture: texture) }
      var mip: [UInt8] = []
      var blocks: [UInt8] = []
      for level in 0 ..< (compressed ? Self.levels : 1)
      {
        let w = width >> level, h = height >> level
        guard w > 0, h > 0 else { break }
        let x = Int(region.x) >> level, y = Int(region.y) >> level
        if level > 0
        {
          mip = [UInt8](repeating: 0, count: w * h * 4)
          mip.withUnsafeMutableBufferPointer
          {
            Self.downsample(pixels, width: width, height: height, level: level, x0: 0, y0: 0, w: w, h: h,
                            into: $0.baseAddress!)
          }
        }

        let encode = { (source: UnsafePointer<UInt8>) in
          if let format
          {
            // both formats pack a 4x4 block into 16 bytes, so the blocks take a byte per texel
            blocks = [UInt8](repeating: 0, count: w * h)
            blocks.withUnsafeMutableBufferPointer
            {
              if format == .astc
              {
                if !ASTC.encode(source, stride: w, width: w, height: h, into: $0.baseAddress!)
                {
                  print("[akari/atlas] astc encode of a \(w)x\(h) region failed, it samples as black")
                }
              }
              else
              {
                BC7.encode(source, stride: w, width: w, height: h, into: $0.baseAddress!)
              }
            }

            if format == .astc
            {
              _ = labgl.textureSubImageASTC(texture, level: Int32(level), x: Int32(x), y: Int32(y),
                                            width: Int32(w), height: Int32(h), blocks: blocks)
            }
            else
            {
              _ = labgl.textureSubImageBC7(texture, level: Int32(level), x: Int32(x), y: Int32(y),
                                           width: Int32(w), height: Int32(h), blocks: blocks)
            }
          }
          else
          {
            gl.texSubImage2D(target: GL_TEXTURE_2D, level: GLint(level), xOffset: GLint(x), yOffset: GLint(y),
                             width: GLsizei(w), height: GLsizei(h), format: GL_RGBA, type: GL_UNSIGNED_BYTE,
                             pixels: UnsafeRawPointer(source))
          }
        }

        if level == 0 { encode(pixels) } else { mip.withUnsafeBufferPointer { encode($0.baseAddress!) } }
      }
    }

    /// the box filtered mip `level` of a region, straight from level 0.
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
