# Akari shaders

Every shader is a Swift struct in `Graph/Shaders`, one file each, holding its interface and its
GLSL and MSL bodies together. The render graph that uses them is described in `RENDERGRAPH.md`.

## Cross platform shading strategy

Akari renders through **LabGL / LabFX**. Only the shading language is
backend specific: a shader declares its interface once (`attributes`,
`uniforms`, `varyings`) with backend neutral semantics, then forks only
the body text (GLSL for the GL backend, MSL for the Metal backend).

## Layout

```
Graph/Shaders/<Name>Shader.swift              one shader, its interface and bodies
Graph/Shaders/FullscreenQuad.swift            the vertex stage full screen passes share
Graph/Shaders/Library/ShaderLibrary+*.swift   code several shaders splice in
```

A GLSL body is a `void main()` with any helpers above it. An MSL body puts its helpers above a
`//@main` line and its entry point code in a block below it, which LabFX splices into the
generated `vert_main` or `frag_main`.

## Writing a body

Bodies are raw string literals, so backslashes and quotes are written as they are, and `\#(...)`
splices in Swift values. Shared code comes from `ShaderLibrary`, and a shader that takes
parameters can use them in its body.

```swift
struct TaaCopyShader: FullscreenShader
{
  let source: Source

  var fragmentMSL: String
  {
    #"""
    //@main
    {
      \#(output) = \#(source.texture.sampler).read(uint2(gl_FragCoord.xy));
    }
    """#
  }
}
```

`TextureRef.sampler` and `TextureRef.output` give the names LabFX binds a texture to, such as
`u_position_texture` and `o_final_texture`.

## Adding a shader

1. Add `Graph/Shaders/MyShader.swift` with a struct conforming to `ShaderProgram`, or to
   `FullscreenShader` for a full screen pass, which only needs `fragmentGLSL` and `fragmentMSL`.
2. Use it from a pass in `Graph/DeferredGraph.swift` with `Shader(MyShader())`.

A pass only the Metal backend draws uses `ShaderLibrary.metalOnly` as its GLSL body.
