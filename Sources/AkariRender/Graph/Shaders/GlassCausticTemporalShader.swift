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
  /// drawn by the `glass caustic temporal` pass.
  struct GlassCausticTemporalShader: FullscreenShader
  {
    let name = "glass-caustic-temporal"

    var uniforms: [Declaration]
    {
      Sampler(GlassSunCausticBuffer.glassSunCaustic)
      Sampler(GlassLocalCausticBuffer.glassLocalCaustic)
      Sampler(GlassCausticHistoryBuffer.glassSunCausticHistory)
      Sampler(GlassCausticHistoryBuffer.glassLocalCausticHistory)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.velocity)
      Uniforms.taa
      Uniforms.invProj
      Uniforms.frameIndex
    }

    // blends the jittered caustics over frames along each pixel's motion so they don't flicker, final renders keep no history

    let fragmentGLSL = #"""
      vec3 causticHistory(sampler2D raw, sampler2D history, ivec2 pixel, ivec2 size, vec2 prevUV, bool fresh, float alpha)
      {
        vec3 current = texelFetch(raw, pixel, 0).rgb;
        vec3 lo = current, hi = current;
        for (int y = -1; y <= 1; ++y) {
          for (int x = -1; x <= 1; ++x) {
            vec3 s = texelFetch(raw, clamp(pixel + ivec2(x, y), ivec2(0), size - 1), 0).rgb;
            lo = min(lo, s);
            hi = max(hi, s);
          }
        }
        vec3 kept = texture(history, clamp(prevUV, 0.0, 1.0)).rgb;
        if (fresh || any(isnan(kept)) || any(lessThan(kept, vec3(0.0)))) return current;
        return mix(clamp(kept, lo * 0.5, hi * 2.0), current, alpha);
      }

      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        ivec2 size = textureSize(u_glassSunCaustic_texture, 0);
        ivec2 gsize = textureSize(u_position_texture, 0);
        vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
        ivec2 g = clamp(ivec2(uv * vec2(gsize)), ivec2(0), gsize - 1);
        float depth = log2(max(-texelFetch(u_position_texture, g, 0).z, 1e-4));
        bool surface = texelFetch(u_normal_texture, g, 0).a >= 0.5;
        bool shutter = u_taa.w > 0.5;
        vec2 prevUV = uv + (shutter ? vec2(0.0) : texelFetch(u_velocity_texture, g, 0).xy);
        bool offscreen = any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));
        float historyDepth = texelFetch(u_glassSunCausticHistory_texture,
                                        clamp(ivec2(prevUV * vec2(size)), ivec2(0), size - 1), 0).a;
        bool uncovered = !shutter && abs(historyDepth - depth) > 0.05;
        bool fresh = !surface || u_taa.x < 0.5 || u_taa.y > 0.5 || offscreen || uncovered;

        // caustics keep ten frames or more since they stay on surfaces the reprojection follows
        float alpha = clamp(u_taa.z, 0.05, 0.1);
        o_glassSunCausticAccum_texture = vec4(causticHistory(u_glassSunCaustic_texture, u_glassSunCausticHistory_texture,
                                                             pixel, size, prevUV, fresh, alpha), depth);
        o_glassLocalCausticAccum_texture = vec4(causticHistory(u_glassLocalCaustic_texture, u_glassLocalCausticHistory_texture,
                                                               pixel, size, prevUV, fresh, alpha), depth);
      }
      """#

    let fragmentMSL = #"""
      // the sun and local light caustics at pixel, softened through one shared disc of taps
      void softCaustics(texture2d<float> sunCaustic, texture2d<float> localCaustic, bool wantSun, bool wantLocal,
                        texture2d<float> positions, texture2d<float> normals, uint2 pixel, float3 posEye, float3 normalEye,
                        float4x4 invProj, float noise, thread float3& sun, thread float3& local)
      {
        sun = float3(0.0);
        local = float3(0.0);
        if (!wantSun && !wantLocal) return;

        // the caustics are smaller than the gbuffer, so the disc walks their pixels and reads each tap's surface at the gbuffer's
        float2 size = float2(sunCaustic.get_width(), sunCaustic.get_height());
        float2 gbufferSize = float2(positions.get_width(), positions.get_height());
        float2 perCausticPixel = gbufferSize / max(size, float2(1.0));
        float2 here = (float2(pixel) + 0.5) / perCausticPixel;
        float pixelSize = 2.0 * abs(posEye.z) * abs(invProj[1][1]) / size.y;
        float radius = clamp(0.05 / max(pixelSize, 1e-6), 1.0, 32.0);
        float turn = 6.2831853 * noise;

        // most of the frame has no caustic nearby, so the disc is probed first and a pixel with nothing in reach is done
        uint2 center = uint2(clamp(here, float2(0.0), size - 1.0));
        float3 probeSun = wantSun ? sunCaustic.read(center).rgb : float3(0.0);
        float3 probeLocal = wantLocal ? localCaustic.read(center).rgb : float3(0.0);
        for (int i = 0; i < 4; ++i) {
          float a = 1.5707963 * float(i) + turn;
          float2 step = float2(cos(a), sin(a)) * radius;
          uint2 far = uint2(clamp(here + step, float2(0.0), size - 1.0));
          uint2 near = uint2(clamp(here + step * 0.5, float2(0.0), size - 1.0));
          if (wantSun) probeSun += sunCaustic.read(far).rgb + sunCaustic.read(near).rgb;
          if (wantLocal) probeLocal += localCaustic.read(far).rgb + localCaustic.read(near).rgb;
        }
        bool doSun = probeSun.r + probeSun.g + probeSun.b > 0.0;
        bool doLocal = probeLocal.r + probeLocal.g + probeLocal.b > 0.0;
        if (!doSun && !doLocal) return;

        float3 sumSun = float3(0.0), sumLocal = float3(0.0);
        float total = 0.0;
        for (int i = 0; i < 16; ++i) {
          float r = sqrt((float(i) + 0.5) / 16.0) * radius;
          float a = float(i) * 2.3999632 + turn;
          float2 t = clamp(here + float2(cos(a), sin(a)) * r, float2(0.0), size - 1.0);
          uint2 g = uint2(clamp(t * perCausticPixel, float2(0.0), gbufferSize - 1.0));
          float4 n = normals.read(g);
          if (n.a < 0.5) continue;
          float dz = abs(positions.read(g).z - posEye.z);
          float w = exp(-dz / max(0.03 * abs(posEye.z), 1e-3)) * pow(saturate(dot(normalize(n.xyz), normalEye)), 4.0);
          if (doSun) sumSun += sunCaustic.read(uint2(t)).rgb * w;
          if (doLocal) sumLocal += localCaustic.read(uint2(t)).rgb * w;
          total += w;
        }
        if (total > 1e-4) {
          sun = doSun ? sumSun / total : float3(0.0);
          local = doLocal ? sumLocal / total : float3(0.0);
        } else {
          sun = doSun ? sunCaustic.read(center).rgb : float3(0.0);
          local = doLocal ? localCaustic.read(center).rgb : float3(0.0);
        }
      }

      // the caustic softened through its disc, blended with where this surface was last frame
      float3 causticHistory(float3 current, texture2d<float> history, sampler smp, float2 prevUV, bool fresh, float alpha)
      {
        float3 kept = history.sample(smp, clamp(prevUV, 0.0, 1.0)).rgb;
        if (fresh || any(isnan(kept)) || any(kept < float3(0.0))) return current;
        return mix(kept, current, alpha);
      }

      //@main
      {
        int2 pixel = int2(gl_FragCoord.xy);
        int2 size = int2(u_glassSunCaustic_texture.get_width(), u_glassSunCaustic_texture.get_height());
        int2 gsize = int2(u_position_texture.get_width(), u_position_texture.get_height());
        float2 uv = (float2(pixel) + 0.5) / float2(size);
        uint2 g = uint2(clamp(int2(uv * float2(gsize)), int2(0), gsize - 1));
        float3 posEye = u_position_texture.read(g).xyz;
        float4 normal = u_normal_texture.read(g);
        float depth = log2(max(-posEye.z, 1e-4));
        bool surface = normal.a >= 0.5;

        // the disc turns every frame and the blend averages its turns, which one frame alone shows as shimmer
        float2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, float2(0.06711056, 0.00583715))));
        float3 sun = float3(0.0), local = float3(0.0);
        if (surface) {
          softCaustics(u_glassSunCaustic_texture, u_glassLocalCaustic_texture, true, true, u_position_texture, u_normal_texture,
                       g, posEye, normalize(normal.xyz), u_invProj, noise, sun, local);
        }

        bool shutter = u_taa.w > 0.5;
        float2 prevUV = uv + (shutter ? float2(0.0) : u_velocity_texture.read(g).xy);
        bool offscreen = any(prevUV < float2(0.0)) || any(prevUV > float2(1.0));
        float historyDepth = u_glassSunCausticHistory_texture.read(uint2(clamp(int2(prevUV * float2(size)), int2(0), size - 1))).a;
        bool uncovered = !shutter && abs(historyDepth - depth) > 0.05;
        bool fresh = !surface || u_taa.x < 0.5 || u_taa.y > 0.5 || offscreen || uncovered;

        // caustics keep ten frames or more since they stay on surfaces the reprojection follows
        float alpha = clamp(u_taa.z, 0.05, 0.1);
        o_glassSunCausticAccum_texture = float4(causticHistory(sun, u_glassSunCausticHistory_texture,
                                                               u_glassSunCausticHistory_texture_smp, prevUV, fresh, alpha), depth);
        o_glassLocalCausticAccum_texture = float4(causticHistory(local, u_glassLocalCausticHistory_texture,
                                                                 u_glassLocalCausticHistory_texture_smp, prevUV, fresh, alpha), depth);
      }
      """#
  }

  /// drawn by the `glass caustic history` pass.
  struct GlassCausticCopyShader: FullscreenShader
  {
    let name = "glass-caustic-copy"

    var uniforms: [Declaration]
    {
      Sampler(GlassCausticAccumBuffer.glassSunCausticAccum)
      Sampler(GlassCausticAccumBuffer.glassLocalCausticAccum)
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        o_glassSunCausticHistory_texture = texelFetch(u_glassSunCausticAccum_texture, pixel, 0);
        o_glassLocalCausticHistory_texture = texelFetch(u_glassLocalCausticAccum_texture, pixel, 0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        uint2 pixel = uint2(gl_FragCoord.xy);
        o_glassSunCausticHistory_texture = u_glassSunCausticAccum_texture.read(pixel);
        o_glassLocalCausticHistory_texture = u_glassLocalCausticAccum_texture.read(pixel);
      }
      """#
  }
}
