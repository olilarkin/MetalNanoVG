# perf_harness

Offscreen correctness + benchmark harness for MetalNanoVG. Renders
deterministic scenes (the nanovg demo, blend-stress, text, texture-churn,
mipmaps, and a GPU-bound sampling scene) into an `MNVGframebuffer`, reads the
pixels back, and writes PNGs that can be compared byte-for-byte across code
changes. Not part of the library; macOS only.

```sh
./build.sh                      # clones nanovg on first run, builds ./harness

# Capture a baseline before making changes:
mkdir -p out/baseline
(cd nanovg/src && ../../harness render ../../out/baseline)

./verify.sh                     # re-render and diff against out/baseline
(cd nanovg/src && ../../harness bench)   # CPU encode + pipeline ms/frame

# Run with the Metal validation layer:
(cd nanovg/src && MTL_DEBUG_LAYER=1 ../../harness render ../../out/current)
```

The harness must run with its working directory set to a direct subdirectory
of `nanovg/` (e.g. `nanovg/src`) because the nanovg demo loads its assets via
`../example/...` paths; `verify.sh` handles this.
