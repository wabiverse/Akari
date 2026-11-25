# The render graph in Swift

Akari's render graphs are declared in Swift with result builders, the way SwiftUI builds views.
`Graph/RenderGraph.swift` holds the building blocks and `Graph/RenderGraph+LabFX.swift` writes a
graph out as LabFX text, which the engine hands to the unchanged LabFX runtime.

| File | Holds |
| --- | --- |
| `Graph/DeferredGraph.swift` | The deferred graph, every pass in the order it runs |
| `Graph/DeferredGraph+Buffers.swift` | Its buffers, one enum each with a case per texture |
| `Graph/DeferredGraph+Uniforms.swift` | The typed uniform and sampler catalog |
| `Graph/Shaders` | Its shaders, one file each with the interface and the GLSL and MSL bodies, see `SHADERS.md` |

## What it looks like

```swift
enum GBuffer: String, RenderBuffer
{
  case diffuse, position, normal, material, velocity, ptexA, ptexB

  static let name = "gbuffer"
  static var options: BufferOptions { .init(depth: true) }
}

struct GridOverlayShader: FullscreenShader
{
  let name = "grid-overlay"

  var uniforms: [Declaration]
  {
    Sampler(GBuffer.position)
    Sampler(GBuffer.normal)
    Uniforms.view
    Uniforms.gridInvProj
  }

  let fragmentGLSL = #"""
    void main()
    {
      ...
    }
    """#

  let fragmentMSL = #"""
    //@main
    {
      ...
    }
    """#
}

Pass(.gridOverlay)
{
  Quad()
  Blend(.alpha)
  Shader(GridOverlayShader())
  Inputs(GBuffer.position, GBuffer.normal)
  Output(TonemapBuffer.tonemap)
}
```

## Shaders are values

A shader is a struct whose instance describes it, so one type can stand for a whole family and
take parameters that shape its name, its interface and its bodies.

```swift
struct SunShadowBlurShader: FullscreenShader
{
  let axis: BlurAxis

  var name: String { "sun-shadow-blur-\(axis.suffix)" }

  var source: TextureRef { axis == .horizontal ? SunShadowAccumBuffer.sunShadowAccum.ref : SunShadowBlurBuffer.sunShadowBlurH.ref }

  var uniforms: [Declaration]
  {
    Sampler(source)
    Sampler(GBuffer.position)
    Sampler(GBuffer.normal)
  }

  var fragmentMSL: String
  {
    #"""
    //@main
    {
      float4 center = \#(source.sampler).read(uint2(gl_FragCoord.xy));
      ...
    }
    """#
  }
}
```

Because the graph body is a result builder, a family's passes can come from a loop.

```swift
for level in bloomDown.indices
{
  let shader = BloomDownShader(level: level)
  Pass("bloom down \(level)")
  {
    Quad()
    Shader(shader)
    Inputs(shader.source)
    Output(bloomDown[level])
  }
}
```

## Building blocks

| Swift | Writes |
| --- | --- |
| A `RenderBuffer` enum | `buffer:`, its cases are the textures in attachment order |
| `Quad()` | `draw: quad`, `depth test: never`, `write depth: no` |
| `Sampler(GBuffer.position)` | `u_position_texture: sampler2d`, named by the input convention |
| `Uniform<SIMD4<Float>>` | `vec4`, from the Swift type |
| `FullscreenShader` | the `texCoord` varying, the shared quad vertex stage, and a fragment stage from `fragmentGLSL` and `fragmentMSL` |
| `Stage(.vertex, glsl:, msl:)` | a stage with its two bodies and the attributes it reads |
| `Shader(SomeShader())` | `use shader:`, and adds the shader's declaration to the graph |
| `Shaders(SomeShader())` | declares shaders no pass names, such as the ones geometry captures replay through |
| `Output(Buffer.self)` | every texture of the buffer |
| `Output.visible` | `outputs: visible` |
| `Dispatch(groups, threadgroup:)` | a compute pass |
| `Callback(.name)` | a pass Swift draws itself |

## What the compiler checks

- Pass names come from `Akari.LabFXEngine.Pass`, the same enum `setPassActive` takes.
- Buffer and texture references are enum cases, so a typo fails to compile.
- `Output(a, b)` is generic over one buffer type, so writing to two buffers in one pass fails to compile.
- A uniform's GLSL type comes from its Swift type, and `runtime.setUniform(Uniforms.zUp, value)` checks the value against it.

`graph.diagnostics` catches what types can't, such as a pass input with no matching sampler or a
quad with no shader.

## Debugging

```
Kraken --emit-labfx [file]                  prints or writes the deferred graph as LabFX
Kraken --check-labfx graph.labfx            compares each section with the same section of graph.labfx
```

## Next steps

- Replace the string enums in `LabFXEngine+Graph.swift` with the typed catalogs, so
  `runtime.texture(GBuffer.position)` and `runtime.setUniform(Uniforms.renderScale, value)` are
  checked end to end.
- Put passes that need a certain quality tier inside `if` blocks, so the graph only builds what is enabled.
- Model `active:`, `mip:`, the `texture:` section and per pass `latency:` once a graph needs them.
