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

import CoreGraphics
import Foundation
import ImageIO
import simd

extension Kraken
{
  /// an image to sculpt and paint from, kept as display rgba bytes top row first
  struct SculptReference: @unchecked Sendable
  {
    let url: URL
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(url: URL)
    {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }

      let width = image.width, height = image.height
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      let drawn = bytes.withUnsafeMutableBytes
      { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }

      guard drawn else { return nil }
      self.width = width
      self.height = height
      pixels = bytes
      self.url = url
    }

    var aspect: Float
    {
      Float(width) / Float(max(height, 1))
    }

    /// the color under a point of the image, blended between pixels, nil off its edge
    func sample(_ u: Float, _ v: Float) -> SIMD4<Float>?
    {
      guard u >= 0, v >= 0, u <= 1, v <= 1 else { return nil }
      let x = u * Float(width - 1), y = v * Float(height - 1)
      let x0 = Int(x), y0 = Int(y)
      let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
      let fx = x - Float(x0), fy = y - Float(y0)

      func at(_ x: Int, _ y: Int) -> SIMD4<Float>
      {
        let i = (y * width + x) * 4
        return SIMD4(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), Float(pixels[i + 3]))
      }

      let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
      let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
      return top * (1 - fy) + bottom * fy
    }

    /// where a viewport point lands on the image when the image is fitted inside a viewport of `aspect`
    func imagePoint(viewport point: SIMD2<Float>, aspect viewportAspect: Float) -> SIMD2<Float>
    {
      if aspect < viewportAspect { return SIMD2((point.x - 0.5) * (viewportAspect / aspect) + 0.5, point.y) }
      return SIMD2(point.x, (point.y - 0.5) * (aspect / viewportAspect) + 0.5)
    }
  }
}

extension Kraken.Sculpt
{
  /// loads an image to sculpt and paint from
  func loadReference(_ url: URL)
  {
    guard let image = Kraken.SculptReference(url: url) else
    {
      status = "Couldn't read \(url.lastPathComponent)"
      return
    }

    reference = image
    showsReference = true
    referenceRevision += 1
    revision += 1
    status = "Reference \(url.lastPathComponent)"
  }

  func chooseReference()
  {
    Kraken.Dialogs.openImage { [weak self] url in self?.loadReference(url) }
  }

  func clearReference()
  {
    reference = nil
    referenceRevision += 1
    revision += 1
  }

  /// projects from the sculpt viewport's own camera, framed as the overlay shows it
  func projectReferenceFromView()
  {
    guard let viewport else { return }
    let size = viewport.bounds.size
    projectReference(camera: viewport.camera, aspect: Float(size.width / max(size.height, 1)))
  }

  /// paints the reference onto the surface the camera sees, the way a matte painting is projected onto set geometry
  func projectReference(camera: Kraken.SculptCamera, aspect: Float, strength: Float = 1)
  {
    settle()
    guard let reference else
    {
      status = "Load a reference image first"
      return
    }

    // the camera looks at the scene, the paint lands on voxels in the sculpt's own space
    let volume = volume
    let viewProjection = camera.projection(aspect: aspect) * camera.view * frame
    let seenFrom = frame.inverse * SIMD4(camera.eye, 1)
    let eye = SIMD3(seenFrom.x, seenFrom.y, seenFrom.z)
    let voxel = volume.voxel
    let keys = Array(volume.bricks.keys)
    let side = Kraken.SculptBrick.side

    // read everything first across every core, the volume doesn't change until the colors go on
    var found = [[(Int, SIMD4<UInt8>)]](repeating: [], count: keys.count)
    found.withUnsafeMutableBufferPointer
    { found in
      DispatchQueue.concurrentPerform(iterations: keys.count)
      { i in
        guard let brick = volume.bricks[keys[i]] else { return }
        let origin = keys[i] &* side
        var out: [(Int, SIMD4<UInt8>)] = []

        for z in 0 ..< side
        {
          for y in 0 ..< side
          {
            for x in 0 ..< side
            {
              let index = Kraken.SculptBrick.index(x, y, z)
              guard abs(brick.distance[index]) < voxel * 1.8 else { continue }

              let p = SIMD3<Float>(origin &+ SIMD3(x, y, z)) * voxel
              let clip = viewProjection * SIMD4(p, 1)
              guard clip.w > 1e-5 else { continue }
              let ndc = SIMD2(clip.x, clip.y) / clip.w
              let point = reference.imagePoint(viewport: SIMD2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5), aspect: aspect)
              guard let color = reference.sample(point.x, point.y) else { continue }

              // only what faces the camera and nothing hides takes the paint
              let toEye = simd_normalize(eye - p)
              let facing = simd_dot(volume.normal(p), toEye)
              guard facing > 0.12 else { continue }
              if volume.raycast(origin: p + toEye * voxel * 2.5, direction: toEye, maxDistance: simd_distance(eye, p)) != nil { continue }

              let w = min(max((facing - 0.12) / 0.35, 0), 1) * strength
              let kept = SIMD4<Float>(brick.color[index])
              let laid = SIMD4(color.x, color.y, color.z, kept.w)
              out.append((index, SIMD4<UInt8>((kept * (1 - w) + laid * w).rounded(.toNearestOrAwayFromZero))))
            }
          }
        }

        found[i] = out
      }
    }

    var record: [SIMD3<Int32>: Kraken.SculptBrickState] = [:]
    var touched: [SIMD3<Int32>] = []
    for (i, k) in keys.enumerated() where !found[i].isEmpty
    {
      guard let brick = volume.bricks[k] else { continue }
      record[k] = volume.state(k)
      for (index, color) in found[i] { brick.color[index] = color }
      touched.append(k)
    }

    guard !touched.isEmpty else
    {
      status = "Nothing in view to paint"
      return
    }

    projection = (camera, aspect)
    markDirty(touched)
    pushStep(.volume(record))
    status = "Projected \(reference.url.lastPathComponent) onto \(touched.count) bricks"
    scheduleWrite()
  }
}
