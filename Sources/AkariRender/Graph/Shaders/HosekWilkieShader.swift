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
  /// cooks the hosek wilkie clear sky into the environment cube, from meshula's clear sky models under the bsd 3 clause license
  struct HosekWilkieShader: ShaderProgram
  {
    let name = "hosek-wilkie"

    var uniforms: [Declaration]
    {
      Uniforms.sunHeight
      Uniforms.sunAzimuth
    }

    var stages: [Stage]
    {
      Stage(.compute, glsl: computeGLSL, msl: computeMSL)
    }

    let computeGLSL = #"""
      const float PI = 3.14159265358979323846;
      const float SKY_SCALE = 0.02;
      const float SKY_CEILING = 4.0;

      // `sunAzimuth` turns the sun from its original bearing, zero keeps the sky as it was
      const float SUN_AZ0 = 0.674742;      // atan2(0.4, 0.5)
      const float SUN_R0  = 0.640312;      // length(vec2(0.4, 0.5))

      vec3 cubeFaceDir(vec2 uv, int face)
      {
        float u = uv.x * 2.0 - 1.0;
        float v = uv.y * 2.0 - 1.0;
        if (face == 0) return normalize(vec3( 1.0, -v, -u));
        if (face == 1) return normalize(vec3(-1.0, -v,  u));
        if (face == 2) return normalize(vec3( u,  1.0, -v));
        if (face == 3) return normalize(vec3( u, -1.0,  v));
        if (face == 4) return normalize(vec3( u, -v,  1.0));
        return normalize(vec3(-u, -v, -1.0));
      }

      float hosekWilkieSkyRadiance(mat3 config, float cosTheta, float gamma)
      {
        cosTheta = max(cosTheta, 0.0);
        float expM = exp(config[1][1] * gamma);
        float rayM = cos(gamma) * cos(gamma);
        float mieM = (1.0 + rayM) / pow(1.0 + config[2][2] * config[2][2]
                     - 2.0 * config[2][2] * cos(gamma), 1.5);
        float zenith = sqrt(cosTheta);
        return (1.0 + config[0][0] * exp(config[0][1] / (cosTheta + 0.01)))
             * (config[0][2] + config[1][0] * expM
                + config[1][2] * rayM + config[2][0] * mieM
                + config[2][1] * zenith);
      }

      void main()
      {
        ivec3 gid = ivec3(gl_GlobalInvocationID);
        ivec2 texel = gid.xy;
        int face = gid.z;
        ivec2 size = imageSize(o_envCube_texture);
        if (texel.x >= size.x || texel.y >= size.y || face >= 6) return;

        float u = (float(texel.x) + 0.5) / float(size.x);
        float v = (float(texel.y) + 0.5) / float(size.y);
        vec3 dir = cubeFaceDir(vec2(u, v), face);

        // `sunHeight` runs from the horizon at 0 to 75 degrees up at 1.
        float sunElevAngle = clamp(sunHeight, 0.0, 1.0) * 75.0 * PI / 180.0;
        float sunAz = SUN_AZ0 + sunAzimuth;
        float sunHoriz = SUN_R0 * cos(sunElevAngle);
        vec3 sunDir = normalize(vec3(sunHoriz * sin(sunAz),
                                     sin(sunElevAngle),
                                     -sunHoriz * cos(sunAz)));

        float skyCosTheta = max(dir.y, 0.001);
        vec3 horizonDir = normalize(vec3(dir.x, 0.0, dir.z));
        float horizonCosTheta = 0.0;

        float cospsiSky = dot(dir, sunDir);
        float gammaSky = acos(clamp(cospsiSky, -1.0, 1.0));

        float cospsiHorizon = dot(horizonDir, sunDir);
        float gammaHorizon = acos(clamp(cospsiHorizon, -1.0, 1.0));

        // blend the model's coefficients for this sun elevation.
        float se = pow(clamp(sunHeight, 0.0, 1.0), 1.0 / 3.0);
        float remE = 1.0 - se;
        float e0 = remE*remE*remE*remE*remE;
        float e1 = 5.0*remE*remE*remE*remE*se;
        float e2 = 10.0*remE*remE*remE*se*se;
        float e3 = 10.0*remE*remE*se*se*se;
        float e4 = 5.0*remE*se*se*se*se;
        float e5 = se*se*se*se*se;

        float r = 0.0, g = 0.0, b = 0.0;
        float r_hor = 0.0, g_hor = 0.0, b_hor = 0.0;

        for (int ch = 0; ch < 3; ch++) {
          int chOff = ch * 1080;
          int radOff = 3240 + ch * 120;
          vec3 c0 = vec3(0.0), c1 = vec3(0.0), c2 = vec3(0.0);

          for (int i = 0; i < 3; i++) {
            int b = chOff + 54 + i;
            float lo = e0*hosek_wilkie_data.values[b] + e1*hosek_wilkie_data.values[b+9]
                     + e2*hosek_wilkie_data.values[b+18] + e3*hosek_wilkie_data.values[b+27]
                     + e4*hosek_wilkie_data.values[b+36] + e5*hosek_wilkie_data.values[b+45];

            int b2 = chOff + 108 + i;
            float hi = e0*hosek_wilkie_data.values[b2] + e1*hosek_wilkie_data.values[b2+9]
                     + e2*hosek_wilkie_data.values[b2+18] + e3*hosek_wilkie_data.values[b2+27]
                     + e4*hosek_wilkie_data.values[b2+36] + e5*hosek_wilkie_data.values[b2+45];
            c0[i] = 0.8 * lo + 0.2 * hi;
          }

          for (int i = 0; i < 3; i++) {
            int b = chOff + 54 + (i+3);
            float lo = e0*hosek_wilkie_data.values[b] + e1*hosek_wilkie_data.values[b+9]
                     + e2*hosek_wilkie_data.values[b+18] + e3*hosek_wilkie_data.values[b+27]
                     + e4*hosek_wilkie_data.values[b+36] + e5*hosek_wilkie_data.values[b+45];

            int b2 = chOff + 108 + (i+3);
            float hi = e0*hosek_wilkie_data.values[b2] + e1*hosek_wilkie_data.values[b2+9]
                     + e2*hosek_wilkie_data.values[b2+18] + e3*hosek_wilkie_data.values[b2+27]
                     + e4*hosek_wilkie_data.values[b2+36] + e5*hosek_wilkie_data.values[b2+45];
            c1[i] = 0.8 * lo + 0.2 * hi;
          }

          for (int i = 0; i < 3; i++) {
            int b = chOff + 54 + (i+6);
            float lo = e0*hosek_wilkie_data.values[b] + e1*hosek_wilkie_data.values[b+9]
                     + e2*hosek_wilkie_data.values[b+18] + e3*hosek_wilkie_data.values[b+27]
                     + e4*hosek_wilkie_data.values[b+36] + e5*hosek_wilkie_data.values[b+45];

            int b2 = chOff + 108 + (i+6);
            float hi = e0*hosek_wilkie_data.values[b2] + e1*hosek_wilkie_data.values[b2+9]
                     + e2*hosek_wilkie_data.values[b2+18] + e3*hosek_wilkie_data.values[b2+27]
                     + e4*hosek_wilkie_data.values[b2+36] + e5*hosek_wilkie_data.values[b2+45];
            c2[i] = 0.8 * lo + 0.2 * hi;
          }

          mat3 cfg = mat3(c0, c1, c2);

          int rb = radOff + 6;
          float radLo = e0*hosek_wilkie_data.values[rb] + e1*hosek_wilkie_data.values[rb+1]
                      + e2*hosek_wilkie_data.values[rb+2] + e3*hosek_wilkie_data.values[rb+3]
                      + e4*hosek_wilkie_data.values[rb+4] + e5*hosek_wilkie_data.values[rb+5];
          rb = radOff + 12;
          float radHi = e0*hosek_wilkie_data.values[rb] + e1*hosek_wilkie_data.values[rb+1]
                      + e2*hosek_wilkie_data.values[rb+2] + e3*hosek_wilkie_data.values[rb+3]
                      + e4*hosek_wilkie_data.values[rb+4] + e5*hosek_wilkie_data.values[rb+5];
          float rad = 0.8 * radLo + 0.2 * radHi;

          float sky = hosekWilkieSkyRadiance(cfg, skyCosTheta, gammaSky) * rad;

          if (ch == 0) r = sky;
          else if (ch == 1) g = sky;
          else b = sky;

          float hor = hosekWilkieSkyRadiance(cfg, horizonCosTheta, gammaHorizon) * rad;
          if (ch == 0) r_hor = hor;
          else if (ch == 1) g_hor = hor;
          else b_hor = hor;
        }

        vec3 skyColor = vec3(r, g, b);
        vec3 horizonColor = vec3(r_hor, g_hor, b_hor);
        float sigma = 0.12;
        float gaussianFactor = exp(-(dir.y * dir.y) / (2.0 * sigma * sigma));
        vec3 blendedColor = mix(skyColor, horizonColor, gaussianFactor * 0.5);

        // the sky fades out as the sun sinks below the horizon.
        float nightFade = smoothstep(-0.3, 0.05, sunHeight);

        imageStore(o_envCube_texture, ivec3(texel, face),
                   vec4(clamp(blendedColor * SKY_SCALE * nightFade, vec3(0.0), vec3(SKY_CEILING)), 1.0));
      }
      """#

    let computeMSL = #"""
      constexpr constant float PI = 3.14159265358979323846;
      constexpr constant float SKY_SCALE = 0.02;
      constexpr constant float SKY_CEILING = 4.0;

      // `sunAzimuth` turns the sun from its original bearing, zero keeps the sky as it was
      constexpr constant float SUN_AZ0 = 0.674742;      // atan2(0.4, 0.5)
      constexpr constant float SUN_R0  = 0.640312;      // length(float2(0.4, 0.5))

      float3 cubeFaceDir(float2 uv, int face)
      {
        float u = uv.x * 2.0 - 1.0;
        float v = uv.y * 2.0 - 1.0;
        if (face == 0) return normalize(float3( 1.0, -v, -u));
        if (face == 1) return normalize(float3(-1.0, -v,  u));
        if (face == 2) return normalize(float3( u,  1.0,  v));
        if (face == 3) return normalize(float3( u, -1.0, -v));
        if (face == 4) return normalize(float3( u, -v,  1.0));
        return normalize(float3(-u, -v, -1.0));
      }

      float hosekWilkieSkyRadiance(float3x3 config, float cosTheta, float gamma)
      {
        cosTheta = max(cosTheta, 0.0);
        float expM = exp(config[1][1] * gamma);
        float rayM = cos(gamma) * cos(gamma);
        float mieM = (1.0 + rayM) / pow(1.0 + config[2][2] * config[2][2]
                     - 2.0 * config[2][2] * cos(gamma), 1.5);
        float zenith = sqrt(cosTheta);
        return (1.0 + config[0][0] * exp(config[0][1] / (cosTheta + 0.01)))
             * (config[0][2] + config[1][0] * expM
                + config[1][2] * rayM + config[2][0] * mieM
                + config[2][1] * zenith);
      }

      //@main
      {
        uint2 texel = gid.xy;
        uint face = gid.z;
        uint2 size = uint2(o_envCube_texture.get_width(), o_envCube_texture.get_height());
        if (texel.x >= size.x || texel.y >= size.y || face >= 6) return;

        float u = (float(texel.x) + 0.5) / float(size.x);
        float v = (float(texel.y) + 0.5) / float(size.y);
        float3 dir = cubeFaceDir(float2(u, v), int(face));

        // `sunHeight` runs from the horizon at 0 to 75 degrees up at 1.
        float sunElevAngle = clamp(sunHeight, 0.0, 1.0) * 75.0 * PI / 180.0;
        float sunAz = SUN_AZ0 + sunAzimuth;
        float sunHoriz = SUN_R0 * cos(sunElevAngle);
        float3 sunDir = normalize(float3(sunHoriz * sin(sunAz),
                                         sin(sunElevAngle),
                                         -sunHoriz * cos(sunAz)));

        float skyCosTheta = max(dir.y, 0.001);
        float3 horizonDir = normalize(float3(dir.x, 0.0, dir.z));
        float horizonCosTheta = 0.0;

        float cospsiSky = dot(dir, sunDir);
        float gammaSky = acos(clamp(cospsiSky, -1.0, 1.0));

        float cospsiHorizon = dot(horizonDir, sunDir);
        float gammaHorizon = acos(clamp(cospsiHorizon, -1.0, 1.0));

        // blend the model's coefficients for this sun elevation.
        float se = pow(clamp(sunHeight, 0.0, 1.0), 1.0 / 3.0);
        float remE = 1.0 - se;
        float e0 = remE*remE*remE*remE*remE;
        float e1 = 5.0*remE*remE*remE*remE*se;
        float e2 = 10.0*remE*remE*remE*se*se;
        float e3 = 10.0*remE*remE*se*se*se;
        float e4 = 5.0*remE*se*se*se*se;
        float e5 = se*se*se*se*se;

        float r = 0.0, g = 0.0, b = 0.0;
        float r_hor = 0.0, g_hor = 0.0, b_hor = 0.0;

        for (int ch = 0; ch < 3; ch++) {
          int chOff = ch * 1080;
          int radOff = 3240 + ch * 120;
          float3 c0 = float3(0.0), c1 = float3(0.0), c2 = float3(0.0);

          for (int i = 0; i < 3; i++) {
            int b = chOff + 54 + i;
            float lo = e0*hosek_wilkie_data.values[b] + e1*hosek_wilkie_data.values[b+9] + e2*hosek_wilkie_data.values[b+18]
                     + e3*hosek_wilkie_data.values[b+27] + e4*hosek_wilkie_data.values[b+36] + e5*hosek_wilkie_data.values[b+45];

            int b2 = chOff + 108 + i;
            float hi = e0*hosek_wilkie_data.values[b2] + e1*hosek_wilkie_data.values[b2+9] + e2*hosek_wilkie_data.values[b2+18]
                     + e3*hosek_wilkie_data.values[b2+27] + e4*hosek_wilkie_data.values[b2+36] + e5*hosek_wilkie_data.values[b2+45];
            c0[i] = 0.8 * lo + 0.2 * hi;
          }

          for (int i = 0; i < 3; i++) {
            int b = chOff + 54 + (i+3);
            float lo = e0*hosek_wilkie_data.values[b] + e1*hosek_wilkie_data.values[b+9] + e2*hosek_wilkie_data.values[b+18]
                     + e3*hosek_wilkie_data.values[b+27] + e4*hosek_wilkie_data.values[b+36] + e5*hosek_wilkie_data.values[b+45];

            int b2 = chOff + 108 + (i+3);
            float hi = e0*hosek_wilkie_data.values[b2] + e1*hosek_wilkie_data.values[b2+9] + e2*hosek_wilkie_data.values[b2+18]
                     + e3*hosek_wilkie_data.values[b2+27] + e4*hosek_wilkie_data.values[b2+36] + e5*hosek_wilkie_data.values[b2+45];
            c1[i] = 0.8 * lo + 0.2 * hi;
          }

          for (int i = 0; i < 3; i++) {
            int b = chOff + 54 + (i+6);
            float lo = e0*hosek_wilkie_data.values[b] + e1*hosek_wilkie_data.values[b+9] + e2*hosek_wilkie_data.values[b+18]
                     + e3*hosek_wilkie_data.values[b+27] + e4*hosek_wilkie_data.values[b+36] + e5*hosek_wilkie_data.values[b+45];

            int b2 = chOff + 108 + (i+6);
            float hi = e0*hosek_wilkie_data.values[b2] + e1*hosek_wilkie_data.values[b2+9] + e2*hosek_wilkie_data.values[b2+18]
                     + e3*hosek_wilkie_data.values[b2+27] + e4*hosek_wilkie_data.values[b2+36] + e5*hosek_wilkie_data.values[b2+45];
            c2[i] = 0.8 * lo + 0.2 * hi;
          }

          float3x3 cfg = float3x3(c0, c1, c2);

          int rb = radOff + 6;
          float radLo = e0*hosek_wilkie_data.values[rb] + e1*hosek_wilkie_data.values[rb+1] + e2*hosek_wilkie_data.values[rb+2]
                      + e3*hosek_wilkie_data.values[rb+3] + e4*hosek_wilkie_data.values[rb+4] + e5*hosek_wilkie_data.values[rb+5];
          rb = radOff + 12;
          float radHi = e0*hosek_wilkie_data.values[rb] + e1*hosek_wilkie_data.values[rb+1] + e2*hosek_wilkie_data.values[rb+2]
                      + e3*hosek_wilkie_data.values[rb+3] + e4*hosek_wilkie_data.values[rb+4] + e5*hosek_wilkie_data.values[rb+5];
          float rad = 0.8 * radLo + 0.2 * radHi;

          float sky = hosekWilkieSkyRadiance(cfg, skyCosTheta, gammaSky) * rad;

          if (ch == 0) r = sky;
          else if (ch == 1) g = sky;
          else b = sky;

          float hor = hosekWilkieSkyRadiance(cfg, horizonCosTheta, gammaHorizon) * rad;
          if (ch == 0) r_hor = hor;
          else if (ch == 1) g_hor = hor;
          else b_hor = hor;
        }

        float3 skyColor = float3(r, g, b);
        float3 horizonColor = float3(r_hor, g_hor, b_hor);
        float sigma = 0.12;
        float gaussianFactor = exp(-(dir.y * dir.y) / (2.0 * sigma * sigma));
        float3 blendedColor = mix(skyColor, horizonColor, gaussianFactor * 0.5);

        // the sky fades out as the sun sinks below the horizon.
        float nightFade = smoothstep(-0.3, 0.05, sunHeight);

        o_envCube_texture.write(
            half4(half3(clamp(blendedColor * SKY_SCALE * nightFade, float3(0.0), float3(SKY_CEILING))), 1.0h),
            ushort2(texel), ushort(face));
      }
      """#
  }
}
