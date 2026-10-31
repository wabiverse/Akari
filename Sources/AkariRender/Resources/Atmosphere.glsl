float clamp01(float x) { return clamp(x, 0.0, 1.0); }
vec2 clamp01(vec2 x) { return clamp(x, 0.0, 1.0); }
vec3 clamp01(vec3 x) { return clamp(x, 0.0, 1.0); }

const float ATMOS_PI = 3.14159265358979;

struct Atmosphere
{
  float bottom;
  float top;
  vec3 rayleigh;
  float rayleighHeight;
  vec3 mie;
  float mieHeight;
  vec3 mieAbsorption;
  float g;
  vec3 ozone;
  float ozoneCenter;
  float ozoneWidth;
  vec3 albedo;
};

Atmosphere makeAtmosphere(vec4 shape, vec4 rayleigh, vec4 mie, vec4 mieExtra, vec4 ozone, vec4 ground)
{
  Atmosphere a;
  a.bottom = shape.y;
  a.top = shape.z;
  a.rayleigh = rayleigh.rgb;
  a.rayleighHeight = rayleigh.w;
  a.mie = mie.rgb;
  a.mieHeight = mie.w;
  a.mieAbsorption = mieExtra.rgb;
  a.g = mieExtra.w;
  a.ozone = ozone.rgb;
  a.ozoneCenter = ozone.w;
  a.ozoneWidth = ground.w;
  a.albedo = ground.rgb;
  return a;
}

struct AtmosphereMedium
{
  vec3 rayleigh;
  vec3 mie;
  vec3 scattering;
  vec3 extinction;
};

AtmosphereMedium atmosphereMedium(Atmosphere a, float h)
{
  AtmosphereMedium m;
  float dr = exp(-max(h, 0.0) / a.rayleighHeight);
  float dm = exp(-max(h, 0.0) / a.mieHeight);
  float dozone = max(0.0, 1.0 - abs(h - a.ozoneCenter) / (0.5 * a.ozoneWidth));
  m.rayleigh = a.rayleigh * dr;
  m.mie = a.mie * dm;
  m.scattering = m.rayleigh + m.mie;
  m.extinction = m.scattering + a.mieAbsorption * dm + a.ozone * dozone;
  return m;
}

float atmosphereRayleighPhase(float c)
{
  return 3.0 / (16.0 * ATMOS_PI) * (1.0 + c * c);
}

float atmosphereMiePhase(float g, float c)
{
  float k = 3.0 / (8.0 * ATMOS_PI) * (1.0 - g * g) / (2.0 + g * g);
  return k * (1.0 + c * c) / pow(max(1.0 + g * g - 2.0 * g * c, 1e-4), 1.5);
}

float atmosphereGroundDisc(Atmosphere a, float r, float mu)
{
  return r * r * mu * mu - (r - a.bottom) * (r + a.bottom);
}

bool atmosphereHitsGround(Atmosphere a, float r, float mu)
{
  return mu < 0.0 && atmosphereGroundDisc(a, r, mu) >= 0.0;
}

float atmosphereDistanceToGround(Atmosphere a, float r, float mu)
{
  return max(-r * mu - sqrt(max(atmosphereGroundDisc(a, r, mu), 0.0)), 0.0);
}

float atmosphereDistanceToTop(Atmosphere a, float r, float mu)
{
  return max(-r * mu + sqrt(max(r * r * mu * mu + (a.top - r) * (a.top + r), 0.0)), 0.0);
}

vec2 atmosphereTransmittanceUv(Atmosphere a, float r, float mu)
{
  float H = sqrt(max((a.top - a.bottom) * (a.top + a.bottom), 0.0));
  float rho = sqrt(max((r - a.bottom) * (r + a.bottom), 0.0));
  float d = atmosphereDistanceToTop(a, r, mu);
  float dMin = a.top - r;
  float dMax = rho + H;
  return vec2((d - dMin) / max(dMax - dMin, 1e-6), rho / H);
}

vec2 atmosphereTransmittanceParams(Atmosphere a, vec2 uv)
{
  float H = sqrt(max((a.top - a.bottom) * (a.top + a.bottom), 0.0));
  float rho = H * uv.y;
  float r = sqrt(rho * rho + a.bottom * a.bottom);
  float dMin = a.top - r;
  float dMax = rho + H;
  float d = dMin + uv.x * (dMax - dMin);
  float mu = d <= 0.0 ? 1.0 : (H * H - rho * rho - d * d) / (2.0 * r * d);
  return vec2(r, clamp(mu, -1.0, 1.0));
}

vec3 atmosphereOpticalDepth(Atmosphere a, float r, float mu)
{
  float d = atmosphereDistanceToTop(a, r, mu);
  float dt = d / 40.0;
  vec3 depth = vec3(0.0);
  for (int i = 0; i < 40; ++i) {
    float t = (float(i) + 0.5) * dt;
    float rq = sqrt(t * t + 2.0 * r * mu * t + r * r);
    depth += atmosphereMedium(a, rq - a.bottom).extinction * dt;
  }
  return depth;
}

vec3 atmosphereTransmittance(Atmosphere a, float r, float mu, sampler2D lut)
{
  vec2 uv = atmosphereTransmittanceUv(a, min(r, a.top), mu);
  vec2 texel = 0.5 / vec2(textureSize(lut, 0).x, textureSize(lut, 0).y);
  return textureLod(lut, clamp(uv, texel, 1.0 - texel), 0.0).rgb;
}

vec3 atmosphereSunTransmittance(Atmosphere a, float r, float mu, sampler2D lut)
{
  if (atmosphereHitsGround(a, r, mu)) return vec3(0.0);
  return atmosphereTransmittance(a, r, mu, lut);
}

vec2 atmosphereMultiScatterUv(Atmosphere a, float r, float mu, float size)
{
  vec2 uv = vec2(mu * 0.5 + 0.5, clamp01((r - a.bottom) / (a.top - a.bottom)));
  return clamp(uv, 0.5 / size, 1.0 - 0.5 / size);
}

vec3 atmosphereMultiScatter(Atmosphere a, float r, float mu, sampler2D lut)
{
  return textureLod(lut, atmosphereMultiScatterUv(a, r, mu, float(textureSize(lut, 0).x)), 0.0).rgb;
}

struct AtmosphereScatter
{
  vec3 L;
  vec3 T;
  vec3 multiScatterAs1;
};

/// Single scattering along `d` from `p` (km from the planet center), for a unit sun
/// toward `sun`, up to `tMax` or the ground. A ray starting above the atmosphere skips
/// to where it enters. `uniformPhase` and `ground` are the multiple scattering LUT's.
AtmosphereScatter atmosphereIntegrate(Atmosphere a, vec3 p, vec3 d, vec3 sun, float tMax, int samples,
                                      bool uniformPhase, bool ground, bool multiScatter,
                                      sampler2D transmittanceLut,
                                      sampler2D multiScatterLut)
{
  AtmosphereScatter result;
  result.L = vec3(0.0);
  result.T = vec3(1.0);
  result.multiScatterAs1 = vec3(0.0);

  float r = length(p);
  float mu = dot(p, d) / max(r, 1e-6);
  bool outside = r > a.top;
  if (outside) {
    float disc = r * r * mu * mu + (a.top - r) * (a.top + r);
    if (disc < 0.0 || mu >= 0.0) return result;
    float enter = -r * mu - sqrt(disc);
    p += d * enter;
    tMax -= enter;
    r = length(p);
    mu = dot(p, d) / r;
    if (tMax <= 0.0) return result;
  }
  bool hitsGround = atmosphereHitsGround(a, r, mu);
  float tEnd = min(hitsGround ? atmosphereDistanceToGround(a, r, mu) : atmosphereDistanceToTop(a, r, mu), tMax);
  if (tEnd <= 0.0) return result;

  float cosTheta = dot(sun, d);
  float phaseR = uniformPhase ? 1.0 / (4.0 * ATMOS_PI) : atmosphereRayleighPhase(cosTheta);
  float phaseM = uniformPhase ? 1.0 / (4.0 * ATMOS_PI) : atmosphereMiePhase(a.g, cosTheta);

  float n = float(samples);
  for (int i = 0; i < samples; ++i) {
    float f0 = float(i) / n, f1 = float(i + 1) / n;
    float t0 = outside ? tEnd * f0 : tEnd * f0 * f0;
    float t1 = outside ? tEnd * f1 : tEnd * f1 * f1;
    float t = mix(t0, t1, 0.3);
    float dt = t1 - t0;
    vec3 q = p + d * t;
    float rq = length(q);
    vec3 up = q / rq;
    AtmosphereMedium m = atmosphereMedium(a, rq - a.bottom);
    vec3 sampleT = exp(-m.extinction * dt);
    float muSun = dot(up, sun);
    vec3 sunT = atmosphereSunTransmittance(a, rq, muSun, transmittanceLut);
    vec3 ms = multiScatter ? atmosphereMultiScatter(a, rq, muSun, multiScatterLut) : vec3(0.0);
    vec3 S = sunT * (m.rayleigh * phaseR + m.mie * phaseM) + ms * m.scattering;
    vec3 integral = (S - S * sampleT) / max(m.extinction, vec3(1e-9));
    result.L += result.T * integral;
    result.multiScatterAs1 += result.T * (m.scattering - m.scattering * sampleT) / max(m.extinction, vec3(1e-9));
    result.T *= sampleT;
  }

  if (ground && hitsGround && tEnd < tMax) {
    vec3 q = p + d * tEnd;
    vec3 up = normalize(q);
    float muSun = dot(up, sun);
    vec3 sunT = atmosphereSunTransmittance(a, a.bottom, muSun, transmittanceLut);
    result.L += result.T * sunT * clamp01(muSun) * a.albedo / ATMOS_PI;
  }
  return result;
}

/// The sky view LUT's (u, v) for a direction `viewZenith` (cos) and `sunAzimuth` (cos of the
/// angle around the zenith from the sun), the horizon at v = 0.5 seen from altitude `h`.
vec2 atmosphereSkyViewUv(Atmosphere a, float h, float viewZenith, float sunAzimuth)
{
  float r = a.bottom + h;
  float horizon = sqrt(max(h * (2.0 * a.bottom + h), 0.0));
  float beta = acos(clamp(horizon / r, -1.0, 1.0));
  float zenithHorizon = ATMOS_PI - beta;
  float viewAngle = acos(clamp(viewZenith, -1.0, 1.0));
  float v;
  if (viewAngle < zenithHorizon) {
    float coord = clamp01(viewAngle / zenithHorizon);
    v = (1.0 - sqrt(max(1.0 - coord, 0.0))) * 0.5;
  } else {
    float coord = clamp01((viewAngle - zenithHorizon) / beta);
    v = sqrt(coord) * 0.5 + 0.5;
  }
  float u = sqrt(clamp01((1.0 - sunAzimuth) * 0.5));
  return vec2(u, v);
}

void atmosphereSkyViewDirection(Atmosphere a, float h, vec2 uv, out float viewZenith, out float sunAzimuth)
{
  float r = a.bottom + h;
  float horizon = sqrt(max(h * (2.0 * a.bottom + h), 0.0));
  float beta = acos(clamp(horizon / r, -1.0, 1.0));
  float zenithHorizon = ATMOS_PI - beta;
  float viewAngle;
  if (uv.y < 0.5) {
    float coord = 1.0 - 2.0 * uv.y;
    viewAngle = zenithHorizon * (1.0 - coord * coord);
  } else {
    float coord = uv.y * 2.0 - 1.0;
    viewAngle = zenithHorizon + beta * coord * coord;
  }
  viewZenith = cos(viewAngle);
  sunAzimuth = 1.0 - 2.0 * uv.x * uv.x;
}

vec3 atmosphereSrgbToLinear(vec3 c)
{
  return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

vec2 atmosphereLatLong(vec3 d)
{
  return vec2(fract((atan(d.z, d.x) + 0.5 * ATMOS_PI) / (2.0 * ATMOS_PI)), acos(clamp(d.y, -1.0, 1.0)) / ATMOS_PI);
}

float atmosphereAerialSlice(float t, float maxDistance)
{
  return sqrt(max(t, 0.0) / maxDistance) * 32.0 - 0.5;
}

vec4 atmosphereAerialTap(sampler2D lut, vec2 local, int slice)
{
  vec2 origin = vec2(float(slice % 8), float(slice / 8)) * 32.0;
  vec2 xy = clamp(local, vec2(0.5), vec2(31.5));
  return textureLod(lut, (origin + xy) / vec2(256.0, 128.0), 0.0);
}

/// In scattering (rgb, for a unit sun) and mean transmittance (a) from the eye to `t` km
/// along the pixel at `screenUv`.
vec4 atmosphereAerial(sampler2D lut, vec2 screenUv, float t, float maxDistance)
{
  vec2 local = screenUv * 32.0;
  float w = atmosphereAerialSlice(t, maxDistance);
  if (w <= 0.0) return mix(vec4(0.0, 0.0, 0.0, 1.0), atmosphereAerialTap(lut, local, 0), clamp01(2.0 * w + 1.0));
  int s0 = min(int(w), 31);
  int s1 = min(s0 + 1, 31);
  return mix(atmosphereAerialTap(lut, local, s0), atmosphereAerialTap(lut, local, s1), clamp01(w - float(s0)));
}

struct AtmosphereSurface
{
  mat3 planetFromWorld;
  float zUp;
  float hasGround;
  float hasNight;
  float nightIntensity;
  float pixelAngle;
};

/// What the eye at `altitude` km above the ground along `up` sees toward `d`: the sky's in
/// scattering, scaled by `skyScale`, and the lit planet behind it, for a sun of illuminance
/// `sunE` toward `sun`. `transmittance` is what reaches the eye from beyond, zero on the planet.
vec3 atmosphereRadiance(Atmosphere a, vec3 up, float altitude, vec3 d, vec3 sun, vec3 sunE, float skyScale,
                          bool skyView, AtmosphereSurface surface, out vec3 transmittance,
                          sampler2D transmittanceLut,
                          sampler2D multiScatterLut,
                          sampler2D irradianceLut,
                          sampler2D skyViewLut,
                          sampler2D groundMap,
                          sampler2D nightMap)
{
  float h = max(altitude, 1e-3);
  float r = a.bottom + h;
  vec3 p = up * r;
  float mu = dot(up, d);
  float c = h * (2.0 * a.bottom + h);
  float disc = r * r * mu * mu - c;
  bool hitGround = mu < 0.0 && disc >= 0.0;
  float tGround = hitGround ? c / max(-r * mu + sqrt(max(disc, 0.0)), 1e-9) : 1e30;

  vec3 L;
  vec3 T;
  if (skyView && r < a.top) {
    float muSun = dot(up, sun);
    vec3 dp = d - up * mu;
    vec3 sp = sun - up * muSun;
    float dl = length(dp), sl = length(sp);
    float azimuth = dl > 1e-5 && sl > 1e-5 ? dot(dp, sp) / (dl * sl) : 1.0;
    vec2 uv = atmosphereSkyViewUv(a, h, mu, azimuth);
    vec2 texel = 0.5 / vec2(textureSize(skyViewLut, 0).x, textureSize(skyViewLut, 0).y);
    L = textureLod(skyViewLut, clamp(uv, texel, 1.0 - texel), 0.0).rgb;
    if (hitGround) {
      vec3 g = p + d * tGround;
      float muGround = dot(normalize(g), -d);
      T = atmosphereTransmittance(a, a.bottom, muGround, transmittanceLut)
        / max(atmosphereTransmittance(a, r, -mu, transmittanceLut), vec3(1e-6));
      T = min(T, vec3(1.0));
    } else {
      T = atmosphereTransmittance(a, r, mu, transmittanceLut);
    }
  } else {
    AtmosphereScatter s = atmosphereIntegrate(a, p, d, sun, tGround, r < a.top ? 32 : 48, false, false, true,
                                              transmittanceLut, multiScatterLut);
    L = s.L;
    T = s.T;
  }
  L *= sunE * skyScale;

  if (hitGround) {
    vec3 g = p + d * tGround;
    vec3 n = normalize(g);
    float muSun = dot(n, sun);
    vec3 albedo = a.albedo;
    vec3 emission = vec3(0.0);
    if (surface.hasGround > 0.5 || surface.hasNight > 0.5) {
      vec3 local = surface.planetFromWorld * n;
      local = mix(local, vec3(local.x, local.z, -local.y), surface.zUp);
      vec2 uv = atmosphereLatLong(local);
      float footprint = tGround * surface.pixelAngle / max(abs(dot(n, d)), 0.05);
      if (surface.hasGround > 0.5) {
        float lod = log2(max(footprint * float(textureSize(groundMap, 0).x) / (2.0 * ATMOS_PI * a.bottom), 1.0));
        albedo = atmosphereSrgbToLinear(textureLod(groundMap, uv, lod).rgb);
      }
      if (surface.hasNight > 0.5) {
        float lod = log2(max(footprint * float(textureSize(nightMap, 0).x) / (2.0 * ATMOS_PI * a.bottom), 1.0));
        emission = atmosphereSrgbToLinear(textureLod(nightMap, uv, lod).rgb) * surface.nightIntensity
                 * (1.0 - smoothstep(-0.05, 0.1, muSun));
      }
    }
    vec3 sunT = atmosphereSunTransmittance(a, a.bottom, muSun, transmittanceLut);
    vec3 sky = textureLod(irradianceLut, atmosphereMultiScatterUv(a, a.bottom, muSun, float(textureSize(irradianceLut, 0).x)),
                                      0.0).rgb * skyScale;
    L += T * (albedo / ATMOS_PI * sunE * (sunT * clamp01(muSun) + sky) + emission);
    T = vec3(0.0);
  }
  transmittance = T;
  return L;
}

/// The sun's disk toward `d`, limb darkened, for a sun of illuminance `sunE` and angular radius `radius`.
vec3 atmosphereSunDisk(vec3 d, vec3 sun, vec3 sunE, float radius)
{
  float cosR = cos(max(radius, 1e-4));
  float c = dot(d, sun);
  if (c < cosR) return vec3(0.0);
  float s = sin(max(radius, 1e-4));
  float x = clamp01(sqrt(max(1.0 - c * c, 0.0)) / s);
  float limb = 1.0 - 0.6 * (1.0 - sqrt(max(1.0 - x * x, 0.0)));
  return sunE / (ATMOS_PI * s * s * 0.8) * limb;
}
