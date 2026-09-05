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

import CxxStdlib
import Foundation

public class Atlas
{
  /// Semantic RGBA channel (0=R, 1=G, 2=B, 3=A) to its physical byte offset in a
  /// texel. R and B are swapped: LabGL uploads these atlases with `GL_RGBA` onto a
  /// BGRA-ordered native format, so the CPU writer pre-swizzles to match.
  @inline(__always)
  public static func physicalChannel(_ semantic: Int32) -> Int
  {
    switch semantic
    {
      case 0: 2
      case 2: 0
      default: Int(semantic)
    }
  }

  /// Quantizes a [0,1] float to an 8-bit UNORM byte.
  @inline(__always)
  public static func quantize(_ v: Float) -> UInt8
  {
    UInt8(min(max(v, 0), 1) * 255 + 0.5)
  }

  /// Averages one destination texel's footprint in source space.
  @inline(__always)
  static func boxFilterSample(_ src: UnsafePointer<Float>, _ srcW: Int, _ srcH: Int, _ nComp: Int,
                              _ comp: Int, _ destX: Int, _ destW: Int, _ destY: Int, _ destH: Int) -> Float
  {
    let sx0 = (destX * srcW) / destW
    let sx1 = min(srcW, max(sx0 + 1, ((destX + 1) * srcW) / destW))
    let sy0 = (destY * srcH) / destH
    let sy1 = min(srcH, max(sy0 + 1, ((destY + 1) * srcH) / destH))

    var accum = 0.0
    var count = 0
    for sy in sy0 ..< sy1
    {
      for sx in sx0 ..< sx1
      {
        accum += Double(src[(sy * srcW + sx) * nComp + comp])
        count += 1
      }
    }
    return count > 0 ? Float(accum / Double(count)) : 0
  }

  /// Flat-fills one semantic channel of a square region with a constant.
  public static func fillChannel(_ pixels: UnsafeMutablePointer<UInt8>, atlasWidth: Int32,
                                 px0: Int32, py0: Int32, regionSize: Int32,
                                 channel: Int32, value: Float)
  {
    let width = Int(atlasWidth)
    let byte = quantize(value)
    let phys = physicalChannel(channel)

    for y in 0 ..< Int(regionSize)
    {
      for x in 0 ..< Int(regionSize)
      {
        pixels[((Int(py0) + y) * width + (Int(px0) + x)) * 4 + phys] = byte
      }
    }
  }

  /// Flat-fills a square region of the color atlas with a constant RGB, alpha 255.
  public static func fillColorRegion(_ pixels: UnsafeMutablePointer<UInt8>, atlasWidth: Int32,
                                     px0: Int32, py0: Int32, regionSize: Int32,
                                     r: Float, g: Float, b: Float)
  {
    let width = Int(atlasWidth)
    let rb = quantize(r), gb = quantize(g), bb = quantize(b)

    for y in 0 ..< Int(regionSize)
    {
      for x in 0 ..< Int(regionSize)
      {
        let idx = ((Int(py0) + y) * width + (Int(px0) + x)) * 4
        pixels[idx + physicalChannel(0)] = rb
        pixels[idx + 1] = gb
        pixels[idx + physicalChannel(2)] = bb
        pixels[idx + 3] = 255
      }
    }
  }

  /// Resamples one decoded UDIM tile into a sub-rect of one semantic channel.
  /// `srcComponent` selects which component of the source image feeds the channel,
  /// so a packed map (ORM and friends) reads the component it was wired to.
  public static func bakeChannelTile(_ pixels: UnsafeMutablePointer<UInt8>, atlasWidth: Int32,
                                     src: UnsafePointer<Float>, srcW: Int32, srcH: Int32, nComp: Int32,
                                     srcComponent: Int32, channel: Int32,
                                     subX0: Int32, subY0: Int32, subW: Int32, subH: Int32)
  {
    let width = Int(atlasWidth)
    let phys = physicalChannel(channel)
    let comp = min(Int(srcComponent), Int(nComp) - 1)

    for y in 0 ..< Int(subH)
    {
      for x in 0 ..< Int(subW)
      {
        let v = boxFilterSample(src, Int(srcW), Int(srcH), Int(nComp), comp,
                                x, Int(subW), y, Int(subH))
        pixels[((Int(subY0) + y) * width + (Int(subX0) + x)) * 4 + phys] = quantize(v)
      }
    }
  }

  /// Resamples one decoded UDIM tile into a sub-rect of the color atlas.
  /// Grayscale sources replicate their single component across RGB.
  public static func bakeColorTile(_ pixels: UnsafeMutablePointer<UInt8>, atlasWidth: Int32,
                                   src: UnsafePointer<Float>, srcW: Int32, srcH: Int32, nComp: Int32,
                                   subX0: Int32, subY0: Int32, subW: Int32, subH: Int32)
  {
    let width = Int(atlasWidth)
    let w = Int(srcW), h = Int(srcH), n = Int(nComp)

    for y in 0 ..< Int(subH)
    {
      for x in 0 ..< Int(subW)
      {
        let r = boxFilterSample(src, w, h, n, 0, x, Int(subW), y, Int(subH))
        let g = n >= 2 ? boxFilterSample(src, w, h, n, 1, x, Int(subW), y, Int(subH)) : r
        let b = n >= 3 ? boxFilterSample(src, w, h, n, 2, x, Int(subW), y, Int(subH)) : r

        let idx = ((Int(subY0) + y) * width + (Int(subX0) + x)) * 4
        pixels[idx + physicalChannel(0)] = quantize(r)
        pixels[idx + 1] = quantize(g)
        pixels[idx + physicalChannel(2)] = quantize(b)
        pixels[idx + 3] = 255
      }
    }
  }

  /// Replicates the baked interior out into the cell's padding ring so mip
  /// generation never bleeds between neighbouring cells.
  public static func fillCellBorder(_ pixels: UnsafeMutablePointer<UInt8>,
                                    colorPixels: UnsafeMutablePointer<UInt8>,
                                    atlasWidth: Int32,
                                    px0: Int32, py0: Int32, regionSize: Int32, padding: Int32)
  {
    let width = Int(atlasWidth)
    let cx0 = Int(px0) + Int(padding), cx1 = Int(px0) + Int(regionSize) - Int(padding)
    let cy0 = Int(py0) + Int(padding), cy1 = Int(py0) + Int(regionSize) - Int(padding)

    func fill(_ buffer: UnsafeMutablePointer<UInt8>)
    {
      for y in 0 ..< Int(regionSize)
      {
        let py = Int(py0) + y
        let sy = min(max(py, cy0), cy1 - 1)
        for x in 0 ..< Int(regionSize)
        {
          let px = Int(px0) + x
          // interior is already baked.
          if px >= cx0, px < cx1, py >= cy0, py < cy1 { continue }
          let sx = min(max(px, cx0), cx1 - 1)
          let srcIdx = (sy * width + sx) * 4
          let dstIdx = (py * width + px) * 4
          for c in 0 ..< 4
          {
            buffer[dstIdx + c] = buffer[srcIdx + c]
          }
        }
      }
    }
    fill(pixels)
    fill(colorPixels)
  }

  /// Substitutes a UDIM tile number into a "<UDIM>"-templated path.
  /// `u`/`v` are tile grid coordinates (tile 1001 is u=0, v=0).
  public static func resolveUdimTile(_ templatePath: std.string,
                                     _ u: Int32,
                                     _ v: Int32) -> std.string
  {
    let path = String(templatePath)
    guard let marker = path.range(of: "<UDIM>") else { return templatePath }

    let tile = 1001 + Int(u) + Int(v) * 10
    let padded = String(format: "%04d", tile)
    return std.string(path.replacingCharacters(in: marker, with: padded))
  }
}
