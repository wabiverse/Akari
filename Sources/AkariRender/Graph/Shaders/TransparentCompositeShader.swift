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
  /// drawn by the `transparent composite` pass.
  struct TransparentCompositeShader: FullscreenShader
  {
    let name = "transparent-composite"

    var uniforms: [Declaration]
    {
      Uniforms.iblTint
      Uniforms.frameIndex
      Sampler(ColorBuffer.`final`)
      Sampler(TransparentAccumBuffer.tColor)
      Sampler(TransparentAccumBuffer.tReflect)
      Sampler(TransparentAccumBuffer.tTransmit)
      Sampler(TransparentAccumBuffer.tOffset)
      Sampler(TransparentAccumBuffer.tDepth)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(PrefilteredBuffer.prefiltered, .samplerCube)
      Uniforms.proj
      Uniforms.invProj
      Uniforms.waterView
      Uniforms.waterInvView
      Uniforms.water
      Uniforms.waterColor
      Uniforms.waterBounds
      Uniforms.waterWaves
      Uniforms.sunDirection
      Uniforms.sunOverride
      Uniforms.iblEnabled
      Uniforms.zUp
      Uniforms.transparency
      Uniforms.glass
      Samplers.probeSphere
      Samplers.probeInfo
      Uniforms.probeGridMax
      Sampler(GlassFrontBuffer.glassFront)
      Sampler(GlassFrontBuffer.glassFrontNormal)
      Sampler(GlassBackBuffer.glassBack)
      Sampler(GlassBackBuffer.glassBackNormal)
      Sampler(TransparentBehindBuffer.bColor)
      Sampler(TransparentBehindBuffer.bReflect)
      Sampler(TransparentBehindBuffer.bTransmit)
      Sampler(TransparentBehindResolvedBuffer.tBehind)
    }

    let fragmentGLSL = #"""
      void main()
      {
        o_tResolved_texture = texelFetch(u_final_texture, ivec2(gl_FragCoord.xy), 0);
        o_tSurface_texture = vec4(0.0);
      }
      """#

    var fragmentMSL: String { ShaderLibrary.probeSphereMSL + "\n" + Self.lensMSL + "\n" + mainMSL }

    /// tracing a view ray through glass and its reflection, shared with the behind composite
    static let lensMSL = #"""
      // where an eye space point lands on screen, in pixels, the way the g-buffer is laid out.
      static float2 lensPixel(float3 p, float4x4 proj, float2 size, bool flipY)
      {
        float4 c = proj * float4(p, 1.0);
        float2 pixel = (c.xy / max(c.w, 1e-6) * 0.5 + 0.5) * size;
        return flipY ? float2(pixel.x, size.y - pixel.y) : pixel;
      }

      static bool onScreen(float2 pixel, float2 size)
      {
        return all(pixel >= 0.0) && all(pixel < size);
      }

      // the sharp environment along an eye space direction, before its tint
      static float3 lensEnvironment(float3 direction, float4x4 invView, float zUp, texturecube<float> environment, sampler smp)
      {
        float3 w = normalize((invView * float4(direction, 0.0)).xyz);
        return environment.sample(smp, mix(w, float3(w.x, w.z, -w.y), zUp), level(0.0)).rgb;
      }

      // what the sphere probe around the glass sees along a leaving ray, false where no probe holds the glass
      static bool lensProbe(float3 start, float3 direction, float4x4 invView, int count,
                            texture2d<float> atlas, sampler smp, texture2d<float> info, thread float3& radiance)
      {
        float3 from = (invView * float4(start, 1.0)).xyz;
        float3 toward = normalize((invView * float4(direction, 0.0)).xyz);
        int best = -1;
        float nearest = 1e30;
        for (int i = 0; i < count; ++i) {
          float4 sphere = info.read(uint2(i, 0));
          if (info.read(uint2(i, 1)).x <= 0.0) continue;
          float d = length(from - sphere.xyz);
          if (d < sphere.w * 1.5 && d < nearest) {
            nearest = d;
            best = i;
          }
        }
        if (best < 0) return false;

        radiance = probeSphereMip(atlas, smp, best, 0, toward);
        return true;
      }

      // what the glass mirrors at a pixel, its reflected ray marched to the first surface behind, faded toward the screen edges
      static float3 glassReflection(uint2 px, float2 size, float4x4 proj, float ior, float noise,
                                    texture2d<float> front, texture2d<float> frontNormal,
                                    texture2d<float> positions, texture2d<float> normals,
                                    texture2d<float> lit, sampler smp)
      {
        float3 p = front.read(px).xyz;
        float3 n = normalize(frontNormal.read(px).xyz);
        float3 v = normalize(p);
        float3 r = reflect(v, n);
        float2 here = lensPixel(p, proj, size, false);
        float2 center = float2(px) + 0.5;

        // flips y only on a clear win, so pixels across the screen's middle never disagree by rounding alone
        float upright = abs(here.y - center.y);
        float mirrored = abs(size.y - here.y - center.y);
        bool flipY = mirrored < upright - 1.0;
        float f0 = (ior - 1.0) / (ior + 1.0);
        f0 *= f0;
        float F = f0 + (1.0 - f0) * pow(1.0 - saturate(dot(n, -v)), 5.0);

        // marches across the screen with perspective correct depth in at most 48 noisy strides, then halves in on the crossing
        float far = max(-p.z, 1.0) * 2.0;
        if (r.z > 0.0) far = min(far, (-0.01 - p.z) / r.z);
        float3 end = p + r * far;
        float2 s0 = lensPixel(p, proj, size, flipY);
        float2 s1 = lensPixel(end, proj, size, flipY);
        float2 delta = s1 - s0;
        float pixels = max(abs(delta.x), abs(delta.y));
        if (pixels < 2.0) return float3(0.0);

        // two pixel strides, fewer where the glass faces the view and barely mirrors
        float strides = mix(16.0, 48.0, saturate((F - f0) * 6.0));
        int steps = int(clamp(pixels * 0.5, 2.0, strides));
        float k0 = 1.0 / p.z, k1 = 1.0 / end.z;
        float before = 0.0;
        float lastZ = p.z;
        for (int i = 1; i <= steps; ++i) {
          float f = (float(i) + noise) / float(steps);
          if (f > 1.0) break;
          float2 sp = s0 + delta * f;
          if (!onScreen(sp, size)) return float3(0.0);
          float rayZ = 1.0 / mix(k0, k1, f);
          float thickness = max(0.03 + 0.01 * abs(rayZ), 1.5 * abs(rayZ - lastZ));
          lastZ = rayZ;
          uint2 at = uint2(sp);
          float4 hitNormal = normals.read(at);
          if (hitNormal.a < 0.5) { before = f; continue; }
          float sceneZ = positions.read(at).z;

          // only a surface facing the ray can be hit, so one the ray passes behind isn't reflected again along its back
          if (rayZ < sceneZ && sceneZ - rayZ < thickness && dot(hitNormal.xyz, r) < 0.0) {
            float lo = before, hi = f;
            for (int k = 0; k < 6; ++k) {
              float mid = 0.5 * (lo + hi);
              float2 mp = s0 + delta * mid;
              if (1.0 / mix(k0, k1, mid) < positions.read(uint2(clamp(mp, float2(0.0), size - 1.0))).z) hi = mid; else lo = mid;
            }
            float2 hp = clamp(s0 + delta * hi, float2(0.0), size - 1.0);

            // fading out toward the screen's edges and the end of the ray, so hits give way to misses gradually.
            float2 edge = min(hp, size - hp) / (0.2 * size);
            float fade = saturate(min(edge.x, edge.y)) * (1.0 - smoothstep(0.75, 1.0, hi));

            // read through a small disc that widens the farther the ray went, a touch of blur like a not quite perfect mirror.
            float blur = 1.0 + 6.0 * hi;
            float3 c = lit.read(uint2(hp)).rgb * 2.0;
            for (int k = 0; k < 4; ++k) {
              float a = 1.5707963 * float(k) + 6.2831853 * noise;
              c += lit.read(uint2(clamp(hp + float2(cos(a), sin(a)) * blur, float2(0.0), size - 1.0))).rgb;
            }
            return c / 6.0 * F * fade;
          }
          before = f;
        }
        return float3(0.0);
      }

      // what a view ray through glass ends on
      constant int lensNone = 0;
      constant int lensHit = 1;
      constant int lensAway = 2;
      constant int lensHidden = 3;

      // a view ray refracts in through the glass, out the far side or back by total reflection, and lands on the gbuffer, with sure saying how far to trust the picture over the probe
      static int lensUV(uint2 px, float2 size, float4x4 proj, float ior, float noise,
                        texture2d<float> front, texture2d<float> frontNormal, texture2d<float> back, texture2d<float> backNormal,
                        texture2d<float> positions, texture2d<float> normals, thread float2& uv, thread float3& start, thread float3& away,
                        thread float& sure)
      {
        float4 f = front.read(px);
        float3 p = f.xyz;
        float2 here = lensPixel(p, proj, size, false);
        float2 center = float2(px) + 0.5;

        // flips y only on a clear win, so pixels across the screen's middle never disagree by rounding alone
        float upright = abs(here.y - center.y);
        float mirrored = abs(size.y - here.y - center.y);
        bool flipY = mirrored < upright - 1.0;
        float3 v = normalize(p);
        float3 nearNormal = normalize(frontNormal.read(px).xyz);
        float3 inside = refract(v, nearNormal, 1.0 / ior);
        float4 b = back.read(px);
        sure = 0.0;
        start = p;
        away = v;
        if (dot(inside, inside) < 1e-6) return lensNone;

        // a ring at the rim has a front surface and no back, so the ray leaves the way it came, which also matches a real silhouette
        float3 exit = p;
        float3 n = nearNormal;
        if (b.w > 0.5) {
          // across the glass until the ray passes behind its far side.
          float reach = max(p.z - b.z, 1e-3) * 3.0;
          float before = 0.0;
          for (int i = 1; i <= 24; ++i) {
            float t = reach * float(i) / 24.0;
            float3 q = p + inside * t;
            float2 qp = lensPixel(q, proj, size, flipY);
            if (!onScreen(qp, size)) break;
            float4 far = back.read(uint2(qp));

            // another glass's far side is no wall of this one, so the ray counts as out
            if (far.w < 0.5 || abs(far.w - f.w) > 0.5 || q.z <= far.z) {
              float lo = before, hi = t;
              for (int k = 0; k < 5; ++k) {
                float mid = 0.5 * (lo + hi);
                float3 m = p + inside * mid;
                float4 mf = back.read(uint2(lensPixel(m, proj, size, flipY)));
                if (mf.w < 0.5 || abs(mf.w - f.w) > 0.5 || m.z <= mf.z) hi = mid; else lo = mid;
              }
              exit = p + inside * hi;
              uint2 ep = uint2(clamp(lensPixel(exit, proj, size, flipY), float2(0.0), size - 1.0));
              float4 en = backNormal.read(ep);
              n = en.w > 0.5 ? normalize(en.xyz) : nearNormal;
              break;
            }
            before = t;
          }
        }

        float3 out = refract(inside, -n, ior);
        if (dot(out, out) < 1e-6) out = reflect(inside, -n);
        out = normalize(out);

        // on to the first surface it passes behind with growing noisy steps, so frames land on what others step over and blend
        float far = max(-exit.z, 1.0) * 1.5;

        // start a little clear of the glass so a floor it rests on is not hit or missed by noise alone
        float clear = 0.004 + 0.004 * abs(exit.z);
        float stepBefore = clear;
        float lastZ = exit.z;

        // the surface under the previous step and whether the ray was in front of it
        float3 prevPos = float3(0.0), prevNormal = float3(0.0);
        bool wasInFront = false;

        // where the ray went behind a surface too far to have hit it, kept while it stays hidden
        float2 hidden = float2(-1.0);

        // where the ray crosses the gbuffer depth between two distances along it
        auto crossing = [&](float lo, float hi) {
          for (int k = 0; k < 6; ++k) {
            float mid = 0.5 * (lo + hi);
            float3 m = exit + out * mid;
            float2 mp = clamp(lensPixel(m, proj, size, flipY), float2(0.0), size - 1.0);
            if (m.z < positions.read(uint2(mp)).z) hi = mid; else lo = mid;
          }
          return clamp(lensPixel(exit + out * hi, proj, size, flipY), float2(0.0), size - 1.0);
        };

        for (int i = 1; i <= 32; ++i) {
          float step = float(i) - 1.0 + noise;
          float t = clear + far * step * step / 1024.0;
          float3 q = exit + out * t;
          float2 qp = lensPixel(q, proj, size, flipY);
          if (!onScreen(qp, size) || q.z > -1e-3) break;

          float thickness = max(0.05 + 0.02 * abs(q.z), 2.0 * abs(q.z - lastZ));
          lastZ = q.z;
          float4 sceneNormal = normals.read(uint2(qp));
          if (sceneNormal.a < 0.5) {
            // over the sky nothing hides the ray any more
            hidden = float2(-1.0);
            stepBefore = t;
            wasInFront = false;
            continue;
          }

          float3 scenePos = positions.read(uint2(qp)).xyz;
          float sceneZ = scenePos.z;

          // a surface counts once the ray just passes behind it, or the last step was in front on the same plane so floors aren't skipped
          bool samePlane = wasInFront && abs(dot(scenePos - prevPos, prevNormal)) < 0.01 + 0.01 * abs(sceneZ);
          if (q.z < sceneZ && (sceneZ - q.z < thickness || samePlane)) {
            uv = crossing(stepBefore, t) / size;
            start = exit;
            away = out;
            sure = samePlane ? 1.0 : 1.0 - smoothstep(0.5, 1.0, (sceneZ - q.z) / thickness);
            return lensHit;
          }

          // past the back of something the ray meets the plane it was last in front of, which lands the same every frame so it can't shimmer
          if (q.z >= sceneZ) {
            hidden = float2(-1.0);
          } else if (hidden.x < 0.0) {
            hidden = qp;
            float facing = dot(out, prevNormal);
            if (wasInFront && facing < -1e-4) {
              float3 meets = exit + out * (dot(prevPos - exit, prevNormal) / facing);
              float2 there = lensPixel(meets, proj, size, flipY);
              if (meets.z < -1e-3 && onScreen(there, size)) hidden = there;
            }
          }

          wasInFront = q.z >= sceneZ;
          prevPos = scenePos;
          prevNormal = normalize(sceneNormal.xyz);
          stepBefore = t;
        }

        start = exit;
        away = out;
        if (hidden.x >= 0.0) {
          uv = hidden / size;
          return lensHidden;
        }

        // a ray leaving the picture or meeting nothing goes on to the probe or environment, clamping it smeared streaks
        return lensAway;
      }
      """#

    let mainMSL = #"""
      //@main
      {
        uint2 px = uint2(gl_FragCoord.xy);
        float2 size = float2(u_final_texture.get_width(), u_final_texture.get_height());
        float4 acc = u_tColor_texture.read(px);
        float4 refl = u_tReflect_texture.read(px);
        float4 tr = u_tTransmit_texture.read(px);
        float4 off = u_tOffset_texture.read(px);
        float4 tz = u_tDepth_texture.read(px);
        float3 color = u_final_texture.read(px).rgb;
        float4 surfaceOut = float4(0.0);
        float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), float2(0.06711056, 0.00583715))));

        // what lies behind the nearest glass is composited on its own, so here the nearest glass adds only its own surface and tint
        float4 nearest = u_glassFront_texture.read(px);
        bool lens = u_glass.z > 0.5 && nearest.w > 0.5;
        if (lens) {
          acc = max(acc - u_bColor_texture.read(px), float4(0.0));
          refl = max(refl - u_bReflect_texture.read(px), float4(0.0));
          tr = max(tr - u_bTransmit_texture.read(px), float4(0.0));
        }
        if (!(acc.a <= 1e-6 && tr.a <= 1e-6 && dot(tr.rgb, float3(1.0)) <= 1e-6 && dot(refl.rgb, float3(1.0)) <= 1e-6)) {
          float3 start = float3(0.0), away = float3(0.0);
          float sure = 1.0;
          bool beyond = false;
          float3 beyondColor = float3(0.0);
          float2 uv = (gl_FragCoord.xy + float2(off.x, -off.y) / max(off.w, 1e-6) * max(off.z, 0.0) * size.y) / size;
          if (lens) {
            float2 traced;
            int result = lensUV(px, size, u_proj, u_transparency.y, noise, u_glassFront_texture, u_glassFrontNormal_texture,
                                u_glassBack_texture, u_glassBackNormal_texture, u_position_texture, u_normal_texture,
                                traced, start, away, sure);
            if (result == lensNone) {
              // the sliver at the rim the trace can't follow looks straight through, matching what lies just past the edge.
              uv = gl_FragCoord.xy / size;
              sure = 1.0;
            } else {
              if (result != lensAway) uv = traced;

              // past what the picture shows, the glass's probe sees what the ray meets
              if (sure < 1.0) {
                beyond = lensProbe(start, away, u_waterInvView, int(u_probeGridMax.w), u_probe_sphere, u_probe_sphere_smp,
                                   u_probe_info, beyondColor);
                if (!beyond && result == lensAway) {
                  beyond = true;
                  beyondColor = lensEnvironment(away, u_waterInvView, u_zUp, u_prefiltered_texture, u_prefiltered_texture_smp) * u_iblTint.rgb * u_iblEnabled;
                }
              }
            }
          }
          float2 at = clamp(uv, float2(0.0), float2(1.0));
          float3 background = u_final_texture.sample(u_final_texture_smp, at, level(0.0)).rgb;
          if (lens && sure > 0.0) {
            // where the bent ray lands, the glass behind this one has already bent what lies behind it
            uint2 q = uint2(min(at * size, size - 1.0));
            float there = u_glassFront_texture.read(q).w;
            float3 behind = u_tBehind_texture.sample(u_tBehind_texture_smp, at, level(0.0)).rgb;
            if (abs(there - nearest.w) < 0.5) {
              background = behind;
            } else if (there > 0.5) {
              // another glass is nearest there, so it shows with its own surface and tint over what lies behind it
              float4 qAcc = max(u_tColor_texture.read(q) - u_bColor_texture.read(q), float4(0.0));
              float4 qRefl = max(u_tReflect_texture.read(q) - u_bReflect_texture.read(q), float4(0.0));
              float4 qTr = max(u_tTransmit_texture.read(q) - u_bTransmit_texture.read(q), float4(0.0));
              background = qAcc.rgb / max(qAcc.a, 1e-6) * (1.0 - exp(-qTr.a)) + qRefl.rgb + behind * exp(-qTr.rgb);
            }
          }
          if (beyond) background = mix(beyondColor, background, sure);
          float coverage = 1.0 - exp(-tr.a);
          float3 surface = acc.rgb / max(acc.a, 1e-6) * coverage + refl.rgb;

          // glass turns to a mirror at grazing views, which carries the traced image out to the silhouette
          float grazing = 1.0;
          if (u_glass.z > 0.5) {
            float4 fn = u_glassFrontNormal_texture.read(px);
            if (fn.w > 0.5) {
              float3 vd = normalize(u_glassFront_texture.read(px).xyz);
              float c = saturate(dot(-vd, normalize(fn.xyz)));
              grazing = 1.0 - (0.04 + 0.96 * pow(1.0 - c, 5.0));
            }
          }
          float3 through = background * exp(-tr.rgb) * grazing;
          color = surface + through;
          if (u_glass.z > 0.5 && u_glassFront_texture.read(px).w > 0.5) {
            color += glassReflection(px, size, u_proj, u_transparency.y, noise, u_glassFront_texture, u_glassFrontNormal_texture,
                                     u_position_texture, u_normal_texture, u_final_texture, u_final_texture_smp);
          }
          float share = dot(surface, float3(0.2126, 0.7152, 0.0722)) / max(dot(color, float3(0.2126, 0.7152, 0.0722)), 1e-6);
          surfaceOut = float4(tz.x / max(tz.y, 1e-6), saturate(max(share, coverage)), 0.0, 1.0);
        }

        // the water plane, a ray against the sheet with waves, a screen space reflection, refraction with depth absorption and the view from below
        if (u_water.y > 0.5) {
          bool zUp = u_zUp > 0.5;
          float mpu = u_waterColor.w;
          float3 upW = zUp ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
          float2 baseUV = gl_FragCoord.xy / size;
          float4 gpos = u_position_texture.read(px);
          bool opaque = u_normal_texture.read(px).a >= 0.5;
          float4 e = u_invProj * float4(baseUV * 2.0 - 1.0, -1.0, 1.0);
          float3 dirEye = normalize(e.xyz / e.w);
          float3 camW = (u_waterInvView * float4(0.0, 0.0, 0.0, 1.0)).xyz;
          float3 dirW = normalize((u_waterInvView * float4(dirEye, 0.0)).xyz);
          float dOpaque = opaque ? length(gpos.xyz) : 1e30;
          float camH = dot(camW, upW), dirH = dot(dirW, upW);
          float t = abs(dirH) > 1e-6 ? (u_water.x - camH) / dirH : -1.0;
          bool under = camH < u_water.x;
          float3 hitW = camW + dirW * t;
          float2 hp = zUp ? hitW.xy : hitW.xz;
          bool inside = all(hp >= u_waterBounds.xy) && all(hp <= u_waterBounds.zw);

          // red goes within a few meters, blue green carries, by the water's own color.
          float3 absorb = (1.0 - u_waterColor.rgb) * 0.45 + float3(0.02, 0.01, 0.015);
          float3 skyAmbient = u_prefiltered_texture.sample(u_prefiltered_texture_smp, mix(upW, float3(upW.x, upW.z, -upW.y), u_zUp), level(6.0)).rgb * u_iblTint.rgb * u_iblEnabled;
          float3 scatter = u_waterColor.rgb * skyAmbient * 0.06;
          float ior = u_water.z;
          float time = u_waterWaves.x;

          // summed waves, their slope in meters, fading to calm with distance so they don't alias.
          auto waveNormal = [&](float2 p, float distance) {
            const float4 waves[4] = { float4(1.0, 0.2, 7.0, 0.07), float4(0.6, 1.0, 3.1, 0.06),
                                      float4(-0.7, 0.5, 1.3, 0.05), float4(0.2, -1.0, 0.55, 0.035) };
            float2 g = float2(0.0);
            for (int i = 0; i < 4; ++i) {
              float2 d = normalize(waves[i].xy);
              float k = 6.2831853 / waves[i].z;
              float phase = k * dot(d, p) + time * sqrt(9.81 * k);
              g += d * waves[i].w * cos(phase);
            }
            g *= exp(-distance / 400.0);
            return zUp ? normalize(float3(-g.x, -g.y, 1.0)) : normalize(float3(-g.x, 1.0, -g.y));
          };
          auto environment = [&](float3 r, float rough) {
            return u_prefiltered_texture.sample(u_prefiltered_texture_smp, mix(r, float3(r.x, r.z, -r.y), u_zUp), level(rough * 5.0)).rgb * u_iblTint.rgb * u_iblEnabled;
          };

          if (!under && inside && t > 0.0 && t < dOpaque) {
            float3 N = waveNormal(hp * mpu, t * mpu);
            float3 V = -dirW;
            float NoV = saturate(dot(N, V));
            float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
            float F = f0 + (1.0 - f0) * pow(1.0 - NoV, 5.0);

            // what's under the surface, bent by its slope and dimmed by the depth it's seen through.
            float thickness = opaque ? (dOpaque - t) * mpu : 60.0;
            float2 tilt = (zUp ? N.xy : N.xz) * 0.04 * saturate(thickness * 0.5);
            float3 below = u_final_texture.sample(u_final_texture_smp, clamp(baseUV + tilt, float2(0.0), float2(1.0)), level(0.0)).rgb;
            float3 T = exp(-absorb * thickness);
            float3 refracted = below * T + scatter * (1.0 - T);

            // the reflection, marched against the scene in screen space before falling back to the sky.
            float3 R = reflect(dirW, N);
            R = normalize(R + upW * max(0.02 - dot(R, upW), 0.0));
            float rough = max(u_water.w, 0.02);
            float3 reflection = environment(R, rough);
            float s = 0.2 / mpu;
            for (int i = 0; i < 40; ++i) {
              float3 q = hitW + R * s;
              float4 qe = u_waterView * float4(q, 1.0);
              float4 qc = u_proj * qe;
              if (qc.w <= 1e-4) break;
              float2 quv = qc.xy / qc.w * 0.5 + 0.5;
              if (any(quv < float2(0.0)) || any(quv > float2(1.0))) break;
              uint2 qpx = uint2(quv * size);
              if (u_normal_texture.read(qpx).a >= 0.5) {
                float sceneZ = -u_position_texture.read(qpx).z, rayZ = -qe.z;
                if (rayZ > sceneZ && rayZ - sceneZ < s * 0.35 + 0.1 / mpu) {
                  float2 edge = min(quv, 1.0 - quv);
                  float fade = saturate(min(edge.x, edge.y) * 12.0);
                  reflection = mix(reflection, u_final_texture.read(qpx).rgb, fade);
                  break;
                }
              }
              s *= 1.18;
            }

            // the sun's glint off the waves.
            float3 L = normalize(u_sunDirection.xyz);
            float3 sun = mix(float3(3.0), u_sunOverride.rgb, u_sunOverride.w);
            float3 H = normalize(V + L);
            float a2 = pow(max(rough * rough, 0.002), 2.0);
            float NoH = saturate(dot(N, H)), NoL = saturate(dot(N, L));
            float D = a2 / (3.14159265 * pow(NoH * NoH * (a2 - 1.0) + 1.0, 2.0));
            float3 glint = sun * NoL * F * D * 0.25 / max(NoV * NoL, 0.05);

            color = mix(refracted, reflection, F) + glint;
            surfaceOut = float4(1.0 / max(t, 1e-2), 1.0, 0.0, 1.0);
          } else if (under) {
            // under water everything is seen through it, the surface from below through snell's window.
            bool upward = t > 0.0 && t < dOpaque && inside;
            float path = upward ? t : min(dOpaque, 1e6);
            float3 seen = color;
            if (upward) {
              float3 N = waveNormal(hp * mpu, t * mpu);
              float3 out = refract(dirW, -N, ior);
              seen = dot(out, out) > 1e-6 ? environment(out, max(u_water.w, 0.02)) : scatter * 4.0;
            }
            float3 T = exp(-absorb * path * mpu);
            color = seen * T + scatter * (1.0 - T);
            surfaceOut = float4(1.0 / max(path, 1e-2), 1.0, 0.0, 1.0);
          }
        }
        o_tResolved_texture = float4(min(color, float3(60000.0)), 1.0);
        o_tSurface_texture = surfaceOut;
      }
      """#
  }

  /// drawn by the transparent behind composite pass, everything behind the nearest glass with the next glass bent too
  struct TransparentBehindCompositeShader: FullscreenShader
  {
    let name = "transparent-behind-composite"

    var uniforms: [Declaration]
    {
      Uniforms.frameIndex
      Uniforms.iblTint
      Uniforms.iblEnabled
      Uniforms.zUp
      Uniforms.waterInvView
      Samplers.probeSphere
      Samplers.probeInfo
      Uniforms.probeGridMax
      Sampler(PrefilteredBuffer.prefiltered, .samplerCube)
      Sampler(ColorBuffer.`final`)
      Sampler(TransparentBehindBuffer.bColor)
      Sampler(TransparentBehindBuffer.bReflect)
      Sampler(TransparentBehindBuffer.bTransmit)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Uniforms.proj
      Uniforms.transparency
      Uniforms.glass
      Sampler(GlassFrontBuffer.glassFront)
      Sampler(GlassBehindFrontBuffer.glassBehindFront)
      Sampler(GlassBehindFrontBuffer.glassBehindFrontNormal)
      Sampler(GlassBehindBackBuffer.glassBehindBack)
      Sampler(GlassBehindBackBuffer.glassBehindBackNormal)
    }

    let fragmentGLSL = #"""
      void main()
      {
        o_tBehind_texture = texelFetch(u_final_texture, ivec2(gl_FragCoord.xy), 0);
      }
      """#

    var fragmentMSL: String { ShaderLibrary.probeSphereMSL + "\n" + TransparentCompositeShader.lensMSL + "\n" + mainMSL }

    let mainMSL = #"""
      //@main
      {
        uint2 px = uint2(gl_FragCoord.xy);
        float2 size = float2(u_final_texture.get_width(), u_final_texture.get_height());
        float3 color = u_final_texture.read(px).rgb;

        // only behind the nearest glass is anything composited, elsewhere the nearest glass never reads this
        if (u_glass.z > 0.5 && u_glassFront_texture.read(px).w > 0.5) {
          float4 acc = u_bColor_texture.read(px);
          float4 refl = u_bReflect_texture.read(px);
          float4 tr = u_bTransmit_texture.read(px);
          if (!(acc.a <= 1e-6 && tr.a <= 1e-6 && dot(tr.rgb, float3(1.0)) <= 1e-6 && dot(refl.rgb, float3(1.0)) <= 1e-6)) {
            float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), float2(0.06711056, 0.00583715))));
            float2 uv = gl_FragCoord.xy / size;
            float grazing = 1.0;
            bool toEnvironment = false;
            float3 environment = float3(0.0);
            float sure = 1.0;

            // the next glass bends what lies behind it the same way the nearest does
            float4 next = u_glassBehindFront_texture.read(px);
            if (next.w > 0.5) {
              float2 traced;
              float3 start, away;
              int result = lensUV(px, size, u_proj, u_transparency.y, noise, u_glassBehindFront_texture, u_glassBehindFrontNormal_texture,
                                  u_glassBehindBack_texture, u_glassBehindBackNormal_texture, u_position_texture, u_normal_texture,
                                  traced, start, away, sure);
              if (result == lensNone) {
                sure = 1.0;
              } else {
                if (result != lensAway) uv = traced;
                if (sure < 1.0) {
                  toEnvironment = lensProbe(start, away, u_waterInvView, int(u_probeGridMax.w), u_probe_sphere, u_probe_sphere_smp,
                                            u_probe_info, environment);
                  if (!toEnvironment && result == lensAway) {
                    toEnvironment = true;
                    environment = lensEnvironment(away, u_waterInvView, u_zUp, u_prefiltered_texture, u_prefiltered_texture_smp) * u_iblTint.rgb * u_iblEnabled;
                  }
                }
              }
              float3 n = normalize(u_glassBehindFrontNormal_texture.read(px).xyz);
              float c = saturate(dot(-normalize(next.xyz), n));
              grazing = 1.0 - (0.04 + 0.96 * pow(1.0 - c, 5.0));
            }

            float3 background = u_final_texture.sample(u_final_texture_smp, clamp(uv, float2(0.0), float2(1.0)), level(0.0)).rgb;
            if (toEnvironment) background = mix(environment, background, sure);
            float coverage = 1.0 - exp(-tr.a);
            color = acc.rgb / max(acc.a, 1e-6) * coverage + refl.rgb + background * exp(-tr.rgb) * grazing;
          }
        }
        o_tBehind_texture = float4(color, 1.0);
      }
      """#
  }
}
