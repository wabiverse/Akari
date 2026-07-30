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

public extension Akari
{
  /// The Hgi handed to Akari by Hydra, used only to
  /// wrap LabGL's final color texture into the color
  /// AOV for presentation.
  final class GpuContext
  {
    public let backend: GpuBackend
    public let hgi: UnsafeMutableRawPointer?

    public init(hgi: UnsafeMutableRawPointer?, backend: GpuBackend)
    {
      self.hgi = hgi
      self.backend = backend
    }
  }

  /// A 4x4 matrix as 16 row-major floats.
  struct Matrix4: Sendable
  {
    public var m: [Float]
    public init(_ m: [Float])
    {
      self.m = m.count == 16 ? m : Array(repeating: 0, count: 16)
    }

    public static let identity = Matrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
  }

  /// The view the frame is rendered from.
  struct Camera: Sendable
  {
    /// world -> view
    public var view: Matrix4
    /// view -> clip
    public var projection: Matrix4

    public init(view: Matrix4, projection: Matrix4)
    {
      self.view = view
      self.projection = projection
    }
  }

  /// The AOV render buffers Hydra wants Akari to fill.
  struct FrameTarget
  {
    public var color: UnsafeMutableRawPointer?
    public var depth: UnsafeMutableRawPointer?
    public var width: Int
    public var height: Int
  }

  /// Immutable per frame data for a pass.
  struct FrameContext: @unchecked Sendable
  {
    public let gpu: GpuContext
    public let camera: Camera
    public let target: FrameTarget
    public let settings: RenderSettings
    public let frameIndex: UInt64
    /// True when the camera moved since the last frame
    /// (so TAA doesn't ghost behind the view change).
    public let cameraMoved: Bool
    /// True when rendering for output (still) rather than interaction.
    public let isFinalRender: Bool
    /// Opaque `HdAkariRenderParam`.
    public let renderParam: UnsafeMutableRawPointer?
  }

  /// Mutable per frame state.
  struct FrameState
  {
    public var target: FrameTarget
    public var resources: [RenderTargetID: RenderTargetDesc] = [:]

    public init(target: FrameTarget)
    {
      self.target = target
    }

    public mutating func declare(_ id: RenderTargetID, _ desc: RenderTargetDesc)
    {
      resources[id] = desc
    }
  }

  /// Named transient targets passed between stages.
  enum RenderTargetID: String, Sendable
  {
    case gbufferAlbedo, gbufferNormal, gbufferMaterial, depth
    case shadowAtlas
    case ambientOcclusion
    case sceneColorHDR
    case screenSpaceGI
    case reflections
    case history
    case bloomChain
  }

  struct RenderTargetDesc: Sendable
  {
    public var width: Int
    public var height: Int
    public var format: TargetFormat
    public var scale: Float
    public init(width: Int, height: Int, format: TargetFormat, scale: Float = 1)
    {
      self.width = width
      self.height = height
      self.format = format
      self.scale = scale
    }
  }

  enum TargetFormat: Sendable
  {
    case rgba8, rgba16f, rgba32f, r16f, rg16f, depth32f
  }

  /// One node in the frame graph.
  protocol RenderPassNode: Sendable
  {
    var id: RenderPassID { get }
    func isEnabled(for settings: RenderSettings) -> Bool
    func execute(_ state: inout FrameState, _ ctx: FrameContext)
  }
}

public extension Akari.RenderPassNode
{
  func isEnabled(for _: RenderSettings) -> Bool
  {
    true
  }
}
