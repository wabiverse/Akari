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

import Foundation
import Metal
import QuartzCore
import simd

extension Kraken
{
  /// the sculpt viewport's shaders, built from source when the renderer starts
  enum SculptShaders
  {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms
    {
      float4x4 viewProjection;
      float4x4 view;
      float4x4 inverseViewProjection;
      float4 eye;
      float4 light;
      float4 look;
      float4 painterly;
      float4 canvas;
      float4 clay;
      float4 top;
      float4 bottom;
      float4 viewport;
      float4 cursor;
      float4 cursorNormal;
      float4 reference;
      float4 tone;
      float4x4 projection;
      float4 projectionEye;
      float4 detail;
    };

    struct Vertex
    {
      packed_float3 position;
      packed_float3 normal;
      uint color;
      float mask;
    };

    struct PencilVertex
    {
      packed_float3 position;
      packed_float3 other;
      float side;
      float width;
      float along;
      uint color;
    };

    float hash21(float2 p)
    {
      p = fract(p * float2(123.34, 456.21));
      p += dot(p, p + 45.32);
      return fract(p.x * p.y);
    }

    float hash31(float3 p)
    {
      p = fract(p * float3(0.1031, 0.1030, 0.0973));
      p += dot(p, p.yxz + 33.33);
      return fract((p.x + p.y) * p.z);
    }

    float noise(float2 p)
    {
      float2 i = floor(p), f = fract(p);
      float2 s = f * f * (3.0 - 2.0 * f);
      float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
      return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
    }

    float fbm(float2 p)
    {
      float v = 0.0, a = 0.5;
      for (int i = 0; i < 4; ++i) { v += a * noise(p); p *= 2.03; a *= 0.5; }
      return v;
    }

    float3 toLinear(float3 c)
    {
      return pow(max(c, 0.0), 2.2);
    }

    // the eigenvector along an edge, from a smoothed structure tensor
    float2 flowDirection(float3 t, thread float &anisotropy)
    {
      float root = sqrt(max((t.y - t.x) * (t.y - t.x) + 4.0 * t.z * t.z, 0.0));
      float l1 = 0.5 * (t.x + t.y + root), l2 = 0.5 * (t.x + t.y - root);
      float2 v = float2(l1 - t.x, -t.z);
      anisotropy = (l1 + l2) > 1e-6 ? (l1 - l2) / (l1 + l2) : 0.0;
      return dot(v, v) > 1e-10 ? normalize(v) : float2(0.0, 1.0);
    }

    float3 backdrop(float2 uv, constant Uniforms &u)
    {
      float wash = fbm(uv * float2(3.0, 2.2) + 7.0);
      float t = saturate(1.0 - uv.y * 0.85 - (uv.x - 0.5) * 0.35 + (wash - 0.5) * 0.45);
      float3 c = mix(u.bottom.rgb, u.top.rgb, smoothstep(0.1, 0.95, t));

      // broad diagonal knife and brush passes, stretched along the stroke so the ground reads as paint
      float2 q = float2(uv.x * 0.8 + uv.y * 0.6, uv.y * 0.8 - uv.x * 0.6);
      float sweep = fbm(float2(q.x * 2.5, q.y * 22.0) + 3.0);
      float scumble = fbm(float2(q.x * 7.0, q.y * 60.0) + 11.0);
      c *= 0.82 + 0.3 * sweep + 0.12 * (scumble - 0.5);
      return c * (0.92 + 0.16 * fbm(uv * 9.0));
    }

    // MARK: g buffer

    struct GOut
    {
      float4 position [[position]];
      float3 normal;
      float4 color;
      float mask;
    };

    struct GTargets
    {
      float4 albedo [[color(0)]];
      float4 normal [[color(1)]];
    };

    // the sculpt draws in its own space, the scene around it brings its triangles in through `model`
    vertex GOut gVertex(const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                        constant float4x4 &model [[buffer(2)]], uint vid [[vertex_id]])
    {
      Vertex v = vertices[vid];
      GOut o;
      o.position = u.viewProjection * (model * float4(float3(v.position), 1.0));
      o.normal = (model * float4(float3(v.normal), 0.0)).xyz;
      o.color = unpack_unorm4x8_to_float(v.color);
      o.mask = v.mask;
      return o;
    }

    fragment GTargets gFragment(GOut in [[stage_in]], bool front [[front_facing]])
    {
      // the scene's meshes may wind either way, so a face seen from behind turns its normal to the eye
      GTargets t;
      t.albedo = in.color;
      t.normal = float4(normalize(front ? in.normal : -in.normal), in.mask);
      return t;
    }

    // MARK: fullscreen passes

    struct FOut
    {
      float4 position [[position]];
      float2 uv;
    };

    vertex FOut fullscreen(uint vid [[vertex_id]])
    {
      float2 p = float2((vid << 1) & 2, vid & 2);
      FOut o;
      o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
      o.uv = float2(p.x, 1.0 - p.y);
      return o;
    }

    float3 viewNormal(texture2d<float> normals, int2 p, int2 size, constant Uniforms &u)
    {
      float3 n = normals.read(uint2(clamp(p, int2(0), size - 1))).xyz;
      return (u.view * float4(n, 0.0)).xyz;
    }

    // the painting's marks read back where the surface faced the projecting camera, adding detail finer than a voxel where the paint still matches
    float3 paintDetail(float3 paint, float3 p, float3 n, texture2d<float> reference, depth2d<float> seen, constant Uniforms &u)
    {
      float3 toEye = normalize(u.projectionEye.xyz - p);
      float facing = dot(n, toEye);
      if (facing <= 0.12) return paint;

      float4 clip = u.projection * float4(p, 1.0);
      if (clip.w <= 1e-5) return paint;
      float2 ndc = clip.xy / clip.w;
      float2 view = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
      if (any(view < 0.0) || any(view > 1.0)) return paint;

      // nothing in front of it from the projecting camera, tested a few voxels toward that camera
      float4 lifted = u.projection * float4(p + toEye * u.detail.x * 3.0, 1.0);
      constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
      if (lifted.z / lifted.w > seen.sample(nearest, view)) return paint;

      // fitted into the projecting view the same way the paint was
      float imageAspect = u.reference.y, viewAspect = u.detail.w;
      float2 at = view;
      if (imageAspect < viewAspect) at.x = (at.x - 0.5) * (viewAspect / imageAspect) + 0.5;
      else at.y = (at.y - 0.5) * (imageAspect / viewAspect) + 0.5;
      if (any(at < 0.0) || any(at > 1.0)) return paint;

      // how many picture pixels one voxel covers, the level the voxel paint already holds
      float footprint = u.detail.x * u.detail.y / clip.w * 0.5 * u.detail.z;
      float lod = log2(max(footprint * 1.5, 1.0));
      constexpr sampler fine(filter::linear, mip_filter::linear, address::clamp_to_edge);
      float3 sharp = reference.sample(fine, at, level(0.0)).rgb;
      float3 broad = reference.sample(fine, at, level(lod)).rgb;

      float matches = 1.0 - smoothstep(0.08, 0.22, length(paint - broad));
      float w = saturate((facing - 0.12) / 0.35) * matches;
      return saturate(paint + (sharp - broad) * w);
    }

    fragment float4 lightFragment(FOut in [[stage_in]],
                                  texture2d<float> albedo [[texture(0)]],
                                  texture2d<float> normals [[texture(1)]],
                                  depth2d<float> depth [[texture(2)]],
                                  texture2d<float> reference [[texture(3)]],
                                  depth2d<float> seen [[texture(4)]],
                                  constant Uniforms &u [[buffer(0)]])
    {
      uint2 px = uint2(in.position.xy);
      float d = depth.read(px);
      if (d >= 1.0) return float4(backdrop(in.uv, u), 0.0);

      float4 a = albedo.read(px);
      float4 nm = normals.read(px);
      float3 n = normalize(nm.xyz);
      float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
      float4 w = u.inverseViewProjection * float4(ndc, d, 1.0);
      float3 p = w.xyz / w.w;
      float3 V = normalize(u.eye.xyz - p);

      // how sharply the surface bends here, from the normals around the pixel
      int2 size = int2(normals.get_width(), normals.get_height());
      int2 ip = int2(px);
      float3 nx0 = viewNormal(normals, ip - int2(1, 0), size, u), nx1 = viewNormal(normals, ip + int2(1, 0), size, u);
      float3 ny0 = viewNormal(normals, ip - int2(0, 1), size, u), ny1 = viewNormal(normals, ip + int2(0, 1), size, u);
      float curvature = (nx1.x - nx0.x) + (ny0.y - ny1.y);

      int mode = int(u.look.w);
      float3 L = normalize(u.light.xyz);
      float warmth = u.light.w;
      float3 key = float3(1.0, 0.93, 0.84) * (1.0 + warmth * 0.25);
      float3 fill = float3(0.55, 0.65, 0.85);
      float3 paint = a.rgb;
      if (mode != 0 && u.projectionEye.w > 0.5) paint = paintDetail(paint, p, n, reference, seen, u);
      float3 base = mode == 0 ? u.clay.rgb : toLinear(paint);
      float gloss = mode == 0 ? 0.3 : a.a;

      float lambert = saturate(dot(n, L) * 0.5 + 0.5);
      lambert *= lambert;
      if (mode == 2)
      {
        // a painter's chiaroscuro, values pushed apart and grouped into a few masses
        lambert = smoothstep(0.08, 0.9, lambert);
        if (u.canvas.z > 1.0)
        {
          float bands = u.canvas.z;
          float stepped = floor(lambert * bands) / bands + 0.5 / bands;
          lambert = mix(lambert, stepped, 0.55);
        }
      }

      float sky = saturate(n.y * 0.5 + 0.5);
      float3 shadowTint = mode == 2 ? float3(0.42, 0.5, 0.66) : fill;
      float3 color = base * (key * lambert + shadowTint * u.look.x * sky);
      if (mode == 2)
      {
        // the turn from light to shadow warms a little, the way flesh does in paint
        float turn = 1.0 - abs(lambert - 0.35) * 2.5;
        color += base * float3(0.18, 0.06, 0.04) * saturate(turn) * warmth;
      }

      float3 H = normalize(L + V);
      float power = mix(8.0, 180.0, gloss);
      color += key * pow(saturate(dot(n, H)), power) * gloss * (mode == 0 ? 0.35 : 1.2);

      float rim = pow(1.0 - saturate(dot(n, V)), 3.0) * u.look.y;
      color += fill * rim * (mode == 0 ? 0.25 : 0.35);

      float cavity = u.look.z;
      color *= 1.0 - cavity * saturate(-curvature * 3.0) * 0.7;
      color += (mode == 0 ? 0.12 : 0.05) * cavity * saturate(curvature * 3.0);

      // paint projected from a picture already carries its light, so the lighting can step back toward the paint itself
      if (mode != 0) color = mix(base * (0.85 + 0.15 * lambert), color, u.tone.x);

      if (u.canvas.w > 0.5) color = mix(color, color * float3(0.25, 0.3, 0.45), nm.w * 0.75);
      return float4(color, 1.0);
    }

    float luminance(texture2d<float> lit, int2 p, int2 size)
    {
      return dot(lit.read(uint2(clamp(p, int2(0), size - 1))).rgb, float3(0.3, 0.59, 0.11));
    }

    // the sobel gradient's outer product at each pixel, read back by the tensor pass below
    fragment float4 gradientFragment(FOut in [[stage_in]], texture2d<float> lit [[texture(0)]])
    {
      int2 size = int2(lit.get_width(), lit.get_height());
      int2 c = int2(in.position.xy);
      float l00 = luminance(lit, c + int2(-1, -1), size), l10 = luminance(lit, c + int2(0, -1), size);
      float l20 = luminance(lit, c + int2(1, -1), size), l01 = luminance(lit, c + int2(-1, 0), size);
      float l21 = luminance(lit, c + int2(1, 0), size), l02 = luminance(lit, c + int2(-1, 1), size);
      float l12 = luminance(lit, c + int2(0, 1), size), l22 = luminance(lit, c + int2(1, 1), size);
      float gx = (l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02);
      float gy = (l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20);
      return float4(gx * gx, gy * gy, gx * gy, 1.0);
    }

    // the structure tensor, gradients gathered over a widened neighborhood
    fragment float4 tensorFragment(FOut in [[stage_in]], texture2d<float> gradient [[texture(0)]])
    {
      int2 size = int2(gradient.get_width(), gradient.get_height());
      int2 p = int2(in.position.xy);
      float3 sum = 0.0;
      float total = 0.0;

      for (int j = -1; j <= 1; ++j)
      {
        for (int i = -1; i <= 1; ++i)
        {
          int2 c = clamp(p + int2(i, j) * 2, int2(0), size - 1);
          float w = (i == 0 && j == 0) ? 4.0 : (i == 0 || j == 0) ? 2.0 : 1.0;
          sum += gradient.read(uint2(c)).xyz * w;
          total += w;
        }
      }

      return float4(sum / total, 1.0);
    }

    // anisotropic kuwahara with polynomial sector weights, the oil paint abstraction
    fragment float4 kuwaharaFragment(FOut in [[stage_in]],
                                     texture2d<half> lit [[texture(0)]],
                                     texture2d<float> tensor [[texture(1)]],
                                     constant Uniforms &u [[buffer(0)]])
    {
      int2 size = int2(lit.get_width(), lit.get_height());
      int2 p = int2(in.position.xy);
      float radius = max(u.painterly.w, 1.0);
      float anisotropy;
      float2 dir = flowDirection(tensor.read(uint2(p)).xyz, anisotropy);

      float phi = -atan2(dir.y, dir.x);
      float alpha = 1.0;
      float a = radius * clamp((alpha + anisotropy) / alpha, 0.1, 2.0);
      float b = radius * clamp(alpha / (alpha + anisotropy), 0.1, 2.0);
      float cp = cos(phi), sp = sin(phi);
      float2x2 R = float2x2(float2(cp, -sp), float2(sp, cp));
      float2x2 S = float2x2(float2(0.5 / a, 0.0), float2(0.0, 0.5 / b));
      half2x2 SR = half2x2(S * R);
      int mx = int(sqrt(a * a * cp * cp + b * b * sp * sp));
      int my = int(sqrt(a * a * sp * sp + b * b * cp * cp));

      float zeroCross = 0.58;
      float sz = sin(zeroCross);
      half zeta = half(2.0 / radius);
      half eta = half((2.0 / radius + cos(zeroCross)) / (sz * sz));

      // the kernel runs in half precision, reads every other pixel each way and judges sectors by luminance spread, the strokes over it hide the difference
      half4 m[8];
      half s[8];
      for (int k = 0; k < 8; ++k) { m[k] = 0.0; s[k] = 0.0; }

      // each sample's twin across the center uses the same weights turned half way round, so half the kernel serves both
      for (int y = 0; y <= my; y += 2)
      {
        for (int x = (y == 0 ? 0 : -(mx / 2) * 2); x <= mx; x += 2)
        {
          half2 v = SR * half2(x, y);
          if (dot(v, v) > 0.25h) continue;

          half w[8];
          half sum = 0.0h, z, vxx, vyy;

          vxx = zeta - eta * v.x * v.x;
          vyy = zeta - eta * v.y * v.y;
          z = max(0.0h, v.y + vxx); w[0] = z * z; sum += w[0];
          z = max(0.0h, -v.x + vyy); w[2] = z * z; sum += w[2];
          z = max(0.0h, -v.y + vxx); w[4] = z * z; sum += w[4];
          z = max(0.0h, v.x + vyy); w[6] = z * z; sum += w[6];

          half2 r = 0.70710678h * half2(v.x - v.y, v.x + v.y);
          vxx = zeta - eta * r.x * r.x;
          vyy = zeta - eta * r.y * r.y;
          z = max(0.0h, r.y + vxx); w[1] = z * z; sum += w[1];
          z = max(0.0h, -r.x + vyy); w[3] = z * z; sum += w[3];
          z = max(0.0h, -r.y + vxx); w[5] = z * z; sum += w[5];
          z = max(0.0h, r.x + vyy); w[7] = z * z; sum += w[7];

          half g = exp(-3.125h * dot(v, v)) / max(sum, 1e-6h);
          half3 c = half3(saturate(lit.read(uint2(clamp(p + int2(x, y), int2(0), size - 1))).rgb));
          half lc = dot(c, half3(0.2126h, 0.7152h, 0.0722h));
          for (int k = 0; k < 8; ++k)
          {
            half wk = half(w[k] * g);
            m[k] += half4(c * wk, wk);
            s[k] += lc * lc * wk;
          }

          if (x == 0 && y == 0) continue;
          half3 o = half3(saturate(lit.read(uint2(clamp(p - int2(x, y), int2(0), size - 1))).rgb));
          half lo = dot(o, half3(0.2126h, 0.7152h, 0.0722h));
          for (int k = 0; k < 8; ++k)
          {
            half wk = half(w[(k + 4) & 7] * g);
            m[k] += half4(o * wk, wk);
            s[k] += lo * lo * wk;
          }
        }
      }

      float4 result = 0.0;
      for (int k = 0; k < 8; ++k)
      {
        if (m[k].w <= 0.0) continue;
        float3 mean = float3(m[k].rgb) / float(m[k].w);
        float l = dot(mean, float3(0.2126, 0.7152, 0.0722));
        float sigma = 3.0 * abs(float(s[k]) / float(m[k].w) - l * l);
        float w = 1.0 / (1.0 + pow(1000.0 * sigma, 4.0));
        result += float4(mean * w, w);
      }

      float3 painted = result.w > 0.0 ? result.rgb / result.w : float3(lit.read(uint2(p)).rgb);
      return float4(painted, 1.0);
    }

    // MARK: brush strokes

    struct SplatOut
    {
      float4 position [[position]];
      float2 local;
      float3 color;
      float seed;
    };

    vertex SplatOut splatVertex(const device Vertex *vertices [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]],
                                texture2d<float> lit [[texture(0)]],
                                texture2d<float> tensor [[texture(1)]],
                                uint vid [[vertex_id]], uint iid [[instance_id]])
    {
      SplatOut o;
      o.position = float4(0.0, 0.0, 2.0, 1.0);
      o.local = 0.0;
      o.color = 0.0;
      o.seed = 0.0;

      Vertex v = vertices[iid];
      float3 n = float3(v.normal);
      float3 p = float3(v.position);
      if (dot(n, n) < 0.5) return o;

      float seed = hash31(floor(p * 997.0));
      if (seed > u.painterly.z) return o;
      if (dot(n, normalize(u.eye.xyz - p)) < 0.02) return o;

      float4 clip = u.viewProjection * float4(p, 1.0);
      if (clip.w <= 0.0) return o;

      float2 ndc = clip.xy / clip.w;

      // a vertex stands for about a voxel of surface and lays a stroke only while strokes stay under six deep
      float3 up = float3(u.view[0].y, u.view[1].y, u.view[2].y);
      float4 above = u.viewProjection * float4(p + up * u.tone.y, 1.0);
      float2 step = (above.xy / above.w - ndc) * u.viewport.xy * 0.5;
      float footprint = 4.0 * u.painterly.x * u.painterly.x * max(u.painterly.y, 1.0);
      if (seed > u.painterly.z * min(1.0, 6.0 * dot(step, step) / max(footprint, 1.0))) return o;
      float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
      int2 size = int2(lit.get_width(), lit.get_height());
      uint2 px = uint2(clamp(int2(uv * float2(size)), int2(0), size - 1));

      float anisotropy;
      float2 dir = flowDirection(tensor.read(px).xyz, anisotropy);
      float turn = (hash31(p * 31.0) - 0.5) * (1.4 - anisotropy);
      float ct = cos(turn), st = sin(turn);
      dir = float2(dir.x * ct - dir.y * st, dir.x * st + dir.y * ct);
      float2 across = float2(-dir.y, dir.x);

      float3 color = saturate(lit.read(px).rgb);
      color *= 0.96 + 0.08 * hash31(p * 17.0);

      uint corner = vid & 3u;
      float2 c = float2((corner & 1u) ? 1.0 : -1.0, (corner & 2u) ? 1.0 : -1.0);
      float size0 = u.painterly.x * (0.7 + 0.6 * hash31(p * 7.0));
      float2 offset = (dir * c.x * size0 * u.painterly.y + across * c.y * size0) * u.viewport.zw * 2.0;

      o.position = float4(ndc + float2(offset.x, -offset.y), clip.z / clip.w - 0.0004, 1.0);
      o.local = c;
      o.color = color;
      o.seed = seed;
      return o;
    }

    fragment float4 splatFragment(SplatOut in [[stage_in]])
    {
      float2 q = in.local;

      // a loaded brush leaves a clean edge, the bristles show inside the mark and not as a blurred rim
      float body = smoothstep(1.0, 0.86, length(float2(q.x * 0.8, q.y)));
      float taper = smoothstep(1.0, 0.7, abs(q.x)) * (0.9 + 0.1 * q.x);
      if (body * taper <= 0.0) discard_fragment();
      float bristle = noise(float2(q.y * 9.0 + in.seed * 40.0, q.x * 1.2));
      float a = saturate(body * taper * (0.85 + 0.15 * bristle)) * 0.95;

      // impasto, the bristle ridges catch light on one side and the loaded end of the stroke stands proud
      float ridge = noise(float2(q.y * 9.0 + in.seed * 40.0 + 0.15, q.x * 1.2)) - bristle;
      float load = smoothstep(-0.2, 0.9, q.x) * 0.08;
      float3 c = in.color * (1.0 + ridge * 0.3 + load * 0.5);
      return float4(c * a, a);
    }

    // MARK: pencil

    struct PencilOut
    {
      float4 position [[position]];
      float4 color;
      float side;
      float along;
    };

    vertex PencilOut pencilVertex(const device PencilVertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                                  uint vid [[vertex_id]])
    {
      PencilVertex v = vertices[vid];
      float4 a = u.viewProjection * float4(float3(v.position), 1.0);
      float4 b = u.viewProjection * float4(float3(v.other), 1.0);
      float2 sa = a.xy / max(a.w, 1e-5) * u.viewport.xy * 0.5;
      float2 sb = b.xy / max(b.w, 1e-5) * u.viewport.xy * 0.5;
      float2 d = sb - sa;
      d = dot(d, d) > 1e-8 ? normalize(d) : float2(1.0, 0.0);
      float2 perp = float2(-d.y, d.x);

      // the world width across at this depth, in pixels
      float pixels = v.width * u.viewProjection[1][1] / max(a.w, 1e-5) * u.viewport.y * 0.5;
      float2 offset = perp * v.side * max(pixels * 0.5, 0.75) / (u.viewport.xy * 0.5);

      PencilOut o;
      o.position = float4(a.xy / max(a.w, 1e-5) + offset, a.z / max(a.w, 1e-5) - 0.0006, 1.0);
      o.color = unpack_unorm4x8_to_float(v.color);
      o.side = v.side;
      o.along = v.along;
      return o;
    }

    fragment float4 pencilFragment(PencilOut in [[stage_in]], constant Uniforms &u [[buffer(0)]])
    {
      float edge = smoothstep(1.0, 0.55, abs(in.side));
      float dry = 0.7 + 0.3 * noise(float2(in.along * 40.0, in.side * 3.0));
      float a = in.color.a * edge * (u.look.w > 1.5 ? dry : 1.0);
      float3 c = toLinear(in.color.rgb);
      return float4(c * a, a);
    }

    // MARK: composite

    float depthAt(depth2d<float> depth, int2 p, int2 size)
    {
      return depth.read(uint2(clamp(p, int2(0), size - 1)));
    }

    fragment float4 compositeFragment(FOut in [[stage_in]],
                                      texture2d<float> image [[texture(0)]],
                                      depth2d<float> depth [[texture(1)]],
                                      texture2d<float> referenceImage [[texture(2)]],
                                      constant Uniforms &u [[buffer(0)]])
    {
      uint2 px = uint2(in.position.xy);
      float3 c = image.read(px).rgb;
      int mode = int(u.look.w);

      if (mode == 2)
      {
        int2 size = int2(depth.get_width(), depth.get_height());
        int2 ip = int2(px);
        float e = abs(depthAt(depth, ip + int2(2, 0), size) - depthAt(depth, ip - int2(2, 0), size))
                + abs(depthAt(depth, ip + int2(0, 2), size) - depthAt(depth, ip - int2(0, 2), size));
        float edge = smoothstep(0.0005, 0.004, e);
        float found = step(u.canvas.y, fbm(in.position.xy * 0.02));
        c *= 1.0 - 0.18 * edge * found;

        float2 g = in.position.xy;
        float weave = sin(g.x * 1.9) * sin(g.y * 1.9) * 0.5 + 0.5;
        float tooth = fbm(g * 0.35);
        c *= 1.0 + (weave * 0.4 + tooth * 0.6 - 0.5) * u.canvas.x * 0.35;
        c = mix(c, c * float3(1.02, 0.99, 0.95), 0.5);
      }

      float2 q = in.uv - 0.5;
      c *= 1.0 - dot(q, q) * (mode == 2 ? 0.9 : 0.4);
      c = c / (1.0 + c * 0.12);
      float3 shown = pow(saturate(c), 1.0 / 2.2);

      // the reference laid over the sculpt, fitted the same way paint is projected from it
      if (u.reference.x > 0.0)
      {
        float viewportAspect = u.viewport.x / u.viewport.y;
        float imageAspect = u.reference.y;
        float2 p = in.uv;
        if (imageAspect < viewportAspect) p.x = (p.x - 0.5) * (viewportAspect / imageAspect) + 0.5;
        else p.y = (p.y - 0.5) * (imageAspect / viewportAspect) + 0.5;
        if (all(p >= 0.0) && all(p <= 1.0))
        {
          constexpr sampler linear(filter::linear);
          shown = mix(shown, referenceImage.sample(linear, p).rgb, u.reference.x);
        }
      }

      return float4(shown, 1.0);
    }

    // MARK: brush ring

    vertex float4 ringVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]])
    {
      uint segment = vid / 6u, corner = vid % 6u;
      float3 n = normalize(u.cursorNormal.xyz);
      float3 t = normalize(abs(n.y) < 0.95 ? cross(n, float3(0, 1, 0)) : cross(n, float3(1, 0, 0)));
      float3 b = cross(n, t);
      float step = 6.2831853 / 64.0;
      uint k = (corner == 1u || corner == 2u || corner == 4u) ? segment + 1u : segment;
      float angle = float(k) * step;
      float3 p = u.cursor.xyz + (t * cos(angle) + b * sin(angle)) * u.cursor.w + n * u.cursor.w * 0.01;
      float3 q = u.cursor.xyz + (t * cos(angle + step) + b * sin(angle + step)) * u.cursor.w;
      float4 a = u.viewProjection * float4(p, 1.0);
      float4 c = u.viewProjection * float4(q, 1.0);
      float2 d = normalize((c.xy / c.w - a.xy / a.w) * u.viewport.xy + 1e-6);
      float side = (corner == 2u || corner == 4u || corner == 5u) ? 1.0 : -1.0;
      float2 offset = float2(-d.y, d.x) * side * 1.25 * 2.0 * u.viewport.zw;
      return float4(a.xy / a.w + offset, 0.0, 1.0);
    }

    fragment float4 ringFragment()
    {
      return float4(0.95, 0.95, 0.95, 0.9);
    }
    """
  }

  /// shader inputs shared by every pass, laid out like the shaders' uniforms
  struct SculptUniforms
  {
    var viewProjection = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var inverseViewProjection = matrix_identity_float4x4
    var eye = SIMD4<Float>.zero
    var light = SIMD4<Float>.zero
    var look = SIMD4<Float>.zero
    var painterly = SIMD4<Float>.zero
    var canvas = SIMD4<Float>.zero
    var clay = SIMD4<Float>.zero
    var top = SIMD4<Float>.zero
    var bottom = SIMD4<Float>.zero
    var viewport = SIMD4<Float>.zero
    var cursor = SIMD4<Float>.zero
    var cursorNormal = SIMD4<Float>.zero
    var reference = SIMD4<Float>.zero
    var tone = SIMD4<Float>.zero
    var projection = matrix_identity_float4x4
    var projectionEye = SIMD4<Float>.zero
    var detail = SIMD4<Float>.zero
  }

  /// a pencil ribbon corner, expanded across the screen by the shader
  struct SculptPencilVertex
  {
    var x: Float, y: Float, z: Float
    var ox: Float, oy: Float, oz: Float
    var side: Float
    var width: Float
    var along: Float
    var color: UInt32
  }

  /// every brick's mesh in two shared buffers, each brick in a slot it can grow into
  final class SculptMeshArena
  {
    struct Slot
    {
      var vertexOffset: Int
      var vertexCapacity: Int
      var indexOffset: Int
      var indexCapacity: Int
    }

    let device: MTLDevice
    private(set) var vertices: MTLBuffer
    private(set) var indices: MTLBuffer
    private(set) var vertexCount = 0
    private(set) var indexCount = 0
    private var slots: [SIMD3<Int32>: Slot] = [:]
    private var wasted = 0

    init(device: MTLDevice)
    {
      self.device = device
      vertices = device.makeBuffer(length: 1 << 20, options: .storageModeShared)!
      indices = device.makeBuffer(length: 1 << 20, options: .storageModeShared)!
    }

    var needsCompacting: Bool
    {
      wasted > 1 << 16 && wasted > indexCount / 2
    }

    func reset()
    {
      slots.removeAll()
      vertexCount = 0
      indexCount = 0
      wasted = 0
    }

    private func grow(_ buffer: MTLBuffer, used: Int, needed: Int) -> MTLBuffer
    {
      guard needed > buffer.length else { return buffer }
      var length = buffer.length
      while length < needed { length *= 2 }
      let next = device.makeBuffer(length: length, options: .storageModeShared)!
      memcpy(next.contents(), buffer.contents(), used)
      return next
    }

    /// clears a slot to empty triangles and hidden vertices so neither draws
    private func blank(_ slot: Slot)
    {
      let v = vertices.contents().bindMemory(to: SculptVertex.self, capacity: vertexCount)
      for i in slot.vertexOffset ..< slot.vertexOffset + slot.vertexCapacity { v[i] = .empty }
      let x = indices.contents().bindMemory(to: UInt32.self, capacity: indexCount)
      for i in slot.indexOffset ..< slot.indexOffset + slot.indexCapacity { x[i] = UInt32(slot.vertexOffset) }
    }

    func write(_ key: SIMD3<Int32>, _ chunk: SculptChunk?)
    {
      guard let chunk, !chunk.isEmpty else
      {
        if let old = slots.removeValue(forKey: key)
        {
          blank(old)
          wasted += old.indexCapacity
        }

        return
      }

      var slot: Slot
      if let old = slots[key], old.vertexCapacity >= chunk.vertices.count, old.indexCapacity >= chunk.indices.count
      {
        slot = old
      }
      else
      {
        if let old = slots[key]
        {
          blank(old)
          wasted += old.indexCapacity
        }

        let vc = chunk.vertices.count + chunk.vertices.count / 4 + 16

        // slots hold whole triangles so every slot starts on a triangle boundary
        let ic = (chunk.indices.count + chunk.indices.count / 4 + 48 + 2) / 3 * 3
        vertices = grow(vertices, used: vertexCount * 32, needed: (vertexCount + vc) * 32)
        indices = grow(indices, used: indexCount * 4, needed: (indexCount + ic) * 4)
        slot = Slot(vertexOffset: vertexCount, vertexCapacity: vc, indexOffset: indexCount, indexCapacity: ic)
        vertexCount += vc
        indexCount += ic
        slots[key] = slot
      }

      let v = vertices.contents().bindMemory(to: SculptVertex.self, capacity: vertexCount)
      chunk.vertices.withUnsafeBufferPointer { memcpy(v + slot.vertexOffset, $0.baseAddress!, $0.count * 32) }
      for i in slot.vertexOffset + chunk.vertices.count ..< slot.vertexOffset + slot.vertexCapacity { v[i] = .empty }

      let x = indices.contents().bindMemory(to: UInt32.self, capacity: indexCount)
      let base = UInt32(slot.vertexOffset)
      for (i, index) in chunk.indices.enumerated() { x[slot.indexOffset + i] = index + base }
      for i in slot.indexOffset + chunk.indices.count ..< slot.indexOffset + slot.indexCapacity { x[i] = base }
    }
  }

  /// draws the sculpt with metal, clay, studio or painterly
  @MainActor
  final class SculptRenderer
  {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let arena: SculptMeshArena

    private var gPipeline: MTLRenderPipelineState
    private var lightPipeline: MTLRenderPipelineState
    private var tensorPipeline: MTLRenderPipelineState
    private var gradientPipeline: MTLRenderPipelineState
    private var kuwaharaPipeline: MTLRenderPipelineState
    private var splatPipeline: MTLRenderPipelineState
    private var pencilPipeline: MTLRenderPipelineState
    private var compositePipeline: MTLRenderPipelineState
    private var ringPipeline: MTLRenderPipelineState
    private var seenPipeline: MTLRenderPipelineState
    private var depthWrite: MTLDepthStencilState
    private var depthTest: MTLDepthStencilState

    private var albedo: MTLTexture?
    private var normals: MTLTexture?
    private var depth: MTLTexture?
    private var lit: MTLTexture?
    private var tensor: MTLTexture?
    private var gradient: MTLTexture?
    private var painted: MTLTexture?
    private var seen: MTLTexture?
    private lazy var unseen: MTLTexture? =
    {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
      d.usage = [.renderTarget, .shaderRead]
      d.storageMode = .private
      return device.makeTexture(descriptor: d)
    }()

    private var referenceTexture: MTLTexture?
    private var referenceRevision = -1
    private lazy var blank: MTLTexture? =
    {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
      d.usage = .shaderRead
      return device.makeTexture(descriptor: d)
    }()

    private var pencilBuffer: MTLBuffer?
    private var pencilCount = 0
    private var pencilRevision = -1

    /// whether this renderer's arena holds the sculpt yet, each new view starts a new renderer that needs the whole mesh
    private var primed = false
    private var lastFrame: MTLCommandBuffer?

    /// counts mesh uploads, the projecting camera's depth is only drawn again when the mesh or that camera moves
    private var meshGeneration = 0
    private var seenKey: Int?

    /// the finished picture before the brush ring, kept so moving the ring alone doesn't paint everything again
    private var finished: MTLTexture?

    /// whether the gpu is still on the last frame, the view skips a frame rather than wait so the window stays responsive
    var isBusy: Bool
    {
      guard let lastFrame else { return false }
      return lastFrame.status != .completed && lastFrame.status != .error
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat)
    {
      guard let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: SculptShaders.source, options: nil)
      else { return nil }

      self.device = device
      self.queue = queue
      arena = SculptMeshArena(device: device)

      func pipeline(_ vertex: String, _ fragment: String, colors: [MTLPixelFormat], depth: Bool = false,
                    blend: Bool = false) -> MTLRenderPipelineState?
      {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = fragment.isEmpty ? nil : library.makeFunction(name: fragment)
        for (i, format) in colors.enumerated()
        {
          d.colorAttachments[i].pixelFormat = format
          if blend
          {
            d.colorAttachments[i].isBlendingEnabled = true
            d.colorAttachments[i].sourceRGBBlendFactor = .one
            d.colorAttachments[i].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[i].sourceAlphaBlendFactor = .one
            d.colorAttachments[i].destinationAlphaBlendFactor = .oneMinusSourceAlpha
          }
        }

        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
      }

      func ring() -> MTLRenderPipelineState?
      {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "ringVertex")
        d.fragmentFunction = library.makeFunction(name: "ringFragment")
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
      }

      let wide = MTLPixelFormat.rgba16Float
      guard let g = pipeline("gVertex", "gFragment", colors: [.rgba8Unorm, wide], depth: true),
            let light = pipeline("fullscreen", "lightFragment", colors: [wide]),
            let tensor = pipeline("fullscreen", "tensorFragment", colors: [wide]),
            let gradient = pipeline("fullscreen", "gradientFragment", colors: [.rgba32Float]),
            let kuwahara = pipeline("fullscreen", "kuwaharaFragment", colors: [wide]),
            let splat = pipeline("splatVertex", "splatFragment", colors: [wide], depth: true, blend: true),
            let pencil = pipeline("pencilVertex", "pencilFragment", colors: [wide], depth: true, blend: true),
            let composite = pipeline("fullscreen", "compositeFragment", colors: [pixelFormat]),
            let ring = ring(),
            let seen = pipeline("gVertex", "", colors: [], depth: true)
      else { return nil }

      gPipeline = g
      lightPipeline = light
      tensorPipeline = tensor
      gradientPipeline = gradient
      kuwaharaPipeline = kuwahara
      splatPipeline = splat
      pencilPipeline = pencil
      compositePipeline = composite
      ringPipeline = ring
      seenPipeline = seen

      let write = MTLDepthStencilDescriptor()
      write.depthCompareFunction = .less
      write.isDepthWriteEnabled = true
      let test = MTLDepthStencilDescriptor()
      test.depthCompareFunction = .lessEqual
      test.isDepthWriteEnabled = false
      guard let w = device.makeDepthStencilState(descriptor: write), let t = device.makeDepthStencilState(descriptor: test)
      else { return nil }

      depthWrite = w
      depthTest = t
    }

    private func targets(_ width: Int, _ height: Int)
    {
      guard albedo?.width != width || albedo?.height != height else { return }

      func texture(_ format: MTLPixelFormat) -> MTLTexture?
      {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
      }

      albedo = texture(.rgba8Unorm)
      normals = texture(.rgba16Float)
      depth = texture(.depth32Float)
      lit = texture(.rgba16Float)
      tensor = texture(.rgba16Float)
      gradient = texture(.rgba32Float)
      painted = texture(.rgba16Float)

      if seen == nil
      {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        seen = device.makeTexture(descriptor: d)
      }
    }

    /// keeps the reference image on the gpu, remade when a new one is loaded
    private func uploadReference(_ sculpt: Sculpt)
    {
      guard sculpt.referenceRevision != referenceRevision else { return }
      referenceRevision = sculpt.referenceRevision
      referenceTexture = nil
      guard let reference = sculpt.reference else { return }

      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: reference.width, height: reference.height,
                                                       mipmapped: true)
      d.usage = .shaderRead
      guard let texture = device.makeTexture(descriptor: d) else { return }
      reference.pixels.withUnsafeBytes
      { raw in
        texture.replace(region: MTLRegionMake2D(0, 0, reference.width, reference.height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: reference.width * 4)
      }

      // the coarser levels stand for what the voxel paint already holds
      if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
      {
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
      }

      referenceTexture = texture
    }

    /// the scene's meshes around the sculpt, sent again only when they change
    private var sceneBuffer: MTLBuffer?
    private var sceneCount = 0
    private var sceneRevision = -1

    private func uploadScene(_ sculpt: Sculpt)
    {
      guard sculpt.sceneRevision != sceneRevision else { return }
      sceneRevision = sculpt.sceneRevision
      sceneCount = sculpt.scene.count
      sceneBuffer = sceneCount > 0
        ? sculpt.scene.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        : nil
      if sceneBuffer == nil { sceneCount = 0 }
    }

    func upload(_ sculpt: Sculpt)
    {
      // packing the arena tight writes every brick again, so it waits for the stroke to end rather than stall one
      let compacts = arena.needsCompacting && !sculpt.isStroking
      guard !primed || sculpt.meshReset || !sculpt.uploads.isEmpty || compacts else { return }

      // the last frame may still be reading the buffers being written
      lastFrame?.waitUntilCompleted()
      meshGeneration &+= 1

      if !primed || sculpt.meshReset || compacts
      {
        arena.reset()
        for (k, chunk) in sculpt.chunks { arena.write(k, chunk) }
        primed = true
        sculpt.meshReset = false
        sculpt.uploads.removeAll()
        return
      }

      for (k, chunk) in sculpt.uploads { arena.write(k, chunk) }
      sculpt.uploads.removeAll()
    }

    private func uploadPencil(_ sculpt: Sculpt)
    {
      let drawing = sculpt.drawingPencil
      guard sculpt.pencilRevision != pencilRevision || drawing != nil else { return }
      pencilRevision = sculpt.pencilRevision

      var corners: [SculptPencilVertex] = []
      for line in sculpt.pencil + (drawing.map { [$0] } ?? []) where line.points.count > 1
      {
        let c = simd_clamp(line.color, .zero, SIMD3(repeating: 1)) * 255
        let packed = UInt32(c.x) | UInt32(c.y) << 8 | UInt32(c.z) << 16 | UInt32(min(max(line.opacity, 0), 1) * 255) << 24
        var along: Float = 0

        for i in 0 ..< line.points.count - 1
        {
          let a = line.points[i], b = line.points[i + 1]
          let wa = line.widths[i], wb = line.widths[min(i + 1, line.widths.count - 1)]
          let length = simd_distance(a, b)
          func corner(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ side: Float, _ width: Float, _ at: Float, flip: Bool) -> SculptPencilVertex
          {
            // the other end is ahead for the start and behind for the end, the shader keeps the side consistent
            SculptPencilVertex(x: p.x, y: p.y, z: p.z, ox: q.x, oy: q.y, oz: q.z, side: flip ? -side : side, width: width,
                               along: at, color: packed)
          }

          let a0 = corner(a, b, -1, wa, along, flip: false), a1 = corner(a, b, 1, wa, along, flip: false)
          let b0 = corner(b, a, -1, wb, along + length, flip: true), b1 = corner(b, a, 1, wb, along + length, flip: true)
          corners += [a0, a1, b1, a0, b1, b0]
          along += length
        }
      }

      pencilCount = corners.count
      guard !corners.isEmpty else { return }

      let length = corners.count * MemoryLayout<SculptPencilVertex>.stride
      if (pencilBuffer?.length ?? 0) < length || lastFrame?.status != .completed
      {
        pencilBuffer = device.makeBuffer(length: max(length, 4096), options: .storageModeShared)
      }

      corners.withUnsafeBytes { memcpy(pencilBuffer!.contents(), $0.baseAddress!, length) }
    }

    /// fills the uniforms from the camera and the sculpt's look
    func uniforms(_ sculpt: Sculpt, camera: SculptCamera, width: Int, height: Int, scale: Float) -> SculptUniforms
    {
      // the camera looks at the scene, everything the sculpt draws and lights stays in its own space
      let aspect = Float(width) / Float(max(height, 1))
      let frame = sculpt.frame, back = frame.inverse
      let view = camera.view * frame
      let projection = camera.projection(aspect: aspect)
      var u = SculptUniforms()
      u.viewProjection = projection * view
      u.view = view
      u.inverseViewProjection = u.viewProjection.inverse
      let eye = back * SIMD4(camera.eye, 1)
      u.eye = SIMD4(eye.x, eye.y, eye.z, 1)

      // the light turns with the camera so the form always reads, like a painter's studio lamp
      let light = sculpt.lightDirection
      let turned = back * SIMD4(simd_act(simd_quatf(angle: camera.yaw, axis: SIMD3(0, 1, 0)), light), 0)
      u.light = SIMD4(simd_normalize(SIMD3(turned.x, turned.y, turned.z)), Float(sculpt.warmth))

      let mode: Float = switch sculpt.shading
      {
        case .clay: 0
        case .studio: 1
        case .painterly: 2
      }

      u.look = SIMD4(Float(sculpt.ambient), Float(sculpt.rim), Float(sculpt.cavity), mode)
      u.painterly = SIMD4(Float(sculpt.strokeSize) * scale, Float(sculpt.strokeLength), Float(sculpt.strokeDensity),
                          Float(sculpt.abstraction) * scale)
      u.canvas = SIMD4(Float(sculpt.canvasGrain), 1 - Float(sculpt.lostEdges), Float(sculpt.bands), sculpt.showsMask ? 1 : 0)
      u.clay = SIMD4(SIMD3<Float>(sculpt.clayColor), 1)
      u.top = SIMD4(SculptUSD.linear(SIMD3<Float>(sculpt.backgroundTop)), 1)
      u.bottom = SIMD4(SculptUSD.linear(SIMD3<Float>(sculpt.backgroundBottom)), 1)
      u.viewport = SIMD4(Float(width), Float(height), 1 / Float(width), 1 / Float(height))
      u.tone = SIMD4(Float(sculpt.lighting), sculpt.volume.voxel, 0, 0)

      if let cursor = sculpt.cursor
      {
        u.cursor = SIMD4(cursor.center, cursor.radius)
        u.cursorNormal = SIMD4(cursor.normal, 1)
      }

      if let reference = sculpt.reference
      {
        u.reference = SIMD4(sculpt.showsReference ? Float(sculpt.referenceOpacity) : 0, reference.aspect, 0, 0)
        if let projection = sculpt.projection, referenceTexture != nil
        {
          let p = projection.camera.projection(aspect: projection.aspect)
          u.projection = p * projection.camera.view * frame
          let from = back * SIMD4(projection.camera.eye, 1)
          u.projectionEye = SIMD4(from.x, from.y, from.z, 1)
          let tall = Float(reference.height) * max(1, reference.aspect / projection.aspect)
          u.detail = SIMD4(sculpt.volume.voxel, p.columns.1.y, tall, projection.aspect)
        }
      }

      return u
    }

    func draw(_ sculpt: Sculpt, camera: SculptCamera, drawable: CAMetalDrawable, scale: Float, showsCursor: Bool, repaint: Bool = true)
    {
      let width = drawable.texture.width, height = drawable.texture.height
      let resized = albedo?.width != width || albedo?.height != height
      targets(width, height)
      upload(sculpt)
      uploadPencil(sculpt)
      uploadReference(sculpt)
      uploadScene(sculpt)

      guard let albedo, let normals, let depth, let lit, let tensor, let painted,
            let commands = queue.makeCommandBuffer()
      else { return }

      var u = uniforms(sculpt, camera: camera, width: width, height: height, scale: scale)
      let length = MemoryLayout<SculptUniforms>.stride
      let painterly = sculpt.shading == .painterly
      let paints = repaint || resized || finished == nil
      var image = finished ?? lit

      if paints
      {
        // surface into the g buffer
        let g = MTLRenderPassDescriptor()
        g.colorAttachments[0].texture = albedo
        g.colorAttachments[0].loadAction = .clear
        g.colorAttachments[0].storeAction = .store
        g.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        g.colorAttachments[1].texture = normals
        g.colorAttachments[1].loadAction = .clear
        g.colorAttachments[1].storeAction = .store
        g.depthAttachment.texture = depth
        g.depthAttachment.loadAction = .clear
        g.depthAttachment.storeAction = .store
        g.depthAttachment.clearDepth = 1

        if let encoder = commands.makeRenderCommandEncoder(descriptor: g)
        {
          var model = matrix_identity_float4x4
          encoder.setRenderPipelineState(gPipeline)
          encoder.setDepthStencilState(depthWrite)
          encoder.setCullMode(.back)
          encoder.setFrontFacing(.counterClockwise)
          encoder.setVertexBuffer(arena.vertices, offset: 0, index: 0)
          encoder.setVertexBytes(&u, length: length, index: 1)
          encoder.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 2)
          if arena.indexCount > 0
          {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: arena.indexCount, indexType: .uint32,
                                          indexBuffer: arena.indices, indexBufferOffset: 0)
          }

          // the rest of the scene, from the upright world into the sculpt's space, seen from either side
          if sceneCount > 0, let sceneBuffer
          {
            model = sculpt.frame.inverse
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(sceneBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sceneCount)
          }

          encoder.endEncoding()
        }

        // the surface as the projecting camera saw it, so picture detail only lands where the paint could reach
        var seenTexture = unseen
        var key = Hasher()
        key.combine(meshGeneration)
        withUnsafeBytes(of: u.projection) { key.combine(bytes: $0) }
        let seenNow = key.finalize()
        if u.projectionEye.w > 0.5, seenKey == seenNow, let seen { seenTexture = seen }
        else if u.projectionEye.w > 0.5, let seen, arena.indexCount > 0
        {
          let pass = MTLRenderPassDescriptor()
          pass.depthAttachment.texture = seen
          pass.depthAttachment.loadAction = .clear
          pass.depthAttachment.storeAction = .store
          pass.depthAttachment.clearDepth = 1
          if let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
          {
            var from = u
            from.viewProjection = u.projection
            var model = matrix_identity_float4x4
            encoder.setRenderPipelineState(seenPipeline)
            encoder.setDepthStencilState(depthWrite)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(arena.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&from, length: length, index: 1)
            encoder.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: arena.indexCount, indexType: .uint32,
                                          indexBuffer: arena.indices, indexBufferOffset: 0)
            encoder.endEncoding()
            seenTexture = seen
            seenKey = seenNow
          }
        }

        guard let reference = referenceTexture ?? blank, let seenTexture else { return }
        fullscreen(commands, lightPipeline, into: lit, textures: [albedo, normals, depth, reference, seenTexture], uniforms: &u)

        image = lit
        if painterly
        {
          if let gradient
          {
            fullscreen(commands, gradientPipeline, into: gradient, textures: [lit], uniforms: &u)
            fullscreen(commands, tensorPipeline, into: tensor, textures: [gradient], uniforms: &u)
          }
          fullscreen(commands, kuwaharaPipeline, into: painted, textures: [lit, tensor], uniforms: &u)
          image = painted

          // brush strokes over the abstraction, laid by every surface vertex the density keeps
          overlay(commands, image, depth)
          { encoder in
            encoder.setRenderPipelineState(splatPipeline)
            encoder.setVertexBuffer(arena.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: length, index: 1)
            encoder.setVertexTexture(lit, index: 0)
            encoder.setVertexTexture(tensor, index: 1)
            if arena.vertexCount > 0
            {
              encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: arena.vertexCount)
            }
          }
        }

        if pencilCount > 0, let pencilBuffer
        {
          overlay(commands, image, depth)
          { encoder in
            encoder.setRenderPipelineState(pencilPipeline)
            encoder.setVertexBuffer(pencilBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: length, index: 1)
            encoder.setFragmentBytes(&u, length: length, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pencilCount)
          }
        }

        finished = image
      }

      let final = MTLRenderPassDescriptor()
      final.colorAttachments[0].texture = drawable.texture
      final.colorAttachments[0].loadAction = .dontCare
      final.colorAttachments[0].storeAction = .store
      if let encoder = commands.makeRenderCommandEncoder(descriptor: final)
      {
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentTexture(depth, index: 1)
        encoder.setFragmentTexture(referenceTexture ?? blank, index: 2)
        encoder.setFragmentBytes(&u, length: length, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if showsCursor, sculpt.cursor != nil
        {
          encoder.setRenderPipelineState(ringPipeline)
          encoder.setVertexBytes(&u, length: length, index: 0)
          encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 64 * 6)
        }

        encoder.endEncoding()
      }

      commands.present(drawable)
      commands.commit()
      lastFrame = commands
    }

    private func fullscreen(_ commands: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, into target: MTLTexture,
                            textures: [MTLTexture], uniforms: inout SculptUniforms)
    {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
      encoder.setRenderPipelineState(pipeline)
      for (i, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: i) }
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SculptUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
    }

    /// a blended pass over an image, tested against the surface depth
    private func overlay(_ commands: MTLCommandBuffer, _ target: MTLTexture, _ depth: MTLTexture,
                         _ body: (MTLRenderCommandEncoder) -> Void)
    {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .load
      pass.colorAttachments[0].storeAction = .store
      pass.depthAttachment.texture = depth
      pass.depthAttachment.loadAction = .load
      pass.depthAttachment.storeAction = .store
      guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
      encoder.setDepthStencilState(depthTest)
      body(encoder)
      encoder.endEncoding()
    }
  }
}

