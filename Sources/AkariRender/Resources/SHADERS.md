# Akari shaders

Shader sources live in `DeferredGraph.labfx`, as the `fx.shader` bodies of the LabFX deferred graph.

## Cross platform shading strategy

Akari renders through **LabGL / LabFX**. Only the shading language is
backend specific: a shader declares its interface once (`attributes`,
`uniforms`, `varyings`) with backend neutral semantics, then forks only
the body text (GLSL for the GL backend, MSL for the Metal backend).

Authoring a shader means adding one `fx.shader` entry to `DeferredGraph.labfx`
with its `vsh_glsl`/`fsh_glsl` and `vsh_msl`/`fsh_msl` body pair.
