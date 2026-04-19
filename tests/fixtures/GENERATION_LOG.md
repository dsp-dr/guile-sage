# Image Generation Log

Model: `x/flux2-klein:4b` (5.7GB, Apache 2.0)
Host: `localhost:11434` (Ollama, local network)
Date: 2026-01-29

## Timing Summary

| File | Size | Pixels | Time | Prompt |
|------|------|--------|------|--------|
| image-1769661624.png | 419KB | 1024x1024 | 16s | a simple blue circle on white background |
| guile-logo-512.png | 137KB | 512x512 | 8s | guile scheme logo, minimalist |
| test-tool-exec.png | 23KB | 256x256 | 2s | yellow star on black background |
| fractal-spiral-512.png | 604KB | 512x512 | 4s | fractal spiral in purple and gold, mathematical art |
| zen-garden-512.png | 568KB | 512x512 | 5s | zen garden with raked sand and stones, aerial view |
| circuit-board-512.png | 401KB | 512x512 | 5s | circuit board traces glowing neon blue, macro photography |
| lighthouse-watercolor-512.png | 493KB | 512x512 | 4s | watercolor painting of a lighthouse at sunset |
| pixel-castle-512.png | 312KB | 512x512 | 5s | isometric pixel art castle with moat |
| bauhaus-pattern-512.png | 184KB | 512x512 | 5s | abstract geometric pattern, bauhaus style, primary colors |
| nebula-1024.png | 1779KB | 1024x1024 | 18s | deep space nebula with stars, hubble telescope style |
| wave-hokusai-1024.png | 1753KB | 1024x1024 | 17s | japanese wave woodblock print, hokusai style |

## Performance Notes

- **256x256**: ~2-3s per image
- **512x512**: ~4-5s per image (model warm), ~8s (cold load)
- **1024x1024**: ~16-18s per image
- Scaling is roughly **linear with pixel count** (4x pixels = ~4x time)
- First generation after model load adds ~4s overhead
- Model stays in VRAM for 5min after last request (`expires_at` in `/api/ps`)
- Total VRAM usage: 5.7GB (fits in unified memory on Mac)

## Audit

All images reviewed 2026-01-29. Contents:
- Simple geometric shapes (circles, squares, triangles, stars)
- Artistic scenes (landscapes, architecture, abstract patterns)
- No offensive content, no PII, no TOS violations
- Hokusai wave contains decorative (non-meaningful) CJK characters, expected for style
