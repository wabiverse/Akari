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
  /// drawn by the `geometry dynamic` pass and its back layer counterpart
  struct MeshShader: ShaderProgram
  {
    var layer: MeshLayer = .front

    var name: String { layer == .back ? "mesh-back" : "mesh" }

    var uniforms: [Declaration]
    {
      Samplers.materialAtlas
      Samplers.colorAtlas
      Samplers.normalAtlas
      Samplers.emissiveAtlas
      Samplers.materialConstants
      Samplers.primStyle
      Samplers.ptexTable
      Samplers.ptexAtlas
      Samplers.ptexHash
      Uniforms.ptexParams
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.frameIndex
    }

    var varyings: [Declaration]
    {
      Varying<SIMD3<Float>>("posEye")
      Varying<SIMD3<Float>>("normalEye")
      Varying<SIMD2<Float>>("uv")
      Varying<Float>("primId")
      Varying<SIMD4<Float>>("currClip")
      Varying<SIMD4<Float>>("prevClip")
      Varying<SIMD3<Float>>("posWorld")
      Varying<SIMD3<Float>>("bary")
      Varying<Float>("assembled")
      Varying<SIMD4<Float>>("vcolor")
      Varying<Float>("tri")
      Varying<Float>("hidden")
      Varying<Int32>("ptexBase")
    }

    var stages: [Stage]
    {
      Stage(.vertex, glsl: vertexGLSL, msl: vertexMSL)
      {
        Attribute<SIMD4<Float>>("a_position", .position)
        Attribute<SIMD4<Float>>("a_color", .color)
        Attribute<SIMD3<Float>>("a_normal", .normal)
        Attribute<SIMD2<Float>>("a_uv", .texcoord)
        Attribute<Float>("a_pad", .pad)
      }
      Stage(.fragment, glsl: layer == .back ? ShaderLibrary.metalOnly : fragmentGLSL, msl: fragmentMSL)
    }

    let vertexGLSL = #"""
      void main()
      {
        vec4 ep = u_modelview * vec4(a_position.xyz, 1.0);
        var.posEye = ep.xyz;
        var.normalEye = normalize(u_normalMatrix * a_normal);
        var.uv = a_uv;
        var.primId = a_color.r;
        var.currClip = u_currViewProj * vec4(a_position.xyz, 1.0);
        var.prevClip = u_prevViewProj * vec4(a_color.yzw, 1.0);
        var.posWorld = a_position.xyz;
        var.tri = a_pad;

        float hidden = floor(a_position.w / 8.0);
        float cornerCode = a_position.w - hidden * 8.0;
        float corner = floor(cornerCode * 0.5);
        var.assembled = clamp(cornerCode - corner * 2.0, 0.0, 1.0);
        var.hidden = hidden;
        var.bary = corner < 0.5 ? vec3(1.0, 0.0, 0.0) : corner < 1.5 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);

        float packed = a_uv.x < 0.0 ? a_uv.y - 1.0 : -1.0;
        var.vcolor = packed >= 0.0 ? vec4(floor(packed / 65536.0), mod(floor(packed / 256.0), 256.0), mod(packed, 256.0), 255.0) / 255.0
                                   : vec4(0.0);
        var.ptexBase = 0;

        gl_Position = u_modelviewProjection * vec4(a_position.xyz, 1.0);
      }
      """#

    let vertexMSL = #"""
      //@main
      {
        float4 objPos = float4(a_position.xyz, 1.0);
        float4 worldPos = u_instance * objPos;
        float4 ep = u_modelview * objPos;
        var.posEye = ep.xyz;
        var.normalEye = normalize(u_normalMatrix * a_normal);
        var.uv = a_uv;
        var.primId = a_color.r;
        var.currClip = u_currViewProj * worldPos;
        var.prevClip = u_prevViewProj * (u_instance * float4(a_color.yzw, 1.0));
        var.posWorld = worldPos.xyz;
        var.tri = a_pad;

        float hidden = floor(a_position.w / 8.0);
        float cornerCode = a_position.w - hidden * 8.0;
        float corner = floor(cornerCode * 0.5);
        var.assembled = saturate(cornerCode - corner * 2.0);
        var.hidden = hidden;
        var.bary = corner < 0.5 ? float3(1.0, 0.0, 0.0) : corner < 1.5 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0);

        float packed = a_uv.x < 0.0 ? a_uv.y - 1.0 : -1.0;
        var.vcolor = packed >= 0.0 ? float4(floor(packed / 65536.0), fmod(floor(packed / 256.0), 256.0), fmod(packed, 256.0), 255.0) / 255.0
                                   : float4(0.0);
        var.ptexBase = int(gl_BaseInstance);

        gl_Position = u_modelviewProjection * objPos;
      }
      """#

    let fragmentGLSL = #"""
      void main()
      {
        vec3 dp1 = dFdx(var.posEye);
        vec3 dp2 = dFdy(var.posEye);
        vec2 duv1 = dFdx(var.uv);
        vec2 duv2 = dFdy(var.uv);

        vec4 mat = texture(u_material_atlas, var.uv);
        int row = int(-var.uv.x + 0.5) - 1;

        // a textured material keeps its facing reflectance in the normal map's alpha, a constant one in its row
        vec3 specular = vec3(texture(u_normal_atlas, var.uv).a);
        vec4 c0 = vec4(0.0), c2 = vec4(0.0);
        if (row >= 0)
        {
          // 128 material rows share a scanline, see `MaterialAtlas.constantsRowsPerLine`
          int line = row >> 7;
          int base = (row & 127) * 4;
          c0 = texelFetch(u_materialConstants, ivec2(base, line), 0);
          vec4 c1 = texelFetch(u_materialConstants, ivec2(base + 1, line), 0);
          c2 = texelFetch(u_materialConstants, ivec2(base + 2, line), 0);
          vec4 c3 = texelFetch(u_materialConstants, ivec2(base + 3, line), 0);
          mat = vec4(c1.r, c1.g, c0.a, c1.b);
          specular = c3.rgb;
        }

        // a threshold cuts out, without one opacity dithers and the temporal resolve blends it
        float dither = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64)
                                                    + var.primId * vec2(17.31, 11.87), vec2(0.06711056, 0.00583715))));
        if (mat.a > 0.0 ? mat.b < mat.a : mat.b < 0.98 && mat.b <= dither) discard;

        vec3 albedo = texture(u_color_atlas, var.uv).rgb;
        if (row >= 0) albedo = c0.rgb;

        vec3 N = normalize(var.normalEye);

        // both sides render and a back face shades with its normal turned toward the eye
        vec3 Ng = cross(dp1, dp2);
        if (dot(Ng, var.posEye) > 0.0) Ng = -Ng;
        if (dot(N, Ng) < 0.0) N = -N;

        vec3 tn = texture(u_normal_atlas, var.uv).rgb * 2.0 - 1.0;
        if (row >= 0) tn = vec3(0.0, 0.0, 1.0);
        float handedness = sign(duv1.x * duv2.y - duv2.x * duv1.y);
        vec3 T = (dp1 * duv2.y - dp2 * duv1.y) * handedness;
        vec3 B = (dp2 * duv1.x - dp1 * duv2.x) * handedness;
        T -= N * dot(N, T);
        B -= N * dot(N, B);
        // each axis on its own, the atlas stretches a non square texture's u and v by different amounts
        float tt = dot(T, T), bb = dot(B, B);
        vec3 normalEye = min(tt, bb) > 1e-30 ? normalize(T * (tn.x * inversesqrt(tt)) + B * (tn.y * inversesqrt(bb)) + N * tn.z) : N;

        vec4 emissive = texture(u_emissive_atlas, var.uv);
        vec3 emission = row >= 0 ? c2.rgb : emissive.rgb / max(emissive.a, 1.0 / 255.0);

        o_diffuse_texture = vec4(albedo, emission.b);
        o_position_texture = vec4(var.posEye, var.primId);
        o_normal_texture = vec4(normalEye, 1.0);
        o_material_texture = vec4(mat.r, mat.g, emission.r, emission.g);
        o_specular_texture = vec4(specular, 1.0);

        vec2 motion = (var.prevClip.xy / var.prevClip.w - var.currClip.xy / var.currClip.w) * 0.5;
        o_velocity_texture = vec4(motion, 0.0, 0.0);
      }
      """#

    var fragmentMSL: String
    {
      #"""
      \#(ShaderLibrary.styleMSL)

      /// atlas slot of the streamed tile keyed by a and b, all ones when it is not resident
      inline uint ptexSlot(texture2d_array<uint> hash, uint a, uint b, int4 params)
      {
        uint h = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u) * 0x85EBCA77u;
        h ^= h >> 15;
        h *= 0x2C1B3C6Du;
        h ^= h >> 12;
        for (int i = 0; i <= params.y; ++i)
        {
          uint e = (h + uint(i)) & uint(params.x);
          uint2 at = uint2((e & 1023u) * 4u, e >> 10);
          uint key = hash.read(at, 0).x;
          if (key == 0u) break;
          if (key == a && hash.read(at + uint2(1, 0), 0).x == b) return hash.read(at + uint2(2, 0), 0).x;
        }
        return 0xFFFFFFFFu;
      }

      inline float3 ptexTexel(texture2d_array<uint> atlas, uint2 at, uint layer)
      {
        uint t = atlas.read(at, layer).x;
        float3 c = float3(float(t & 255u), float((t >> 8) & 255u), float((t >> 16) & 255u)) / 255.0;
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
      }

      /// the corners of a ptex quad in order around the unit square
      inline float2 ptexCorner(uint k)
      {
        return float2(k == 1u || k == 2u ? 1.0 : 0.0, k >= 2u ? 1.0 : 0.0);
      }

      //@main
      {
        float3 dp1 = dfdx(var.posEye);
        float3 dp2 = dfdy(var.posEye);
        float2 duv1 = dfdx(var.uv);
        float2 duv2 = dfdy(var.uv);

        // each triangle's ptex face, its place on that face, and the derivatives used to pick a level
        uint ptexIndex = uint(var.ptexBase) + gl_PrimitiveID;
        uint ptexEntry = var.ptexBase != 0 && u_ptexParams.w != 0
          ? u_ptexTable.read(uint2(ptexIndex & 8191u, (ptexIndex >> 13) & 8191u), ptexIndex >> 26).x : 0xFFFFFFFFu;
        uint ptexCode = (ptexEntry >> 18) & 63u;
        float2 ptexUv = saturate(gl_BaryCoord.x * ptexCorner(ptexCode & 3u) + gl_BaryCoord.y * ptexCorner((ptexCode >> 2) & 3u)
                                 + gl_BaryCoord.z * ptexCorner((ptexCode >> 4) & 3u));
        float2 ptexDx = dfdx(ptexUv);
        float2 ptexDy = dfdy(ptexUv);

        \#(layer.keeps("o_ptexA_texture = int4(0);\n        o_ptexB_texture = int4(0);"))

        float4 mat = texture(u_material_atlas, var.uv);

        // an untextured material keeps its constants row in the uv and reads that instead of the atlas
        int row = int(-var.uv.x + 0.5) - 1;

        // a textured material keeps its facing reflectance in the normal map's alpha, a constant one in its row
        float3 specular = float3(texture(u_normal_atlas, var.uv).a);
        float4 c0 = float4(0.0), c2 = float4(0.0);
        if (row >= 0)
        {
          // 128 material rows share a scanline, see `MaterialAtlas.constantsRowsPerLine`
          uint line = uint(row) >> 7u;
          uint base = uint(row & 127) * 4u;
          c0 = u_materialConstants.read(uint2(base, line));
          float4 c1 = u_materialConstants.read(uint2(base + 1u, line));
          c2 = u_materialConstants.read(uint2(base + 2u, line));
          float4 c3 = u_materialConstants.read(uint2(base + 3u, line));
          mat = float4(c1.r, c1.g, c0.a, c1.b);
          specular = c3.rgb;
        }

        // a threshold cuts out, without one opacity dithers and the temporal resolve blends it
        float dither = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64)
                                                    + var.primId * float2(17.31, 11.87), float2(0.06711056, 0.00583715))));
        float see = styleTexel(u_primStyle, var.primId, 4).y;
        if (mat.a > 0.0 ? mat.b < mat.a : mat.b < 0.98 && (see > 0.5 || mat.b <= dither)) discard_fragment();

        float3 albedo = texture(u_color_atlas, var.uv).rgb;
        if (row >= 0) albedo = c0.rgb;

        float3 N = normalize(var.normalEye);
        \#(layer.facingMSL)

        float3 tn = texture(u_normal_atlas, var.uv).rgb * 2.0 - 1.0;
        if (row >= 0) tn = float3(0.0, 0.0, 1.0);
        float handedness = sign(duv1.x * duv2.y - duv2.x * duv1.y);
        float3 T = (dp1 * duv2.y - dp2 * duv1.y) * handedness;
        float3 B = (dp2 * duv1.x - dp1 * duv2.x) * handedness;
        T -= N * dot(N, T);
        B -= N * dot(N, B);
        // each axis on its own, the atlas stretches a non square texture's u and v by different amounts
        float tt = dot(T, T), bb = dot(B, B);
        float3 normalEye = min(tt, bb) > 1e-30 ? normalize(T * (tn.x * rsqrt(tt)) + B * (tn.y * rsqrt(bb)) + N * tn.z) : N;

        float4 emissive = texture(u_emissive_atlas, var.uv);
        float3 emission = row >= 0 ? c2.rgb : emissive.rgb / max(emissive.a, 1.0 / 255.0);

        float4 style0 = styleTexel(u_primStyle, var.primId, 0);
        float4 style1 = styleTexel(u_primStyle, var.primId, 1);
        float shadingModel = styleShadingModel(style0, style1, var.posWorld);

        int map = row >= 0 ? int(c2.w + 0.5) : 0;
        if (ptexEntry != 0xFFFFFFFFu && map > 0) {
          int ulog = int((ptexEntry >> 24) & 15u), vlog = int(ptexEntry >> 28);
          int coarsest = max(ulog, vlog);
          float2 full = float2(float(1 << ulog), float(1 << vlog));
          float lod = 0.5 * log2(max(max(length_squared(ptexDx * full), length_squared(ptexDy * full)), 1e-12));

          // dither between the levels either side of the footprint and let the temporal resolve blend them
          int level = min(max(int(floor(lod + dither)), 0), coarsest);

          uint keyA = uint(map) << 18 | (ptexEntry & 0x3FFFFu);
          uint wanted = 0u, used = 0u, single = 0u;

          // try the levels around the wanted one, then the face's single texel
          for (int step = 0; step < 5; ++step) {
            int l = step < 4 ? level + step : coarsest;
            if (l > coarsest || (step == 4 && level + 3 >= coarsest)) break;
            int lu = max(ulog - l, 0), lv = max(vlog - l, 0);
            int tw = min(1 << lu, 64), th = min(1 << lv, 64);
            float2 p = ptexUv * float2(float(1 << lu), float(1 << lv));
            int tx = clamp(int(p.x) / tw, 0, (1 << lu) / tw - 1), ty = clamp(int(p.y) / th, 0, (1 << lv) / th - 1);
            uint keyB = uint(l) << 16 | uint(ty * ((1 << lu) / tw) + tx);
            if (step == 0) wanted = keyB;
            if (l == coarsest) single = keyB;

            uint slot = ptexSlot(u_ptexHash, keyA, keyB, u_ptexParams);
            if (slot == 0xFFFFFFFFu) continue;

            // bilinear filter across the tile's one texel border, which holds its neighbors' texels
            float2 local = p - float2(float(tx * tw), float(ty * th)) - 0.5;
            float2 i0 = floor(local), f = local - i0;
            uint layer = slot >> 28;
            uint2 at = uint2(slot & 16383u, (slot >> 14) & 16383u) + uint2(int2(i0) + 1);
            albedo = mix(mix(ptexTexel(u_ptexAtlas, at, layer), ptexTexel(u_ptexAtlas, at + uint2(1, 0), layer), f.x),
                         mix(ptexTexel(u_ptexAtlas, at + uint2(0, 1), layer), ptexTexel(u_ptexAtlas, at + uint2(1, 1), layer), f.x),
                         f.y);
            used = keyB | 0x80000000u;
            break;
          }

          // half the pixels request the level they want and half keep the cached one, the single texel when nothing is resident
          bool other = ((int(gl_FragCoord.x) + int(gl_FragCoord.y) + frameIndex) & 1) != 0;
          \#(layer.keeps("o_ptexA_texture = int4(int(keyA));\n          o_ptexB_texture = int4(as_type<int>(!other ? wanted : used != 0u ? used : single));"))
        }

        if (var.vcolor.w > 0.5) {
          albedo *= var.vcolor.rgb;
          emission *= var.vcolor.rgb;
        }

        albedo = mix(float3(dot(albedo, float3(0.2126, 0.7152, 0.0722))), albedo, saturate(style0.y));
        float collapsed = 1.0 - var.assembled;
        if (shadingModel < 1.0) {
          float3 width = max(fwidth(var.bary), float3(1e-6));
          float3 e3 = var.bary / width;
          int hidden = int(var.hidden + 0.5);
          e3 += float3(float(hidden & 1), float((hidden >> 1) & 1), float((hidden >> 2) & 1)) * 1e6;

          float edge = min(e3.x, min(e3.y, e3.z));
          float wire = 1.0 - smoothstep(0.5, 1.2, edge) + exp(-edge * 0.9) * 0.2;
          if (styleTexel(u_primStyle, var.primId, 4).x > 0.0) {
            wire += 0.35 * pow(1.0 - saturate(abs(dot(normalize(var.normalEye), normalize(var.posEye)))), 8.0);
          }
          if (wire < 0.02 && dither >= max(shadingModel, collapsed)) discard_fragment();

          float4 style2 = styleTexel(u_primStyle, var.primId, 2);
          emission = emission * shadingModel + style2.rgb * style2.w * wire * (1.0 - shadingModel);
          albedo *= shadingModel;
        }

        if (collapsed > 0.0) {
          albedo = mix(albedo, var.bary, collapsed);
          emission = mix(emission, var.bary * 2.0, collapsed);
        }

        if (shadingModel < 2.0) normalEye = normalize(mix(normalize(Ng), normalEye, saturate(shadingModel - 1.0)));

        \#(layer.outputsMSL(currentClip: "var.currClip"))
      }
      """#
    }
  }
}
