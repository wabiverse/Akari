<!-- markdownlint-configure-file {
  "MD013": {
    "code_blocks": false,
    "tables": false
  },
  "MD033": false,
  "MD041": false
} -->

<div align="center">

# Akari

<p><b>灯り • "Light"</b></p>

###### <samp>♫ [<b>Starborn</b>](https://open.spotify.com/track/5bXC8lSYDw2uNoH8PHjBRs?si=cfee0d2767fe4eea).</samp>

</div>

## Overview

Akari is a realtime render engine for [**Hydra**](https://openusd.org/release/api/_page__hydra__getting__started__guide.html),
focused on speed and visual fidelity at game frame rates while rendering PBR materials. Akari can be used on every platform Swift
reaches: macOS, iOS, visionOS, Linux, Windows, and Android.

Akari is a [**Hydra Render Delegate**](https://learn.foundry.com/katana/4.5v3/dev-guide/Plugins/HydraRenderDelegates/Introduction.html)
that exists as a renderer plugin, like [**Storm**](https://openusd.org/release/api/hd_storm_page_front.html). Where Storm is USD's reference
rasterizer, Akari is a modern PBR viewport renderer meant to *look good* by default and to evolve toward a realtime game engine's needs.

## Philosophy

Modern PBR render engines look the way they do because of a stack of realtime techniques over a good rasterizer:

- **Rasterization.** Forward+/deferred PBR, image based lighting, light probes/irradiance volumes, soft & contact shadows.
- **Screen space.** GTAO, SSR, screen space GI, TAA.
- **Color pipeline.** AgX, Filmic, etc.
- **Opt-in hardware ray tracing.** RT reflections, shadows, and GI via acceleration structures.

Akari is deliberately *not* a full path tracer like [**Pixar's RenderMan**](https://renderman.pixar.com) or [**Arnold**](https://www.autodesk.com/products/arnold/overview).
Akari is designed for speed and interactivity at game framerates, and aims to match the visual fidelity of other realtime render engines such as
[**Blender's EEVEE**](https://docs.blender.org/manual/en/latest/render/eevee/index.html) and [**Google's Filament**](https://github.com/google/filament).

## Architecture

Akari builds on [**LabGL**](https://codeberg.org/meshula/LabGL) for its high level graphics interface API.

| Platform                        | Backend                     |
|-------------------------------|-------------------------------|
| macOS / iOS / visionOS            | Metal             |
| Linux / Android / Windows         | OpenGL (now) - Vulkan (later) |

## License
All files copyright (c) 2026 Wabi Foundation, and released under a BSD 3-Clause License. Certain files as noted are covered by their own licenses.

Akari builds on the following third-party frameworks, libraries, and fonts.

### High level graphics interface

**LabGL/LabFX** — an immediate-mode graphics library with a classic GL 1 API surface, by Nick Porcino
https://codeberg.org/meshula/LabGL
License: BSD 3-Clause
Credit is required if the code is distributed.

### 3D graphics framework & rendering pipeline

**OpenUSD/Hydra** — an efficient, scalable system for authoring, reading, and streaming time-sampled scene description, by Pixar Animation Studios
https://github.com/PixarAnimationStudios/OpenUSD
License: Tomorrow Open Source Technology License 1.0
Credit is required if the code is distributed.

### Rendering algorithms

**Slug** — GPU font rendering algorithm by Eric Lengyel
Reference shaders: https://github.com/EricLengyel/Slug
Paper: https://jcgt.org/published/0006/02/02/ (JCGT 2017)
License: dual MIT / Apache 2.0. The patent has been dedicated to the public domain.
Credit is required if the code is distributed.

### Text shaping

**kb_text_shape** — single-header Unicode text segmentation and OpenType shaping, by Jimmy Lefevre
https://github.com/jlefevre/kb (part of the `kb` single-header library collection)
License: zlib

**FreeType** — font loading and outline extraction
https://freetype.org
License: FreeType License (BSD-style) / GPLv2

### UI and windowing

**Clay** — immediate-mode UI layout library by Nic Barker
https://github.com/nicbarker/clay
License: zlib

**RGFW** — single-header cross-platform windowing by ColleagueRiley
https://github.com/ColleagueRiley/RGFW
License: zlib

**glad2** — GL loader generator
https://github.com/Dav1dde/glad
License: generated code is WTFPL / CC0; loader itself is Apache 2.0

### Math and geometry

**GLM** — OpenGL Mathematics library
https://github.com/g-truc/glm
License: MIT

**par_shapes** — triangle mesh generation, by Philip Rideout
https://github.com/prideout/par
License: MIT

**LabCamera** — interactive camera controller, by Nick Porcino
https://github.com/meshula/LabCamera
License: MIT

**LabText** — text utilities, by Nick Porcino
https://github.com/meshula/LabText
License: MIT

**OpenVDB** — sparse volumetric data structure (used by the VoxTree demo)
https://www.openvdb.org
License: MPL 2.0

**oneTBB** — Intel Threading Building Blocks (OpenVDB dependency)
https://github.com/oneapi-src/oneTBB
License: Apache 2.0

### Fonts

**Cascadia Mono** — monospace programming font by Microsoft
https://github.com/microsoft/cascadia-code
License: SIL Open Font License 1.1

**Latin Modern** — TeX math serif family, derived from Computer Modern, by B. Jackowski & J.M. Nowacki / GUST
https://www.gust.org.pl/projects/e-foundry/latin-modern
License: GUST Font License (permissive, similar to LPPL)

**STIX Two Math** — mathematical OpenType font by the STIX Fonts Project
https://github.com/stipub/stixfonts
License: SIL Open Font License 1.1

**Noto Sans Devanagari** — Devanagari script font by Google
https://github.com/google/fonts/tree/main/ofl/notosansdevanagari
License: SIL Open Font License 1.1

### MetaverseKit distributed libraries

**Eigen**
https://github.com/libigl/eigen
License: BSD 3-Clause

**Draco**
https://github.com/google/draco
License: Apache 2.0

**ZStandard**
https://github.com/facebook/zstd
License: BSD 3-Clause

**ZLib**
https://www.zlib.net
License: zlib

**Yaml**
https://github.com/yaml/libyaml
License: MIT

**WebP**
https://github.com/webmproject/libwebp
License: BSD 3-Clause

**LZMA2**
https://github.com/conor42/fast-lzma2
License: BSD 3-Clause

**MiniZip**
https://github.com/zlib-ng/minizip-ng
License: zlib

**Blosc**
https://github.com/Blosc/c-blosc
License: BSD 3-Clause

**OpenVDB**
https://github.com/AcademySoftwareFoundation/openvdb
License: Apache 2.0

**OpenColorIO**
https://github.com/AcademySoftwareFoundation/OpenColorIO
License: BSD 3-Clause

**OpenImageIO**
https://github.com/AcademySoftwareFoundation/OpenImageIO
License: BSD 3-Clause

**MaterialX**
https://github.com/materialx/MaterialX
License: Apache 2.0

**LibPNG**
http://www.libpng.org/pub/png
License: LibPNG

**Boost**
https://github.com/boostorg/boost
License: Boost Software License

**Python**
https://python.org
License: Python Software Foundation License

**OpenSubdiv**
https://github.com/PixarAnimationStudios/OpenSubdiv
License: Apache 2.0

**OSL (Open Shading Language)**
https://github.com/AcademySoftwareFoundation/OpenShadingLanguage
License: BSD 3-Clause

**Ptex**
https://github.com/wdas/ptex
License: Apache 2.0

**ImGUI**
https://github.com/ocornut/imgui
License: MIT

**Embree**
https://github.com/RenderKit/embree
License: Apache 2.0

**Alembic**
https://github.com/alembic/alembic
License: BSD 3-Clause

**OpenEXR**
https://github.com/AcademySoftwareFoundation/openexr
License: BSD 3-Clause

**Imath**
https://github.com/AcademySoftwareFoundation/Imath
License: BSD 3-Clause

**HDF5**
https://github.com/HDFGroup/hdf5
License: HDF5 License

**TurboJPEG**
https://github.com/libjpeg-turbo/libjpeg-turbo
License: MIT

**TIFF**
https://github.com/libsdl-org/libtiff
License: Apache 2.0
