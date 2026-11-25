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
  /// drawn by the `ssr` pass.
  struct SsrShader: FullscreenShader
  {
    let name = "ssr"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.material)
      Sampler(GBuffer.velocity)
      Sampler(HistoryBuffer.history)
      Sampler(SsgiPrepBuffer.ssgiDepth)
      Sampler(HizBuffer.hiz)
      Sampler(BackGBuffer.backPosition)
      Sampler(BackGBuffer.backNormal)
      Sampler(BackGBuffer.backDiffuse)
      Sampler(BackGBuffer.backMaterial)
      Sampler(IrradianceBuffer.irradiance, .samplerCube)
      Samplers.probeVolume
      Uniforms.probeGridMin
      Uniforms.probeGridMax
      Uniforms.probeGridSize
      Uniforms.zUp
      Uniforms.iblTint
      Uniforms.iblEnabled
      Uniforms.view
      Uniforms.proj
      Uniforms.invProj
      Uniforms.prevViewProj
      Uniforms.taa
      Uniforms.ssr
      Uniforms.halfScale
      Uniforms.frameIndex
    }

    var fragmentGLSL: String
    {
      #"""
      const float PI = 3.14159265358979;

      \#(ShaderLibrary.hizAtlasGLSL)

      vec3 finiteColor(vec3 c)
      {
        bvec3 bad = equal(floatBitsToUint(c) & 0x7F800000u, uvec3(0x7F800000u));
        return mix(clamp(c, 0.0, 65000.0), vec3(0.0), bad);
      }

      vec3 sampleGGXVisible(vec3 N, vec3 V, float a, vec2 xi)
      {
        vec3 T = normalize(cross(abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0), N));
        vec3 B = cross(N, T);
        vec3 Vt = vec3(dot(V, T), dot(V, B), dot(V, N));
        vec3 Vh = normalize(vec3(a * Vt.x, a * Vt.y, Vt.z));
        float lensq = dot(Vh.xy, Vh.xy);
        vec3 T1 = lensq > 0.0 ? vec3(-Vh.y, Vh.x, 0.0) * inversesqrt(lensq) : vec3(1.0, 0.0, 0.0);
        vec3 T2 = cross(Vh, T1);
        float r = sqrt(xi.x);
        float phi = 2.0 * PI * xi.y;
        float t1 = r * cos(phi);
        float s = 0.5 * (1.0 + Vh.z);
        float t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * r * sin(phi);
        vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(1.0 - t1 * t1 - t2 * t2, 0.0)) * Vh;
        vec3 Ht = normalize(vec3(a * Nh.x, a * Nh.y, max(Nh.z, 0.0)));
        return T * Ht.x + B * Ht.y + N * Ht.z;
      }

      vec2 cameraMotion(vec3 eye)
      {
        mat3 invRot = transpose(mat3(u_view));
        vec4 prev = u_prevViewProj * vec4(invRot * (eye - u_view[3].xyz), 1.0);
        vec4 curr = u_proj * vec4(eye, 1.0);
        if (prev.w < 1e-4 || curr.w < 1e-4) return vec2(0.0);
        return (prev.xy / prev.w - curr.xy / curr.w) * 0.5;
      }

      vec3 viewPosition(vec2 uv, float z)
      {
        vec2 ndc = uv * 2.0 - 1.0;
        float w = u_proj[2][3] * z + u_proj[3][3];
        return vec3((ndc.x * w - u_proj[2][0] * z - u_proj[3][0]) / u_proj[0][0],
                    (ndc.y * w - u_proj[2][1] * z - u_proj[3][1]) / u_proj[1][1], z);
      }

      /// how deep the nearest face turned away from the eye lies behind a visible surface, which bounds that surface's solid
      float backDepth(vec2 uv, float front)
      {
        ivec2 size = textureSize(u_backPosition_texture, 0);
        ivec2 p = clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);

        // with no face behind it, or when the visible face is itself one turned away, the surface counts as a thin shell
        float thin = front + 0.05 + 0.02 * front;
        if (texelFetch(u_backNormal_texture, p, 0).a < 0.5) return thin;
        float z = -texelFetch(u_backPosition_texture, p, 0).z;
        return z > front + 1e-3 ? z : thin;
      }

      float sceneDepth(vec2 uv)
      {
        ivec2 size = textureSize(u_ssgiDepth_texture, 0);
        float z = texelFetch(u_ssgiDepth_texture, clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1), 0).x;
        return z == 0.0 ? 1e30 : -z;
      }

      /// the closest eye distance under one cell of the atlas, the half resolution depth itself at level zero
      float hizClosest(int level, ivec2 cell, ivec2 atlas)
      {
        if (level < 1) {
          float z = texelFetch(u_ssgiDepth_texture, clamp(cell, ivec2(0), atlas - 1), 0).x;
          return z == 0.0 ? 1e30 : -z;
        }
        ivec2 size = hizLevelSize(level, atlas);
        return texelFetch(u_hiz_texture, hizLevelOffset(level, atlas) + clamp(cell, ivec2(0), size - 1), 0).x;
      }

      void main()
      {
        ivec2 size = textureSize(u_position_texture, 0);
        ivec2 fp = min(ivec2(floor(gl_FragCoord.xy) * u_halfScale.xy), size - 1);
        vec4 n = texelFetch(u_normal_texture, fp, 0);
        vec3 P = texelFetch(u_position_texture, fp, 0).xyz;
        float roughness = clamp(texelFetch(u_material_texture, fp, 0).r, 0.045, 1.0);
        o_ssrGuide_texture = vec4(n.a < 0.5 ? vec3(0.0) : normalize(n.xyz), P.z);
        o_ssrRadiance_texture = vec4(0.0);
        o_ssrMotion_texture = vec4(0.0);
        o_ssrRay_texture = vec4(0.0);
        if (u_ssr.z < 0.5 || n.a < 0.5 || roughness >= u_ssr.x + 0.2) return;

        vec2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, vec2(0.06711056, 0.00583715))));

        // the second dimension is a per pixel hash stepped by the golden ratio each frame, so the pair never lines up into a pattern
        uvec2 q = uvec2(gl_FragCoord.xy);
        uint seed = (q.x * 1597334677u) ^ (q.y * 3812015801u);
        seed = (seed ^ (seed >> 16)) * 0x7feb352du;
        seed = (seed ^ (seed >> 15)) * 0x846ca68bu;
        seed ^= seed >> 16;
        float noiseB = fract(float(seed >> 8) * 5.9604645e-8 + 0.61803398875 * float(frameIndex % 1024));

        vec3 N = normalize(n.xyz);
        vec3 V = normalize(-P);
        vec3 R = reflect(-V, sampleGGXVisible(N, V, roughness * roughness, vec2(noise, noiseB)));
        if (dot(R, N) <= 0.0) R = reflect(-V, N);

        // how likely this ray was to be picked, so the resolve can weigh it for a neighbour's own lobe
        float a2 = roughness * roughness * roughness * roughness;
        float NoV = max(dot(N, V), 1e-4);
        float NoH = clamp(dot(N, normalize(V + R)), 0.0, 1.0);
        float dd = NoH * NoH * (a2 - 1.0) + 1.0;
        float G1 = 2.0 * NoV / (NoV + sqrt(a2 + (1.0 - a2) * NoV * NoV));
        o_ssrRay_texture = vec4(R, min(a2 / (PI * dd * dd) * G1 / (4.0 * NoV), 60000.0));

        vec3 origin = P + N * (0.002 * -P.z);
        float nearPlane = u_proj[3][2] / (u_proj[2][2] - 1.0);
        float dist = u_ssr.y;
        if (R.z > 0.0) dist = min(dist, 0.99 * (-nearPlane - origin.z) / R.z);
        if (dist <= 0.0) return;

        vec4 h0 = u_proj * vec4(origin, 1.0);
        vec4 h1 = u_proj * vec4(origin + R * dist, 1.0);
        float k0 = 1.0 / h0.w;
        float k1 = 1.0 / h1.w;
        vec2 s0 = h0.xy * k0 * 0.5 + 0.5;
        vec2 s1 = h1.xy * k1 * 0.5 + 0.5;
        vec2 d = s1 - s0;
        float tMax = 1.0;
        if (abs(d.x) > 1e-6) tMax = min(tMax, max(-s0.x / d.x, (1.0 - s0.x) / d.x));
        if (abs(d.y) > 1e-6) tMax = min(tMax, max(-s0.y / d.y, (1.0 - s0.y) / d.y));

        ivec2 atlas = textureSize(u_ssgiDepth_texture, 0);
        float texels = max(length(d * vec2(atlas)), 1e-4);
        float minT = 0.5 / texels;
        if (tMax <= minT) return;

        // walks the atlas a cell at a time, a level up for each clear cell and down when a cell may hold a hit
        int top = hizTopLevel(atlas);
        int level = 1;
        float t = minT;
        float tHit = -1.0;
        bool hidden = false;

        // whether the ray was clear of everything at its last step, rather than behind something
        bool wasInFront = true;

        // how deep the nearest thing the ray went behind lies, to tell when it comes out behind something farther
        float occluder = 0.0;
        float depthPrev = 1.0 / mix(k0, k1, minT);
        for (int i = 0; i < 80 && t < tMax; ++i) {
          vec2 cell = vec2(hizLevelSize(level, atlas));
          float tNext = hizCellExit(s0, d, t, cell, tMax);
          vec2 mid = s0 + d * (0.5 * (t + tNext));
          float depthNear = 1.0 / mix(k0, k1, t);
          float depthFar = 1.0 / mix(k0, k1, tNext);
          float closest = hizClosest(level, ivec2(floor(mid * cell)), atlas);
          if (max(depthNear, depthFar) < closest) {
            // nothing under this cell reaches as near as the ray, so the ray clears all of it at once
            wasInFront = true;
            depthPrev = depthFar;
            t = tNext;
            level = min(level + 1, top);
            continue;
          }
          if (level > 0) {
            level -= 1;
            continue;
          }

          // one texel of the half resolution depth, where the crossing is solved rather than stepped
          float front = closest;

          // a straight ray only reaches what stands off the plane it left, which keeps a surface from reflecting itself
          if (dot(viewPosition(mid, -front) - P, N) <= 0.0006 * front) {
            wasInFront = true;
            depthPrev = depthFar;
            t = tNext;
            level = min(level + 1, top);
            continue;
          }
          if (depthNear <= front) {
            if (depthFar > front) {
              float tc = abs(k1 - k0) < 1e-12 ? t : clamp((1.0 / front - k0) / (k1 - k0), t, tNext);
              vec2 hitUV = s0 + d * tc;
              vec4 facing = texelFetch(u_normal_texture, clamp(ivec2(hitUV * vec2(size)), ivec2(0), size - 1), 0);
              tHit = tc;
              hidden = facing.a < 0.5 || dot(facing.xyz, R) >= 0.0;
              break;
            }
            wasInFront = true;
            depthPrev = depthFar;
            t = tNext;
            continue;
          }

          // how deep this solid reaches, the far side the back layer holds or a thin shell where it holds none
          float back = backDepth(mid, front);
          if (wasInFront) {
            // clear of everything a texel ago, so the ray met this surface's own face between then and now
            if (depthNear <= back + abs(depthFar - depthNear)) {
              vec4 facing = texelFetch(u_normal_texture, clamp(ivec2(mid * vec2(size)), ivec2(0), size - 1), 0);
              tHit = 0.5 * (t + tNext);
              hidden = facing.a < 0.5 || dot(facing.xyz, R) >= 0.0;
              break;
            }

            // it already runs deeper than this solid reaches, so it passed clean behind
            occluder = front;
            wasInFront = false;
            depthPrev = depthFar;
            t = tNext;
            continue;
          }

          if (depthNear <= back + abs(depthNear - depthPrev)) {
            // already behind one thing and now within the next, so it came in through a face the camera never sees
            tHit = t;
            hidden = true;
            break;
          }
          if (front > occluder * 1.05 + 0.1) {
            // out from behind something past a farther surface, so it crossed it hidden, read a few texels on clear of the near rim
            float onward = min(t + 4.0 / texels, tMax);
            float there = sceneDepth(s0 + d * onward);
            tHit = abs(there - front) < 0.1 + 0.05 * front ? onward : t;
            break;
          }
          depthPrev = depthFar;
          t = tNext;
        }

        // only the metal backend draws the back layer, so here a face the camera never saw stays unknown
        if (tHit < 0.0 || hidden) return;

        vec2 hitUV = s0 + d * tHit;
        ivec2 hitPixel = clamp(ivec2(hitUV * vec2(size)), ivec2(0), size - 1);
        vec4 hitNormal = texelFetch(u_normal_texture, hitPixel, 0);
        if (hitNormal.a < 0.5 || dot(hitNormal.xyz, R) > 0.0) return;

        // the hit is read where its surface was last frame, moving with it rather than only with the camera
        vec2 hitMotion = texelFetch(u_velocity_texture, hitPixel, 0).xy;
        vec2 prevUV = u_taa.x > 0.5 ? hitUV + hitMotion : hitUV;

        // only what the hit or the surface moved on their own counts, the camera's part is followed exactly below
        vec3 hitEye = texelFetch(u_position_texture, hitPixel, 0).xyz;
        vec2 hitOwn = hitMotion - cameraMotion(hitEye);
        vec2 surfaceVelocity = texelFetch(u_velocity_texture, fp, 0).xy;
        vec2 surfaceCamera = cameraMotion(P);
        float moved = max(length((hitOwn - (surfaceVelocity - surfaceCamera)) * vec2(atlas)) - 0.5, 0.0);
        o_ssrMotion_texture = vec4(0.0, 0.0, moved, 0.0);

        // where the hit stood last frame as seen from this frame's camera, so a moving object's own step is known in 3d
        vec4 hc = u_proj * vec4(hitEye, 1.0);
        vec4 was = u_invProj * vec4(hc.xy / hc.w + 2.0 * hitOwn, hc.z / hc.w, 1.0);
        vec3 travel = hitEye - was.xyz / was.w;

        // the reflection is an image mirrored behind the surface, its step mirrored the same way, and its history waits where that image was
        mat3 invRot = transpose(mat3(u_view));
        vec3 image = P + normalize(P) * length(hitEye - P);
        vec3 imagePrev = image - (travel - 2.0 * dot(travel, N) * N);
        vec4 ip = u_prevViewProj * vec4(invRot * (imagePrev - u_view[3].xyz), 1.0);
        vec4 ic = u_proj * vec4(image, 1.0);
        if (ip.w > 1e-4 && ic.w > 1e-4)
          o_ssrMotion_texture = vec4(surfaceVelocity - surfaceCamera + (ip.xy / ip.w - ic.xy / ic.w) * 0.5, moved, 1.0);
        if (any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)))) return;

        vec2 edge = min(hitUV, 1.0 - hitUV);
        float confidence = clamp(min(edge.x, edge.y) * 10.0, 0.0, 1.0)
                         * (1.0 - clamp((roughness - u_ssr.x) / 0.2, 0.0, 1.0));
        vec3 hit = finiteColor(texture(u_history_texture, prevUV).rgb);
        hit *= min(1.0, 10.0 / max(max(hit.r, max(hit.g, hit.b)), 1e-6));
        o_ssrRadiance_texture = vec4(hit, confidence);
      }
      """#
    }

    var fragmentMSL: String
    {
      #"""
      constexpr constant float PI = 3.14159265358979;

      \#(ShaderLibrary.probeVolumeMSL)

      \#(ShaderLibrary.hizAtlasMSL)

      float3 finiteColor(float3 c)
      {
        bool3 bad = (as_type<uint3>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float3(0.0), bad);
      }

      float3 sampleGGXVisible(float3 N, float3 V, float a, float2 xi)
      {
        float3 T = normalize(cross(abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0), N));
        float3 B = cross(N, T);
        float3 Vt = float3(dot(V, T), dot(V, B), dot(V, N));
        float3 Vh = normalize(float3(a * Vt.x, a * Vt.y, Vt.z));
        float lensq = dot(Vh.xy, Vh.xy);
        float3 T1 = lensq > 0.0 ? float3(-Vh.y, Vh.x, 0.0) * rsqrt(lensq) : float3(1.0, 0.0, 0.0);
        float3 T2 = cross(Vh, T1);
        float r = sqrt(xi.x);
        float phi = 2.0 * PI * xi.y;
        float t1 = r * cos(phi);
        float s = 0.5 * (1.0 + Vh.z);
        float t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * r * sin(phi);
        float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(1.0 - t1 * t1 - t2 * t2, 0.0)) * Vh;
        float3 Ht = normalize(float3(a * Nh.x, a * Nh.y, max(Nh.z, 0.0)));
        return T * Ht.x + B * Ht.y + N * Ht.z;
      }

      float2 cameraMotion(float3 eye, float3x3 invRot, constant Uniforms& u)
      {
        float4 prev = u.u_prevViewProj * float4(invRot * (eye - u.u_view[3].xyz), 1.0);
        float4 curr = u.u_proj * float4(eye, 1.0);
        if (prev.w < 1e-4 || curr.w < 1e-4) return float2(0.0);
        return (prev.xy / prev.w - curr.xy / curr.w) * 0.5;
      }

      float3 viewPosition(float2 uv, float z, float4x4 proj)
      {
        float2 ndc = uv * 2.0 - 1.0;
        float w = proj[2][3] * z + proj[3][3];
        return float3((ndc.x * w - proj[2][0] * z - proj[3][0]) / proj[0][0],
                      (ndc.y * w - proj[2][1] * z - proj[3][1]) / proj[1][1], z);
      }

      float sceneDepth(float2 uv, texture2d<float> depthTex)
      {
        int2 size = int2(depthTex.get_width(), depthTex.get_height());
        float z = depthTex.read(uint2(clamp(int2(uv * float2(size)), int2(0), size - 1))).x;
        return z == 0.0 ? 1e30 : -z;
      }

      /// how deep the nearest face turned away from the eye lies behind a visible surface, which bounds that surface's solid
      float backDepth(float2 uv, float front, texture2d<float> backPos, texture2d<float> backNormal)
      {
        int2 size = int2(backPos.get_width(), backPos.get_height());
        uint2 p = uint2(clamp(int2(uv * float2(size)), int2(0), size - 1));

        // with no face behind it, or when the visible face is itself one turned away, the surface counts as a thin shell
        float thin = front + 0.05 + 0.02 * front;
        if (backNormal.read(p).a < 0.5) return thin;
        float z = -backPos.read(p).z;
        return z > front + 1e-3 ? z : thin;
      }

      float4 ssrTrace(float2 fragCoord, uint2 fp, int2 size, float4 n, float3 P,
                      texture2d<float> positionTex, texture2d<float> normalTex, texture2d<float> materialTex,
                      texture2d<float> historyTex, sampler historySmp, texture2d<float> depthTex,
                      texture2d<float> hizTex, texture2d<float> velocityTex, texture2d<float> backPosTex,
                      texture2d<float> backNormalTex, thread float4& reflectionMotion, thread float4& ray,
                      thread bool& hiddenHit, thread uint2& hiddenPixel, constant Uniforms& u)
      {
        float roughness = clamp(materialTex.read(fp).r, 0.045, 1.0);
        if (u.u_ssr.z < 0.5 || n.a < 0.5 || roughness >= u.u_ssr.x + 0.2) return float4(0.0);

        float2 noisePixel = fragCoord + 5.588238 * float(u.frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, float2(0.06711056, 0.00583715))));

        // the second dimension is a per pixel hash stepped by the golden ratio each frame, so the pair never lines up into a pattern
        uint2 q = uint2(fragCoord);
        uint seed = (q.x * 1597334677u) ^ (q.y * 3812015801u);
        seed = (seed ^ (seed >> 16)) * 0x7feb352du;
        seed = (seed ^ (seed >> 15)) * 0x846ca68bu;
        seed ^= seed >> 16;
        float noiseB = fract(float(seed >> 8) * 5.9604645e-8 + 0.61803398875 * float(u.frameIndex % 1024));

        float3 N = normalize(n.xyz);
        float3 V = normalize(-P);
        float3 R = reflect(-V, sampleGGXVisible(N, V, roughness * roughness, float2(noise, noiseB)));
        if (dot(R, N) <= 0.0) R = reflect(-V, N);

        // how likely this ray was to be picked, so the resolve can weigh it for a neighbour's own lobe
        float a2 = roughness * roughness * roughness * roughness;
        float NoV = max(dot(N, V), 1e-4);
        float NoH = saturate(dot(N, normalize(V + R)));
        float dd = NoH * NoH * (a2 - 1.0) + 1.0;
        float G1 = 2.0 * NoV / (NoV + sqrt(a2 + (1.0 - a2) * NoV * NoV));
        ray = float4(R, min(a2 / (PI * dd * dd) * G1 / (4.0 * NoV), 60000.0));

        float3 origin = P + N * (0.002 * -P.z);
        float nearPlane = u.u_proj[3][2] / (u.u_proj[2][2] - 1.0);
        float dist = u.u_ssr.y;
        if (R.z > 0.0) dist = min(dist, 0.99 * (-nearPlane - origin.z) / R.z);
        if (dist <= 0.0) return float4(0.0);

        float4 h0 = u.u_proj * float4(origin, 1.0);
        float4 h1 = u.u_proj * float4(origin + R * dist, 1.0);
        float k0 = 1.0 / h0.w;
        float k1 = 1.0 / h1.w;
        float2 s0 = h0.xy * k0 * 0.5 + 0.5;
        float2 s1 = h1.xy * k1 * 0.5 + 0.5;
        float2 d = s1 - s0;
        float tMax = 1.0;
        if (abs(d.x) > 1e-6) tMax = min(tMax, max(-s0.x / d.x, (1.0 - s0.x) / d.x));
        if (abs(d.y) > 1e-6) tMax = min(tMax, max(-s0.y / d.y, (1.0 - s0.y) / d.y));

        int2 atlas = int2(depthTex.get_width(), depthTex.get_height());
        float texels = max(length(d * float2(atlas)), 1e-4);
        float minT = 0.5 / texels;
        if (tMax <= minT) return float4(0.0);

        // walks the atlas a cell at a time, a level up for each clear cell and down when a cell may hold a hit
        int top = hizTopLevel(atlas);
        int level = 1;
        float t = minT;
        float tHit = -1.0;
        bool hidden = false;

        // whether the ray was clear of everything at its last step, rather than behind something
        bool wasInFront = true;

        // how deep the nearest thing the ray went behind lies, to tell when it comes out behind something farther
        float occluder = 0.0;
        float depthPrev = 1.0 / mix(k0, k1, minT);
        for (int i = 0; i < 80 && t < tMax; ++i) {
          float2 cell = float2(hizLevelSize(level, atlas));
          float tNext = hizCellExit(s0, d, t, cell, tMax);
          float2 mid = s0 + d * (0.5 * (t + tNext));
          float depthNear = 1.0 / mix(k0, k1, t);
          float depthFar = 1.0 / mix(k0, k1, tNext);
          float closest = hizClosest(level, int2(floor(mid * cell)), atlas, hizTex, depthTex);
          if (max(depthNear, depthFar) < closest) {
            // nothing under this cell reaches as near as the ray, so the ray clears all of it at once
            wasInFront = true;
            depthPrev = depthFar;
            t = tNext;
            level = min(level + 1, top);
            continue;
          }
          if (level > 0) {
            level -= 1;
            continue;
          }

          // one texel of the half resolution depth, where the crossing is solved rather than stepped
          float front = closest;

          // a straight ray only reaches what stands off the plane it left, which keeps a surface from reflecting itself
          if (dot(viewPosition(mid, -front, u.u_proj) - P, N) <= 0.0006 * front) {
            wasInFront = true;
            depthPrev = depthFar;
            t = tNext;
            level = min(level + 1, top);
            continue;
          }
          if (depthNear <= front) {
            if (depthFar > front) {
              float tc = abs(k1 - k0) < 1e-12 ? t : clamp((1.0 / front - k0) / (k1 - k0), t, tNext);
              float2 hitUV = s0 + d * tc;
              float4 facing = normalTex.read(uint2(clamp(int2(hitUV * float2(size)), int2(0), size - 1)));
              tHit = tc;
              hidden = facing.a < 0.5 || dot(facing.xyz, R) >= 0.0;
              break;
            }
            wasInFront = true;
            depthPrev = depthFar;
            t = tNext;
            continue;
          }

          // how deep this solid reaches, the far side the back layer holds or a thin shell where it holds none
          float back = backDepth(mid, front, backPosTex, backNormalTex);
          if (wasInFront) {
            // clear of everything a texel ago, so the ray met this surface's own face between then and now
            if (depthNear <= back + abs(depthFar - depthNear)) {
              float4 facing = normalTex.read(uint2(clamp(int2(mid * float2(size)), int2(0), size - 1)));
              tHit = 0.5 * (t + tNext);
              hidden = facing.a < 0.5 || dot(facing.xyz, R) >= 0.0;
              break;
            }

            // it already runs deeper than this solid reaches, so it passed clean behind
            occluder = front;
            wasInFront = false;
            depthPrev = depthFar;
            t = tNext;
            continue;
          }

          if (depthNear <= back + abs(depthNear - depthPrev)) {
            // already behind one thing and now within the next, so it came in through a face the camera never sees
            tHit = t;
            hidden = true;
            break;
          }
          if (front > occluder * 1.05 + 0.1) {
            // out from behind something past a farther surface, so it crossed it hidden, read a few texels on clear of the near rim
            float onward = min(t + 4.0 / texels, tMax);
            float there = sceneDepth(s0 + d * onward, depthTex);
            tHit = abs(there - front) < 0.1 + 0.05 * front ? onward : t;
            break;
          }
          depthPrev = depthFar;
          t = tNext;
        }
        if (tHit < 0.0) return float4(0.0);

        float2 hitUV = s0 + d * tHit;
        uint2 hitPixel = uint2(clamp(int2(hitUV * float2(size)), int2(0), size - 1));
        float3 hitEye;
        float4 hitNormal = normalTex.read(hitPixel);
        if (hidden) {
          // a hidden face is read from the back layer, which holds the side of the solid turned away from the eye
          int2 backSize = int2(backPosTex.get_width(), backPosTex.get_height());
          uint2 backPixel = uint2(clamp(int2(hitUV * float2(backSize)), int2(0), backSize - 1));
          if (backNormalTex.read(backPixel).a >= 0.5) {
            hitEye = backPosTex.read(backPixel).xyz;
            hiddenHit = true;
            hiddenPixel = backPixel;
          } else if (hitNormal.a >= 0.5) {
            // an open sheet has no far side drawn, so the face the camera does see is what the ray ran into
            hidden = false;
            hitEye = positionTex.read(hitPixel).xyz;
          } else {
            return float4(0.0);
          }
        } else {
          if (hitNormal.a < 0.5 || dot(hitNormal.xyz, R) > 0.0) return float4(0.0);
          hitEye = positionTex.read(hitPixel).xyz;
        }

        // the hit is read where its surface was last frame, moving with it rather than only with the camera
        float2 hitMotion = velocityTex.read(hitPixel).xy;
        float2 prevUV = u.u_taa.x > 0.5 ? hitUV + hitMotion : hitUV;

        // only what the hit or the surface moved on their own counts, the camera's part is followed exactly below
        float3x3 invRot = transpose(float3x3(u.u_view[0].xyz, u.u_view[1].xyz, u.u_view[2].xyz));
        float2 hitOwn = hitMotion - cameraMotion(hitEye, invRot, u);
        float2 surfaceVelocity = velocityTex.read(fp).xy;
        float2 surfaceCamera = cameraMotion(P, invRot, u);
        float moved = max(length((hitOwn - (surfaceVelocity - surfaceCamera)) * float2(atlas)) - 0.5, 0.0);
        reflectionMotion = float4(0.0, 0.0, moved, 0.0);

        // where the hit stood last frame as seen from this frame's camera, so a moving object's own step is known in 3d
        float4 hc = u.u_proj * float4(hitEye, 1.0);
        float4 was = u.u_invProj * float4(hc.xy / hc.w + 2.0 * hitOwn, hc.z / hc.w, 1.0);
        float3 travel = hitEye - was.xyz / was.w;

        // the reflection is an image mirrored behind the surface, its step mirrored the same way, and its history waits where that image was
        float3 image = P + normalize(P) * length(hitEye - P);
        float3 imagePrev = image - (travel - 2.0 * dot(travel, N) * N);
        float4 ip = u.u_prevViewProj * float4(invRot * (imagePrev - u.u_view[3].xyz), 1.0);
        float4 ic = u.u_proj * float4(image, 1.0);
        if (ip.w > 1e-4 && ic.w > 1e-4) {
          reflectionMotion = float4(surfaceVelocity - surfaceCamera + (ip.xy / ip.w - ic.xy / ic.w) * 0.5, moved, 1.0);
        }
        if (any(prevUV < float2(0.0)) || any(prevUV > float2(1.0))) return float4(0.0);

        float2 edge = min(hitUV, 1.0 - hitUV);
        float confidence = saturate(min(edge.x, edge.y) * 10.0)
                         * (1.0 - saturate((roughness - u.u_ssr.x) / 0.2));

        // a hidden face is lit by the caller, a visible one is read from last frame where it stood
        if (hidden) return float4(0.0, 0.0, 0.0, confidence);
        float3 hit = finiteColor(historyTex.sample(historySmp, prevUV).rgb);
        hit *= min(1.0, 10.0 / max(max(hit.r, max(hit.g, hit.b)), 1e-6));
        return float4(hit, confidence);
      }

      //@main
      {
        int2 size = int2(u_position_texture.get_width(), u_position_texture.get_height());
        uint2 fp = uint2(min(int2(floor(gl_FragCoord.xy) * u_halfScale.xy), size - 1));
        float4 n = u_normal_texture.read(fp);
        float3 P = u_position_texture.read(fp).xyz;
        o_ssrGuide_texture = float4(n.a < 0.5 ? float3(0.0) : normalize(n.xyz), P.z);
        float4 reflectionMotion = float4(0.0);
        float4 ray = float4(0.0);
        bool hiddenHit = false;
        uint2 hiddenPixel = uint2(0);
        float4 radiance = ssrTrace(gl_FragCoord.xy, fp, size, n, P,
                                   u_position_texture, u_normal_texture, u_material_texture,
                                   u_history_texture, u_history_texture_smp, u_ssgiDepth_texture,
                                   u_hiz_texture, u_velocity_texture, u_backPosition_texture,
                                   u_backNormal_texture, reflectionMotion, ray, hiddenHit, hiddenPixel, _u);
        if (hiddenHit) {
          // the camera never saw this face, so it is lit here from its own albedo and the room's irradiance along its normal
          float3x3 invRot = transpose(float3x3(u_view[0].xyz, u_view[1].xyz, u_view[2].xyz));
          float3 eye = u_backPosition_texture.read(hiddenPixel).xyz;
          float3 worldPos = invRot * (eye - u_view[3].xyz);
          float3 worldN = normalize(invRot * u_backNormal_texture.read(hiddenPixel).xyz);
          float4 albedo = u_backDiffuse_texture.read(hiddenPixel);
          float4 material = u_backMaterial_texture.read(hiddenPixel);
          float3 sky = mix(worldN, float3(worldN.x, worldN.z, -worldN.y), u_zUp);
          float3 fallback = texture(u_irradiance_texture, sky).rgb * u_iblTint.rgb * u_iblEnabled;
          float3 irradiance = probeVolumeIrradiance(worldPos, worldN, fallback, u_probe_volume, _u);
          float3 lit = albedo.rgb * (1.0 - saturate(material.g)) * irradiance + float3(material.b, material.a, albedo.a);
          radiance.rgb = finiteColor(lit);
        }
        o_ssrRadiance_texture = radiance;
        o_ssrMotion_texture = reflectionMotion;
        o_ssrRay_texture = ray;
      }
      """#
    }
  }
}
