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

public extension Akari.GPU
{
  /// The Hgi handed to Akari by Hydra, used only to
  /// wrap LabGL's final color texture into the color
  /// AOV for presentation.
  final class HydraContext
  {
    public let backend: Akari.GPU.Backend
    public let hgi: UnsafeMutableRawPointer?

    public init(hgi: UnsafeMutableRawPointer?, backend: Akari.GPU.Backend)
    {
      self.hgi = hgi
      self.backend = backend
    }
  }

  /// The AOV render buffers Hydra wants Akari to fill.
  struct HydraTarget
  {
    public var color: UnsafeMutableRawPointer?
    public var depth: UnsafeMutableRawPointer?
    public var width: Int
    public var height: Int
  }
}

public extension Akari
{
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
}

public extension Akari.GPU
{
  /// Immutable per frame data for a pass.
  struct FrameContext: @unchecked Sendable
  {
    public let gpu: Akari.GPU.HydraContext
    public let labfx: Akari.LabFXEngine
    public let camera: Akari.Camera
    /// `camera` without the TAA sub pixel jitter, for reprojection.
    public let unjitteredCamera: Akari.Camera
    public let target: Akari.GPU.HydraTarget
    public let settings: RenderSettings
    public let frameIndex: UInt64
    /// True when the camera moved since the last frame
    /// (so TAA doesn't ghost behind the view change).
    public let cameraMoved: Bool
    /// True when rendering for output (still) rather than interaction.
    public let isFinalRender: Bool
    /// Opaque `HdAkariRenderParam`.
    public let renderParam: Pixar.HdAkariRenderParam
  }

  /// Mutable per frame state.
  struct FrameState
  {
    public var target: Akari.GPU.HydraTarget
    public var resources: [RenderTargetID: RenderTargetDesc] = [:]

    public init(target: Akari.GPU.HydraTarget)
    {
      self.target = target
    }

    public mutating func declare(_ id: Akari.GPU.RenderTargetID, _ desc: Akari.GPU.RenderTargetDesc)
    {
      resources[id] = desc
    }
  }

  /// Named transient targets passed between stages.
  enum RenderTargetID: String, Sendable
  {
    case gbufferAlbedo, gbufferNormal, gbufferMaterial, depth
    case ambientOcclusion
    case sceneColorHDR
    case screenSpaceGI
    case volumeScatter, volumeIntegrated
    case reflections
    case history
    case bloomChain
  }

  struct RenderTargetDesc: Sendable
  {
    public var width: Int
    public var height: Int
    public var format: Akari.GPU.RenderTargetFormat
    public var scale: Float
    public init(width: Int, height: Int, format: Akari.GPU.RenderTargetFormat, scale: Float = 1)
    {
      self.width = width
      self.height = height
      self.format = format
      self.scale = scale
    }
  }

  enum RenderTargetFormat: Sendable
  {
    case rgba8, rgba16f, rgba32f, r16f, rg16f, depth32f
  }

  /// One node in the frame graph.
  protocol RenderPassNode: Sendable
  {
    var id: RenderPassID { get }
    func isEnabled(for settings: RenderSettings) -> Bool
    func execute(_ state: inout Akari.GPU.FrameState, _ ctx: Akari.GPU.FrameContext)
  }
}

public extension Akari.GPU.RenderPassNode
{
  func isEnabled(for _: RenderSettings) -> Bool
  {
    true
  }
}
