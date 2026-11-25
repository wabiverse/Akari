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

extension Akari.RenderGraph
{
  /// drawn by the `planet cloud map` pass
  struct PlanetCloudMapShader: FullscreenShader
  {
    let name = "planet-cloud-map"

    var uniforms: [Declaration]
    {
      Uniforms.atmosphere
      Uniforms.planet
      Uniforms.planetTerrain
      Uniforms.planetOcean
      Uniforms.planetClouds
      Uniforms.planetCity
      Uniforms.planetCloudShape
      Uniforms.planetPaletteA
      Uniforms.planetPaletteB
      Uniforms.planetLook
      Uniforms.planetStyle
    }

    let fragmentGLSL = #"""
      void main()
      {
        o_planetCloudMap_texture = vec4(0.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.planetMSL)

      //@main
      {
        // bakes the planet's cloud cover toward every direction whenever the cloud settings change
        Planet pl = makePlanet(u_planet, u_planetTerrain, u_planetOcean, u_planetClouds, u_planetCity, u_planetCloudShape,
                               u_planetPaletteA, u_planetPaletteB, u_planetLook, u_planetStyle);

        float2 uv = gl_FragCoord.xy / float2(4096.0, 2048.0);
        float radius = max(u_atmosphere.y, 1.0);
        float footprint = 2.0 * 3.14159265 * radius / 4096.0;

        o_planetCloudMap_texture = float4(planetClouds(pl, planetFromLatLong(uv), radius, footprint));
      }
      """#
  }
}
