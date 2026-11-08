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
import HdAkari
import HydraKit
import LabGL

extension Akari.Geom.Deformer
{
  /// Per point of a GPU skinned mesh, its rest point blended by its joints' matrices,
  /// UsdSkel's linear blend skinning, into the points the rest of the deform reads.
  static let skinBody = """
      if (int(gid) >= PARAMS.x) return;
      INT2 r = skin_ranges[gid];
      if (r.y == 0) return;
      VEC4 h = VEC4(rest[gid * 3], rest[gid * 3 + 1], rest[gid * 3 + 2], 1.0);
      VEC3 p = VEC3(0.0);
      for (int i = 0; i < r.y; ++i)
      {
        VEC2 w = skin_weights[r.x + i];
        if (w.y <= 1e-5) continue;
        int j = int(w.x) * 3;
        p += w.y * VEC3(dot(palette[j], h), dot(palette[j + 1], h), dot(palette[j + 2], h));
      }
      points[gid * 3] = p.x;
      points[gid * 3 + 1] = p.y;
      points[gid * 3 + 2] = p.z;
    """

  static let skinGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer SkinRanges { ivec2 skin_ranges[]; };
    layout(std430, binding = 1) buffer SkinWeights { vec2 skin_weights[]; };
    layout(std430, binding = 2) buffer Palette { vec4 palette[]; };
    layout(std430, binding = 3) buffer Rest { float rest[]; };
    layout(std430, binding = 4) buffer Points { float points[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(skinBody)
    }
    """

  static let skinMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int2* skin_ranges [[buffer(1)]],
                             device const float2* skin_weights [[buffer(2)]],
                             device const float4* palette [[buffer(3)]],
                             device const float* rest [[buffer(4)]],
                             device float* points [[buffer(5)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(skinBody)
    }
    """

  /// Per triangle: its unit normal, and its doubled area for the smooth weighting.
  static let faceBody = """
      if (int(gid) >= PARAMS.x) return;
      INT4 f = faces[gid];
      if (f.x < 0) { face_normals[gid] = VEC4(0.0); return; }
      VEC3 p0 = VEC3(points[f.x * 3], points[f.x * 3 + 1], points[f.x * 3 + 2]);
      VEC3 p1 = VEC3(points[f.y * 3], points[f.y * 3 + 1], points[f.y * 3 + 2]);
      VEC3 p2 = VEC3(points[f.z * 3], points[f.z * 3 + 1], points[f.z * 3 + 2]);
      VEC3 n = cross(p1 - p0, p2 - p0);
      float l = length(n);
      face_normals[gid] = l > 1e-8 ? VEC4(n / l, l) : VEC4(0.0);
    """

  /// Per point: the area weighted smooth normal, and whether its faces meet within 30°.
  static let pointBody = """
      if (int(gid) >= PARAMS.x) return;
      int s = face_start[gid], e = face_start[gid + 1];
      VEC3 sum = VEC3(0.0);
      for (int i = s; i < e; ++i) { VEC4 fn = face_normals[face_list[i]]; sum += fn.xyz * fn.w; }
      float sl = length(sum);
      VEC3 smooth_n = sl > 1e-8 ? sum / sl : VEC3(0.0, 1.0, 0.0);
      bool is_smooth = true;
      for (int a = s; a < e && is_smooth; ++a)
      {
        VEC4 na = face_normals[face_list[a]];
        if (na.w <= 0.0) continue;
        for (int b = a + 1; b < e; ++b)
        {
          VEC4 nb = face_normals[face_list[b]];
          if (nb.w <= 0.0) continue;
          if (dot(na.xyz, nb.xyz) <= 0.8660254) { is_smooth = false; break; }
        }
      }
      point_normals[gid] = VEC4(smooth_n, is_smooth ? 1.0 : 0.0);
    """

  /// Per triangle corner: the world space vertex `Batch` lays out.
  static let emitBody = """
      if (int(gid) >= PARAMS.x) return;
      INT2 c = corners[gid];
      int p = c.x;
      int face = c.y & 0x0FFFFFFF;
      int base = point_mesh[p] * 40;
      VEC3 lp = VEC3(points[p * 3], points[p * 3 + 1], points[p * 3 + 2]);
      VEC4 pn = point_normals[p];
      VEC4 fn = face_normals[face];
      VEC3 n = (pn.w > 0.5 || fn.w <= 0.0) ? pn.xyz : fn.xyz;
      int o = int(gid) * 14;
      VEC3 wp = VEC3(xf[base + 0] * lp.x + xf[base + 4] * lp.y + xf[base + 8] * lp.z + xf[base + 12],
                     xf[base + 1] * lp.x + xf[base + 5] * lp.y + xf[base + 9] * lp.z + xf[base + 13],
                     xf[base + 2] * lp.x + xf[base + 6] * lp.y + xf[base + 10] * lp.z + xf[base + 14]);
      VEC3 nw = VEC3(xf[base + 16] * n.x + xf[base + 17] * n.y + xf[base + 18] * n.z,
                     xf[base + 19] * n.x + xf[base + 20] * n.y + xf[base + 21] * n.z,
                     xf[base + 22] * n.x + xf[base + 23] * n.y + xf[base + 24] * n.z);
      int k = int(gid) % 3;
      float s = 1.0;
      if (xf[base + 26] < 0.9999)
      {
        VEC3 center = VEC3(xf[base + 27], xf[base + 28], xf[base + 29]);
        float size = xf[base + 30];
        VEC3 up = xf[base + 31] > 0.5 ? VEC3(0.0, 0.0, 1.0) : VEC3(0.0, 1.0, 0.0);
        VEC3 toEye = VEC3(xf[base + 32], xf[base + 33], xf[base + 34]) - center;
        VEC3 fwd = length(toEye) > 1e-6 ? normalize(toEye) : VEC3(0.0, 0.0, 1.0);
        VEC3 side = cross(up, fwd);
        side = length(side) > 1e-6 ? normalize(side) : VEC3(1.0, 0.0, 0.0);
        VEC3 lift = cross(fwd, side);
        float angle = 1.5707963 + float(k) * 2.0943951;
        VEC3 target = center + (side * cos(angle) + lift * sin(angle)) * size;
        float hash = fract(sin(float(int(gid) / 3) * 12.9898) * 43758.5453);
        // ensures that a dense mesh isn't drawn a few hundred thousand times over the same pixels.
        int local = int(gid) / 3 - int(xf[base + 35]);
        bool spare = local != 0;
        VEC3 slot = center;
        if (spare)
        {
          float a = fract(sin(float(int(gid) / 3) * 78.233) * 24634.6345);
          float b = fract(sin(float(int(gid) / 3) * 39.3468) * 11789.5523);
          if (a + b > 1.0) { a = 1.0 - a; b = 1.0 - b; }
          VEC3 c0 = center + (side * cos(1.5707963) + lift * sin(1.5707963)) * size;
          VEC3 c1 = center + (side * cos(3.6651914) + lift * sin(3.6651914)) * size;
          VEC3 c2 = center + (side * cos(5.7595865) + lift * sin(5.7595865)) * size;
          slot = c0 + (c1 - c0) * a + (c2 - c0) * b;
          target = slot + (target - center) * (1.6 / sqrt(max(xf[base + 36], 1.0)));
        }
        float reach = clamp(length(wp - center) / max(size * 6.0, 1e-4), 0.0, 1.0);
        float t = clamp(xf[base + 26] * 1.6 - 0.6 * (0.35 * hash + 0.65 * reach), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        wp = mix(target, wp, s) + fwd * (sin(3.14159265 * s) * size * 0.5);
        // still in its slot, under the collapsed triangle: nothing to draw.
        if (spare && s < 0.02) wp = slot;
        nw = mix(fwd, nw, s);
      }
      // hidden meshes points are never written, it collapses to the origin.
      if (xf[base + 37] > 0.5) { wp = VEC3(0.0); nw = VEC3(0.0, 0.0, 1.0); }
      VEC3 prev = PARAMS.y != 0 && xf[base + 37] < 0.5 ? VEC3(out_verts[o + 0], out_verts[o + 1], out_verts[o + 2]) : wp;
      out_verts[o + 0] = wp.x;
      out_verts[o + 1] = wp.y;
      out_verts[o + 2] = wp.z;
      out_verts[o + 3] = float(k) * 2.0 + s + float((c.y >> 28) & 7) * 8.0;
      out_verts[o + 4] = xf[base + 25];
      out_verts[o + 5] = prev.x;
      out_verts[o + 6] = prev.y;
      out_verts[o + 7] = prev.z;
      out_verts[o + 8] = uvs[gid].x;
      out_verts[o + 9] = uvs[gid].y;
      out_verts[o + 10] = nw.x;
      out_verts[o + 11] = nw.y;
      out_verts[o + 12] = nw.z;
      out_verts[o + 13] = float(int(gid) / 3);
    """

  /// Per point, its world position once, for the shadows indexed draws.
  static let shadowBody = """
      if (int(gid) >= PARAMS.x) return;
      int p = int(gid);
      int base = point_mesh[p] * 40;
      VEC3 lp = VEC3(points[p * 3], points[p * 3 + 1], points[p * 3 + 2]);
      int o = p * 14;
      out_verts[o + 0] = xf[base + 0] * lp.x + xf[base + 4] * lp.y + xf[base + 8] * lp.z + xf[base + 12];
      out_verts[o + 1] = xf[base + 1] * lp.x + xf[base + 5] * lp.y + xf[base + 9] * lp.z + xf[base + 13];
      out_verts[o + 2] = xf[base + 2] * lp.x + xf[base + 6] * lp.y + xf[base + 10] * lp.z + xf[base + 14];
      if (xf[base + 37] > 0.5) { out_verts[o + 0] = 0.0; out_verts[o + 1] = 0.0; out_verts[o + 2] = 0.0; }
      out_verts[o + 3] = 1.0;
      out_verts[o + 4] = xf[base + 25];
      for (int k = 5; k < 14; ++k) out_verts[o + k] = 0.0;
      out_verts[o + 7] = 1.0;
    """

  static let shadowGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Points { float points[]; };
    layout(std430, binding = 1) buffer PointMesh { int point_mesh[]; };
    layout(std430, binding = 2) buffer Xf { float xf[]; };
    layout(std430, binding = 3) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(shadowBody)
    }
    """

  static let shadowMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* points [[buffer(1)]],
                             device const int* point_mesh [[buffer(2)]],
                             device const float* xf [[buffer(3)]],
                             device float* out_verts [[buffer(4)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(shadowBody)
    }
    """

  static let glslPrelude = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    uniform ivec4 u_params;
    #define PARAMS u_params
    #define INT2 ivec2
    #define INT4 ivec4
    #define VEC2 vec2
    #define VEC3 vec3
    #define VEC4 vec4

    """

  static let mslPrelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 params; };
    #define PARAMS u.params
    #define INT2 int2
    #define INT4 int4
    #define VEC2 float2
    #define VEC3 float3
    #define VEC4 float4

    """

  static let faceGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Faces { ivec4 faces[]; };
    layout(std430, binding = 1) buffer Points { float points[]; };
    layout(std430, binding = 2) buffer FaceNormals { vec4 face_normals[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(faceBody)
    }
    """

  static let faceMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int4* faces [[buffer(1)]],
                             device const float* points [[buffer(2)]],
                             device float4* face_normals [[buffer(3)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(faceBody)
    }
    """

  static let pointGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer FaceStart { int face_start[]; };
    layout(std430, binding = 1) buffer FaceList { int face_list[]; };
    layout(std430, binding = 2) buffer FaceNormals { vec4 face_normals[]; };
    layout(std430, binding = 3) buffer PointNormals { vec4 point_normals[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(pointBody)
    }
    """

  static let pointMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int* face_start [[buffer(1)]],
                             device const int* face_list [[buffer(2)]],
                             device const float4* face_normals [[buffer(3)]],
                             device float4* point_normals [[buffer(4)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(pointBody)
    }
    """

  static let emitGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Corners { ivec2 corners[]; };
    layout(std430, binding = 1) buffer Uvs { vec2 uvs[]; };
    layout(std430, binding = 2) buffer Points { float points[]; };
    layout(std430, binding = 3) buffer PointNormals { vec4 point_normals[]; };
    layout(std430, binding = 4) buffer FaceNormals { vec4 face_normals[]; };
    layout(std430, binding = 5) buffer PointMesh { int point_mesh[]; };
    layout(std430, binding = 6) buffer Xf { float xf[]; };
    layout(std430, binding = 7) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(emitBody)
    }
    """

  static let settleBody = """
      if (int(gid) >= PARAMS.x) return;
      int o = int(gid) * 14;
      out_verts[o + 5] = out_verts[o + 0];
      out_verts[o + 6] = out_verts[o + 1];
      out_verts[o + 7] = out_verts[o + 2];
    """

  static let settleGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(settleBody)
    }
    """

  static let settleMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* out_verts [[buffer(1)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(settleBody)
    }
    """

  static let emitMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int2* corners [[buffer(1)]],
                             device const float2* uvs [[buffer(2)]],
                             device const float* points [[buffer(3)]],
                             device const float4* point_normals [[buffer(4)]],
                             device const float4* face_normals [[buffer(5)]],
                             device const int* point_mesh [[buffer(6)]],
                             device const float* xf [[buffer(7)]],
                             device float* out_verts [[buffer(8)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(emitBody)
    }
    """
}
