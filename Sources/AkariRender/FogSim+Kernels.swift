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

extension Akari.FogSim
{
  static let maxDisturbers = 8

  /// Shared by every kernel: the grid (nx, ny, nz, cell size) and where it sits (min corner, z up).
  static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    struct G { float4 grid; float4 origin; };

    inline int3 dims(constant G& g) { return int3(g.grid.xyz); }
    inline int cell(int3 c, int3 n) { return c.x + n.x * (c.y + n.y * c.z); }
    inline bool outside(int3 c, int3 n) { return any(c < 0) || any(c >= n); }

    /// The grid's up is its z, on a y up stage it maps to world y.
    inline float3 toWorld(float3 v, float zUp) { return zUp > 0.5 ? v : float3(v.x, v.z, v.y); }
    inline float3 toGrid(float3 v, float zUp) { return zUp > 0.5 ? v : float3(v.x, v.z, v.y); }

    /// Trilinear at `p` (cell units, centers at +0.5), clamped to the grid.
    inline float4 sample4(device const float4* f, float3 p, int3 n)
    {
      float3 q = clamp(p - 0.5, float3(0.0), float3(n - 1));
      int3 i = min(int3(floor(q)), n - 2);
      i = max(i, int3(0));
      float3 t = q - float3(i);
      int3 j = min(i + 1, n - 1);
      float4 a = mix(f[cell(int3(i.x, i.y, i.z), n)], f[cell(int3(j.x, i.y, i.z), n)], t.x);
      float4 b = mix(f[cell(int3(i.x, j.y, i.z), n)], f[cell(int3(j.x, j.y, i.z), n)], t.x);
      float4 c = mix(f[cell(int3(i.x, i.y, j.z), n)], f[cell(int3(j.x, i.y, j.z), n)], t.x);
      float4 d = mix(f[cell(int3(i.x, j.y, j.z), n)], f[cell(int3(j.x, j.y, j.z), n)], t.x);
      return mix(mix(a, b, t.y), mix(c, d, t.y), t.z);
    }

    inline float sample1(device const float* f, float3 p, int3 n)
    {
      float3 q = clamp(p - 0.5, float3(0.0), float3(n - 1));
      int3 i = max(min(int3(floor(q)), n - 2), int3(0));
      float3 t = q - float3(i);
      int3 j = min(i + 1, n - 1);
      float a = mix(f[cell(int3(i.x, i.y, i.z), n)], f[cell(int3(j.x, i.y, i.z), n)], t.x);
      float b = mix(f[cell(int3(i.x, j.y, i.z), n)], f[cell(int3(j.x, j.y, i.z), n)], t.x);
      float c = mix(f[cell(int3(i.x, i.y, j.z), n)], f[cell(int3(j.x, i.y, j.z), n)], t.x);
      float d = mix(f[cell(int3(i.x, j.y, j.z), n)], f[cell(int3(j.x, j.y, j.z), n)], t.x);
      return mix(mix(a, b, t.y), mix(c, d, t.y), t.z);
    }

    inline float3 velAt(device const float4* v, int3 q, int3 n) { return v[cell(clamp(q, int3(0), n - 1), n)].xyz; }

    /// Below the floor the flow mirrors, so nothing crosses it.
    inline float3 velWall(device const float4* v, int3 q, int3 n)
    {
      if (q.z < 0) { float3 w = v[cell(clamp(int3(q.x, q.y, 0), int3(0), n - 1), n)].xyz; return float3(w.x, w.y, -w.z); }
      return velAt(v, q, n);
    }

    /// Pressure is mirrored at the floor and zero past the open sides.
    inline float pAt(device const float* p, int3 q, int3 n)
    {
      if (q.z < 0) q.z = 0;
      return outside(q, n) ? 0.0 : p[cell(q, n)];
    }

    float simHash(float3 p)
    {
      p = fract(p * 0.3183099 + 0.1);
      p *= 17.0;
      return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    float simNoise(float3 x)
    {
      float3 i = floor(x), f = x - i;
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(mix(simHash(i), simHash(i + float3(1, 0, 0)), f.x),
                     mix(simHash(i + float3(0, 1, 0)), simHash(i + float3(1, 1, 0)), f.x), f.y),
                 mix(mix(simHash(i + float3(0, 0, 1)), simHash(i + float3(1, 0, 1)), f.x),
                     mix(simHash(i + float3(0, 1, 1)), simHash(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    float simFbm(float3 p)
    {
      float sum = 0.0, a = 0.5, norm = 0.0;
      for (int i = 0; i < 4; ++i) {
        sum += simNoise(p) * a; norm += a; a *= 0.5;
        p = float3x3(float3(0.0, 0.8, 0.6), float3(-0.8, 0.36, -0.48), float3(-0.6, -0.48, 0.64)) * p * 2.03;
      }
      return sum / norm;
    }

    /// The deck layer the floor keeps feeding: (floor, falloff, base, -) and the noise (amount, scale, -, -).
    float layerTarget(float height, float3 world, float4 layer, float4 noise, float3 drift)
    {
      float profile = layer.y > 0.0 ? exp(-max(height, 0.0) / layer.y) : 1.0;
      float density = layer.z * profile;
      if (noise.x > 0.0) {
        float n = simFbm((world - drift) / max(noise.y, 1e-3));
        density *= mix(1.0, smoothstep(0.38, 0.66, n) * 1.8, noise.x);
      }
      return density;
    }
    """

  /// Semi-Lagrangian advection of velocity and density, then the forces: wind, damping, the
  /// floor source, dissipation, settling, and the disturbers pushing, lifting and rolling the
  /// fog.
  static let advectMSL = prelude + """
    struct U
    {
      float4 grid; float4 origin;
      float4 step;   // dt, time, disturber count, -
      float4 wind;   // xyz, relax rate
      float4 layer;  // floor, falloff, base, replenish rate
      float4 noise;  // amount, scale, -, -
      float4 sim;    // vorticity, dissipation, settle speed, damping
      float4 d[16];  // per disturber: position + radius, velocity + lift
    };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float4* velIn [[buffer(1)]],
                             device float4* velOut [[buffer(3)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = u.grid.w, dt = u.step.x, zUp = u.origin.w;
      int i = cell(c, n);
      float3 p = float3(c) + 0.5;
      float3 v = velIn[i].xyz;

      float3 back = p - v * dt / h;
      float3 vel = sample4(velIn, back, n).xyz;
      float3 local = p * h;

      float3 wind = toGrid(u.wind.xyz, zUp);
      vel.xy += (wind.xy - vel.xy) * (1.0 - exp(-dt * u.wind.w));
      vel *= exp(-dt * u.sim.w);

      float3 up = float3(0.0, 0.0, 1.0);
      int count = int(u.step.z);
      for (int k = 0; k < count; ++k) {
        float4 pr = u.d[k * 2];
        float4 vl = u.d[k * 2 + 1];
        float3 dp = local - toGrid(pr.xyz - u.origin.xyz, zUp);
        float3 dv = toGrid(vl.xyz, zUp);
        float r = max(pr.w, h);
        float dist = length(dp);
        float speed = length(dv);
        float body = 1.0 - smoothstep(0.6 * r, 1.2 * r, dist);
        vel = mix(vel, dv, body * 0.7);
        if (speed > 0.05) {
          float3 dir = dv / speed;
          float behind = saturate(0.5 - dot(dp, dir) / (2.5 * r));
          float wake = exp(-dot(dp, dp) / (3.0 * r * r)) * behind;
          float3 axis = cross(dir, up);
          axis = length(axis) > 1e-3 ? normalize(axis) : float3(1.0, 0.0, 0.0);
          vel += (up * vl.w * speed + cross(axis, dp / r) * speed * 0.9) * wake * dt * 6.0;
        }
      }

      float speed = length(vel);
      if (speed > 6.0) vel *= 6.0 / speed;
      if (c.z == 0) vel.z = max(vel.z, 0.0);
      velOut[i] = float4(all(isfinite(vel)) ? vel : float3(0.0), 0.0);
    }
    """

  /// Density, on its own finer grid (`grid`), the velocity grid `vgrid`
  /// (the first MacCormack pass), a plain semi Lagrangian step back
  /// along the flow, settling included.
  static let densityPredictMSL = prelude + """
    struct U { float4 grid; float4 origin; float4 vgrid; float4 step; float4 sim; };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float4* vel [[buffer(1)]],
                             device const float* densIn [[buffer(2)]],
                             device float* hat [[buffer(3)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = u.grid.w, hv = u.vgrid.w, dt = u.step.x;
      float3 local = (float3(c) + 0.5) * h;
      float3 v = sample4(vel, local / hv, int3(u.vgrid.xyz)).xyz + float3(0.0, 0.0, -u.sim.z);
      hat[cell(c, n)] = sample1(densIn, (local - v * dt) / h, n);
    }
    """

  /// The MacCormack correction, clamped to what the step back saw so it can't
  /// overshoot, then the floor source and the slow thinning of lifted fog.
  static let densityCorrectMSL = prelude + """
    struct U { float4 grid; float4 origin; float4 vgrid; float4 step; float4 sim; float4 wind; float4 layer; float4 noise; };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float4* vel [[buffer(1)]],
                             device const float* densIn [[buffer(2)]],
                             device const float* hat [[buffer(3)]],
                             device float* densOut [[buffer(4)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = u.grid.w, hv = u.vgrid.w, dt = u.step.x;
      int i = cell(c, n);
      float3 local = (float3(c) + 0.5) * h;
      float3 v = sample4(vel, local / hv, int3(u.vgrid.xyz)).xyz + float3(0.0, 0.0, -u.sim.z);
      float ahead = sample1(hat, (local + v * dt) / h, n);
      float dens = hat[i] + 0.5 * (densIn[i] - ahead);

      float3 q = clamp((local - v * dt) / h - 0.5, float3(0.0), float3(n - 1));
      int3 b = max(min(int3(floor(q)), n - 2), int3(0));
      float lo = 1e20, hi = -1e20;
      for (int k = 0; k < 8; ++k) {
        float f = densIn[cell(min(b + int3(k & 1, (k >> 1) & 1, k >> 2), n - 1), n)];
        lo = min(lo, f); hi = max(hi, f);
      }
      dens = clamp(dens, lo, hi);

      float3 world = toWorld(local, u.origin.w) + u.origin.xyz;
      float target = layerTarget(local.z, world, u.layer, u.noise, u.wind.xyz * u.step.y);
      float nearFloor = u.layer.y > 0.0 ? exp(-local.z / (2.0 * u.layer.y)) : 1.0;
      dens += (target - dens) * (1.0 - exp(-dt * u.layer.w)) * nearFloor;
      dens *= exp(-dt * u.sim.y * (1.0 - nearFloor));
      densOut[i] = isfinite(dens) ? clamp(dens, 0.0, 50.0) : 0.0;
    }
    """

  /// The vorticity of the velocity, central differences.
  static let curlMSL = prelude + """
    kernel void compute_main(constant G& g [[buffer(0)]],
                             device const float4* vel [[buffer(1)]],
                             device float4* curl [[buffer(2)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = dims(g);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = g.grid.w;
      float3 dx = (velAt(vel, c + int3(1, 0, 0), n) - velAt(vel, c - int3(1, 0, 0), n)) / (2.0 * h);
      float3 dy = (velAt(vel, c + int3(0, 1, 0), n) - velAt(vel, c - int3(0, 1, 0), n)) / (2.0 * h);
      float3 dz = (velAt(vel, c + int3(0, 0, 1), n) - velAt(vel, c - int3(0, 0, 1), n)) / (2.0 * h);
      float3 w = float3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x);
      curl[cell(c, n)] = float4(w, length(w));
    }
    """

  /// Vorticity confinement, the curls that turn a push into tendrils.
  static let confineMSL = prelude + """
    struct U { float4 grid; float4 origin; float4 step; };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float4* curl [[buffer(1)]],
                             device float4* vel [[buffer(2)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = u.grid.w;
      float3 grad = float3(curl[cell(clamp(c + int3(1, 0, 0), int3(0), n - 1), n)].w - curl[cell(clamp(c - int3(1, 0, 0), int3(0), n - 1), n)].w,
                           curl[cell(clamp(c + int3(0, 1, 0), int3(0), n - 1), n)].w - curl[cell(clamp(c - int3(0, 1, 0), int3(0), n - 1), n)].w,
                           curl[cell(clamp(c + int3(0, 0, 1), int3(0), n - 1), n)].w - curl[cell(clamp(c - int3(0, 0, 1), int3(0), n - 1), n)].w);
      float l = length(grad);
      if (l < 1e-6) return;
      float3 N = grad / l;
      int i = cell(c, n);
      float3 f = u.step.y * h * cross(N, curl[i].xyz);
      vel[i].xyz += f * u.step.x;
    }
    """

  /// The divergence, the floor a wall the fog can't pass, the other sides open.
  static let divergenceMSL = prelude + """
    kernel void compute_main(constant G& g [[buffer(0)]],
                             device const float4* vel [[buffer(1)]],
                             device float* div [[buffer(2)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = dims(g);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = g.grid.w;
      div[cell(c, n)] = (velWall(vel, c + int3(1, 0, 0), n).x - velWall(vel, c - int3(1, 0, 0), n).x
                       + velWall(vel, c + int3(0, 1, 0), n).y - velWall(vel, c - int3(0, 1, 0), n).y
                       + velWall(vel, c + int3(0, 0, 1), n).z - velWall(vel, c - int3(0, 0, 1), n).z) / (2.0 * h);
    }
    """

  /// One Jacobi iteration of the pressure Poisson equation.
  static let jacobiMSL = prelude + """
    kernel void compute_main(constant G& g [[buffer(0)]],
                             device const float* pIn [[buffer(1)]],
                             device const float* div [[buffer(2)]],
                             device float* pOut [[buffer(3)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = dims(g);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = g.grid.w;
      float sum = pAt(pIn, c + int3(1, 0, 0), n) + pAt(pIn, c - int3(1, 0, 0), n)
                + pAt(pIn, c + int3(0, 1, 0), n) + pAt(pIn, c - int3(0, 1, 0), n)
                + pAt(pIn, c + int3(0, 0, 1), n) + pAt(pIn, c - int3(0, 0, 1), n);
      float p = (sum - h * h * div[cell(c, n)]) / 6.0;
      pOut[cell(c, n)] = isfinite(p) ? p : 0.0;
    }
    """

  /// Subtracts the pressure gradient, leaving the flow divergence free.
  static let projectMSL = prelude + """
    kernel void compute_main(constant G& g [[buffer(0)]],
                             device const float* p [[buffer(1)]],
                             device float4* vel [[buffer(2)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = dims(g);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float h = g.grid.w;
      float3 grad = float3(pAt(p, c + int3(1, 0, 0), n) - pAt(p, c - int3(1, 0, 0), n),
                           pAt(p, c + int3(0, 1, 0), n) - pAt(p, c - int3(0, 1, 0), n),
                           pAt(p, c + int3(0, 0, 1), n) - pAt(p, c - int3(0, 0, 1), n)) / (2.0 * h);
      int i = cell(c, n);
      float3 v = vel[i].xyz - grad;
      if (c.z == 0) v.z = max(v.z, 0.0);
      vel[i] = float4(all(isfinite(v)) ? v : float3(0.0), 0.0);
    }
    """

  /// The rest state, the deck layer, still air moving with the wind.
  static let resetMSL = prelude + """
    struct U { float4 grid; float4 origin; float4 step; float4 wind; float4 layer; float4 noise; };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float4* vel [[buffer(1)]],
                             device float* pressure [[buffer(3)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      int i = cell(c, n);
      vel[i] = float4(toGrid(u.wind.xyz, u.origin.w) * float3(1.0, 1.0, 0.0), 0.0);
      pressure[i] = 0.0;
    }
    """

  static let resetDensityMSL = prelude + """
    struct U { float4 grid; float4 origin; float4 step; float4 wind; float4 layer; float4 noise; };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* dens [[buffer(2)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      float3 local = (float3(c) + 0.5) * u.grid.w;
      float3 world = toWorld(local, u.origin.w) + u.origin.xyz;
      dens[cell(c, n)] = layerTarget(local.z, world, u.layer, u.noise, u.wind.xyz * u.step.y);
    }
    """

  /// How much of the nearby lights illumination reaches each cell through the simulated
  /// fog, weighted by what each brings there, which gives self shadowing.
  static let visibilityMSL = prelude + """
    struct U { float4 grid; float4 origin; float4 dgrid; float4 l[8]; float4 count; };

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* dens [[buffer(1)]],
                             texture3d<float, access::write> out [[texture(0)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = int3(u.grid.xyz);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      int3 dn = int3(u.dgrid.xyz);
      float hd = u.dgrid.w;
      float3 local = (float3(c) + 0.5) * u.grid.w;
      float zUp = u.origin.w;
      float sum = 0.0, weight = 0.0;
      for (int k = 0; k < int(u.count.x); ++k) {
        float4 pi = u.l[k * 2];
        float4 cr = u.l[k * 2 + 1];
        float3 lp = toGrid(pi.xyz - u.origin.xyz, zUp);
        float3 to = lp - local;
        float dist = length(to);
        float w = pi.w * cr.w * cr.w / max(dist * dist, max(cr.w * cr.w, 1e-4));
        if (w <= 1e-6) continue;
        float reach = min(dist - cr.w, 4.0);
        float tau = 0.0;
        if (reach > 0.0) {
          float3 dir = to / max(dist, 1e-6);
          float stepLength = reach / 16.0;
          for (int s = 0; s < 16; ++s) {
            float3 q = local + dir * (stepLength * (float(s) + 0.5));
            tau += sample1(dens, q / hd, dn) * stepLength;
          }
        }
        sum += w * exp(-tau);
        weight += w;
      }
      float vis = weight > 1e-6 ? sum / weight : 1.0;
      out.write(float4(isfinite(vis) ? saturate(vis) : 1.0), uint3(c));
    }
    """

  /// The velocity into a 3D texture the march carries its detail noise with.
  static let exportVelocityMSL = prelude + """
    kernel void compute_main(constant G& g [[buffer(0)]],
                             device const float4* vel [[buffer(1)]],
                             texture3d<float, access::write> out [[texture(0)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = dims(g);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      out.write(float4(toWorld(vel[cell(c, n)].xyz, g.origin.w), 0.0), uint3(c));
    }
    """

  /// The density into the 3D texture the froxel fog samples.
  static let exportMSL = prelude + """
    kernel void compute_main(constant G& g [[buffer(0)]],
                             device const float* dens [[buffer(1)]],
                             texture3d<float, access::write> out [[texture(0)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int3 n = dims(g);
      int3 c = int3(gid);
      if (outside(c, n)) return;
      out.write(float4(dens[cell(c, n)]), uint3(c));
    }
    """
}
