# Third-party notices

Plantty is MIT licensed (see `LICENSE`). Release builds statically link **libghostty**, which brings in the libraries below. Their copyright notices travel with every copy of Plantty, inside the app at `Plantty.app/Contents/Resources/THIRD_PARTY_NOTICES.md`.

## Ghostty

Source: https://github.com/ghostty-org/ghostty. `Plantty/Ghostty/SurfaceView.swift`, `NSEvent+Extension.swift` and parts of `GhosttyApp.swift` are adapted from Ghostty's macOS app.

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Libraries compiled into libghostty

These are built from Ghostty's `pkg/` directory. Each keeps its own license; the full texts are in the linked upstream projects.

| Library | License | Upstream |
| --- | --- | --- |
| Dear ImGui (via dcimgui) | MIT | https://github.com/ocornut/imgui |
| FreeType | FreeType License (FTL) | https://freetype.org |
| libpng | PNG Reference Library License v2 | https://github.com/pnggroup/libpng |
| zlib | zlib License | https://zlib.net |
| Oniguruma | BSD 2-Clause | https://github.com/kkos/oniguruma |
| Wuffs | Apache 2.0 or MIT | https://github.com/google/wuffs |
| SPIRV-Cross | Apache 2.0 | https://github.com/KhronosGroup/SPIRV-Cross |
| glslang | BSD 3-Clause and other permissive licenses | https://github.com/KhronosGroup/glslang |
| Sentry Native | MIT | https://github.com/getsentry/sentry-native |
| Breakpad | BSD 3-Clause | https://chromium.googlesource.com/breakpad/breakpad |
| Highway | Apache 2.0 or BSD 3-Clause | https://github.com/google/highway |
| simdutf | Apache 2.0 or MIT | https://github.com/simdutf/simdutf |

Portions of this software are copyright © The FreeType Project (https://freetype.org). All rights reserved.
