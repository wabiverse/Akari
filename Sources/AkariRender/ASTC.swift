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

#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

public extension Akari
{
  /// astc 4x4 compression through the system encoder, the block format every apple gpu samples
  enum ASTC
  {
    /// bytes a 4x4 block encodes to, the same as bc7
    public static let blockBytes = 16

    /// the khronos internal format of ldr astc 4x4 blocks
    private static let internalFormat: UInt32 = 0x93B0

    /// whether the system encoder hands back 4x4 blocks here, checked once on a single block
    public static let isAvailable: Bool =
    {
      let texels = [UInt8](repeating: 128, count: 4 * 4 * 4)
      var block = [UInt8](repeating: 0, count: blockBytes)
      return texels.withUnsafeBufferPointer { source in
        block.withUnsafeMutableBufferPointer { encode(source.baseAddress!, stride: 4, width: 4, height: 4, into: $0.baseAddress!) }
      }
    }()

    /// encodes a region of bgra8 pixels as labgl's 8 bit textures hold them into a row of blocks, both sizes multiples of 4
    @discardableResult
    public static func encode(_ pixels: UnsafePointer<UInt8>,
                              stride: Int, width: Int, height: Int,
                              into blocks: UnsafeMutablePointer<UInt8>) -> Bool
    {
      #if canImport(ImageIO)
        guard width % 4 == 0, height % 4 == 0,
              let provider = CGDataProvider(dataInfo: nil, data: pixels, size: stride * height * 4, releaseData: { _, _, _ in }),
              // tagged srgb so the encoder keeps the bytes as they are, they hold data as often as color
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return false }

        let ktx = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(ktx, "org.khronos.ktx" as CFString, 1, nil) else { return false }
        var properties: [CFString: Any] = [kCGImagePropertyEncoder: kCGImagePropertyASTCEncoder]
        if #available(macOS 16, iOS 19, *)
        {
          properties[kCGImagePropertyASTCBlockSize] = kCGImagePropertyASTCBlockSize4x4
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }

        return levelZero(of: ktx as Data, width: width, height: height, into: blocks)
      #else
        return false
      #endif
    }

    /// copies the first level's blocks out of a ktx 1 file, after checking it holds astc 4x4 at the expected size
    private static func levelZero(of ktx: Data, width: Int, height: Int, into blocks: UnsafeMutablePointer<UInt8>) -> Bool
    {
      let expected = (width / 4) * (height / 4) * blockBytes
      return ktx.withUnsafeBytes
      { raw in
        func word(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }

        // the 12 byte identifier, then thirteen words of header with the key value bytes last
        guard raw.count >= 64, raw[1] == 0x4B, raw[2] == 0x54, raw[3] == 0x58, word(12) == 0x0403_0201,
              word(28) == internalFormat
        else { return false }

        let start = 64 + Int(word(60))
        guard raw.count >= start + 4, Int(word(start)) == expected, raw.count >= start + 4 + expected else { return false }
        blocks.update(from: raw.baseAddress!.advanced(by: start + 4).assumingMemoryBound(to: UInt8.self), count: expected)
        return true
      }
    }
  }
}
