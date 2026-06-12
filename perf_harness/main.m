// Offscreen correctness + benchmark harness for MetalNanoVG.
//
// Usage (run with cwd = a direct subdirectory of nanovg/, e.g. nanovg/src,
// because demo.c loads assets from "../example/..."):
//   harness render <outdir>   - render correctness scenes to PNGs
//   harness bench             - print median CPU encode time per scene
//
// All scenes are deterministic so PNGs can be compared byte-for-byte
// across code changes.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "nanovg.h"
#include "nanovg_mtl.h"
#include "demo.h"
#include "stb_image_write.h"

enum { W = 1000, H = 600 };

typedef struct {
  NVGcontext* vg;
  MNVGframebuffer* fb;
} Harness;

static double now_ms(void) {
  return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1.0e6;
}

static void frame_begin(Harness* h) {
  mnvgBindFramebuffer(h->fb);
  mnvgClearWithColor(h->vg, nvgRGBAf(0.3f, 0.3f, 0.32f, 1.0f));
  nvgBeginFrame(h->vg, W, H, 1.0f);
}

static void frame_end_save(Harness* h, const char* outdir, const char* name) {
  nvgEndFrame(h->vg);
  if (outdir == NULL) return;
  unsigned char* pixels = (unsigned char*)malloc(W * H * 4);
  mnvgReadPixels(h->vg, h->fb->image, 0, 0, W, H, pixels);
  char path[1024];
  snprintf(path, sizeof(path), "%s/%s.png", outdir, name);
  if (!stbi_write_png(path, W, H, 4, pixels, W * 4)) {
    fprintf(stderr, "FAILED to write %s\n", path);
    exit(1);
  }
  printf("wrote %s\n", path);
  free(pixels);
}

// --- Scenes -----------------------------------------------------------------

static void scene_demo(NVGcontext* vg, DemoData* data, float t) {
  renderDemo(vg, 300.0f, 200.0f, W, H, t, 0, data);
}

// Alternates composite operations per shape; stresses pipeline-state churn.
static void scene_blend_stress(NVGcontext* vg, int n) {
  static const int ops[4] = {NVG_SOURCE_OVER, NVG_LIGHTER, NVG_ATOP, NVG_XOR};
  for (int i = 0; i < n; i++) {
    float x = 30.0f + (float)(i % 24) * 40.0f;
    float y = 30.0f + (float)((i / 24) % 14) * 40.0f;
    nvgGlobalCompositeOperation(vg, ops[i & 3]);
    nvgBeginPath(vg);
    nvgCircle(vg, x, y, 18.0f);
    nvgFillColor(vg, nvgRGBA((i * 37) & 255, (i * 91) & 255, (i * 53) & 255, 200));
    nvgFill(vg);
  }
  nvgGlobalCompositeOperation(vg, NVG_SOURCE_OVER);
}

// Many text draws against the same font atlas; stresses per-call texture binds.
static void scene_text(NVGcontext* vg, int nlines) {
  nvgFontFace(vg, "sans");
  nvgFontSize(vg, 18.0f);
  nvgFillColor(vg, nvgRGBA(255, 255, 255, 255));
  for (int i = 0; i < nlines; i++) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "Line %03d: The quick brown fox jumps over the lazy dog 0123456789",
             i);
    nvgText(vg, 20.0f, 20.0f + (float)(i % 28) * 20.0f, buf, NULL);
  }
}

// Untextured -> textured -> untextured -> text; exercises the pseudo-texture
// fallback and texture rebinding between draw types.
static void scene_mixed(NVGcontext* vg, int image) {
  nvgBeginPath(vg);
  nvgRect(vg, 20, 20, 200, 200);
  nvgFillColor(vg, nvgRGBA(220, 80, 80, 255));
  nvgFill(vg);

  NVGpaint imgPaint = nvgImagePattern(vg, 240, 20, 200, 200, 0, image, 1.0f);
  nvgBeginPath(vg);
  nvgRect(vg, 240, 20, 200, 200);
  nvgFillPaint(vg, imgPaint);
  nvgFill(vg);

  nvgBeginPath(vg);
  nvgRect(vg, 460, 20, 200, 200);
  nvgFillColor(vg, nvgRGBA(80, 220, 80, 255));
  nvgFill(vg);

  nvgFontFace(vg, "sans");
  nvgFontSize(vg, 40.0f);
  nvgFillColor(vg, nvgRGBA(255, 255, 255, 255));
  nvgText(vg, 20, 300, "pseudo-texture / rebind sequence", NULL);

  nvgBeginPath(vg);
  nvgRect(vg, 20, 340, 640, 60);
  nvgFillColor(vg, nvgRGBA(80, 80, 220, 255));
  nvgFill(vg);
}

// Draws `layers` full-framebuffer passes sampling `image`; bandwidth-heavy.
static void scene_sampling(NVGcontext* vg, int image, int layers) {
  for (int i = 0; i < layers; i++) {
    NVGpaint p = nvgImagePattern(vg, (float)(-i), (float)(-i), 1024, 1024, 0,
                                 image, 0.9f);
    nvgBeginPath(vg);
    nvgRect(vg, 0, 0, W, H);
    nvgFillPaint(vg, p);
    nvgFill(vg);
  }
}

static void make_pattern(unsigned char* buf, int w, int h, int seed) {
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      unsigned char* p = buf + (y * w + x) * 4;
      p[0] = (unsigned char)((x * 7 + seed * 31) & 255);
      p[1] = (unsigned char)((y * 11 + seed * 17) & 255);
      p[2] = (unsigned char)((x ^ y ^ seed) & 255);
      p[3] = 255;
    }
  }
}

// Creates/deletes/recreates images and validates handle semantics; renders all
// surviving images.
static int scene_texture_churn(Harness* h, const char* outdir) {
  NVGcontext* vg = h->vg;
  enum { N = 40, SZ = 64 };
  unsigned char buf[SZ * SZ * 4];
  int imgs[N];

  for (int i = 0; i < N; i++) {
    make_pattern(buf, SZ, SZ, i);
    imgs[i] = nvgCreateImageRGBA(vg, SZ, SZ, 0, buf);
    if (imgs[i] == 0) { fprintf(stderr, "FAIL: image create %d\n", i); return 1; }
  }

  // Stale-handle check: delete then recreate (slot gets reused); the old id
  // must no longer resolve.
  int stale = imgs[0];
  nvgDeleteImage(vg, stale);
  if (mnvgImageHandle(vg, stale) != NULL) {
    fprintf(stderr, "FAIL: deleted image id still resolves\n");
    return 1;
  }
  make_pattern(buf, SZ, SZ, 100);
  imgs[0] = nvgCreateImageRGBA(vg, SZ, SZ, 0, buf);
  if (imgs[0] == 0 || imgs[0] == stale) {
    fprintf(stderr, "FAIL: recreate after delete (id=%d stale=%d)\n", imgs[0], stale);
    return 1;
  }
  if (mnvgImageHandle(vg, stale) != NULL) {
    fprintf(stderr, "FAIL: stale id resolves after slot reuse\n");
    return 1;
  }
  if (mnvgImageHandle(vg, imgs[0]) == NULL) {
    fprintf(stderr, "FAIL: live image handle is NULL\n");
    return 1;
  }

  // Churn: delete every other image, recreate with new patterns.
  for (int i = 1; i < N; i += 2) nvgDeleteImage(vg, imgs[i]);
  for (int i = 1; i < N; i += 2) {
    make_pattern(buf, SZ, SZ, 200 + i);
    imgs[i] = nvgCreateImageRGBA(vg, SZ, SZ, 0, buf);
    if (imgs[i] == 0) { fprintf(stderr, "FAIL: image recreate %d\n", i); return 1; }
  }

  // Readback check: uploaded content round-trips through mnvgReadPixels.
  unsigned char check[SZ * SZ * 4];
  make_pattern(buf, SZ, SZ, 200 + 1);
  mnvgReadPixels(vg, imgs[1], 0, 0, SZ, SZ, check);
  if (memcmp(buf, check, sizeof(buf)) != 0) {
    fprintf(stderr, "FAIL: image readback mismatch\n");
    return 1;
  }

  frame_begin(h);
  for (int i = 0; i < N; i++) {
    float x = 20.0f + (float)(i % 10) * 96.0f;
    float y = 20.0f + (float)(i / 10) * 96.0f;
    NVGpaint p = nvgImagePattern(vg, x, y, 80, 80, 0, imgs[i], 1.0f);
    nvgBeginPath(vg);
    nvgRect(vg, x, y, 80, 80);
    nvgFillPaint(vg, p);
    nvgFill(vg);
  }
  frame_end_save(h, outdir, "texture_churn");

  for (int i = 0; i < N; i++) nvgDeleteImage(vg, imgs[i]);
  printf("texture churn checks passed\n");
  return 0;
}

// --- Modes ------------------------------------------------------------------

static int cmp_double(const void* a, const void* b) {
  double x = *(const double*)a, y = *(const double*)b;
  return (x > y) - (x < y);
}

static void bench(Harness* h, const char* name, int frames,
                  void (^body)(int i)) {
  double* times = (double*)malloc(sizeof(double) * frames);
  const double tstart = now_ms();
  for (int i = 0; i < frames; i++) {
    frame_begin(h);  // semaphore wait happens here, excluded from CPU timing
    double t0 = now_ms();
    body(i);
    nvgEndFrame(h->vg);
    times[i] = now_ms() - t0;
  }
  // Drain GPU before stopping the throughput clock.
  unsigned char px[4];
  mnvgReadPixels(h->vg, h->fb->image, 0, 0, 1, 1, px);
  const double total = now_ms() - tstart;

  qsort(times, frames, sizeof(double), cmp_double);
  printf("%-16s cpu median %7.3f ms  p90 %7.3f ms | pipeline %7.3f ms/frame"
         "  (%d frames)\n",
         name, times[frames / 2], times[(int)(frames * 0.9)],
         total / frames, frames);
  free(times);
}

int main(int argc, char** argv) {
  @autoreleasepool {
    const char* mode = argc > 1 ? argv[1] : "render";
    const char* outdir = argc > 2 ? argv[2] : ".";

    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.drawableSize = CGSizeMake(W, H);

    NVGcontext* vg = nvgCreateMTL(
        (__bridge void*)layer,
        NVG_ANTIALIAS | NVG_STENCIL_STROKES | NVG_TRIPLE_BUFFER);
    if (vg == NULL) { fprintf(stderr, "FAIL: nvgCreateMTL\n"); return 1; }

    __block DemoData data;
    if (loadDemoData(vg, &data) != 0) {
      fprintf(stderr, "FAIL: loadDemoData (run from a subdir of nanovg/)\n");
      return 1;
    }

    Harness h;
    h.vg = vg;
    h.fb = mnvgCreateFramebuffer(vg, W, H, 0);
    if (h.fb == NULL || h.fb->image == 0) {
      fprintf(stderr, "FAIL: mnvgCreateFramebuffer\n");
      return 1;
    }

    int rc = 0;
    if (strcmp(mode, "render") == 0) {
      const float ts[3] = {0.0f, 2.5f, 6.0f};
      for (int i = 0; i < 3; i++) {
        frame_begin(&h);
        scene_demo(vg, &data, ts[i]);
        char name[64];
        snprintf(name, sizeof(name), "demo_t%d", i);
        frame_end_save(&h, outdir, name);
      }

      frame_begin(&h);
      scene_blend_stress(vg, 300);
      frame_end_save(&h, outdir, "blend_stress");

      frame_begin(&h);
      scene_text(vg, 150);
      frame_end_save(&h, outdir, "text");

      frame_begin(&h);
      scene_mixed(vg, data.images[0]);
      frame_end_save(&h, outdir, "mixed");

      // Mipmapped image drawn minified; exercises generateMipmaps + trilinear
      // sampling so usage/storage changes get validation coverage.
      {
        enum { MSZ = 256 };
        unsigned char* mbuf = (unsigned char*)malloc(MSZ * MSZ * 4);
        make_pattern(mbuf, MSZ, MSZ, 7);
        int mimg = nvgCreateImageRGBA(vg, MSZ, MSZ, NVG_IMAGE_GENERATE_MIPMAPS,
                                      mbuf);
        free(mbuf);
        if (mimg == 0) { fprintf(stderr, "FAIL: mipmap image\n"); return 1; }
        frame_begin(&h);
        for (int i = 0; i < 6; i++) {
          float s = 256.0f / (float)(1 << i);
          float x = 20.0f + (float)i * 150.0f;
          NVGpaint p = nvgImagePattern(vg, x, 20, s, s, 0, mimg, 1.0f);
          nvgBeginPath(vg);
          nvgRect(vg, x, 20, s, s);
          nvgFillPaint(vg, p);
          nvgFill(vg);
        }
        frame_end_save(&h, outdir, "mipmap");
        nvgDeleteImage(vg, mimg);
      }

      rc = scene_texture_churn(&h, outdir);

      id<MTLDevice> device = (__bridge id<MTLDevice>)mnvgDevice(vg);
      printf("device.currentAllocatedSize = %.2f MB\n",
             (double)device.currentAllocatedSize / (1024.0 * 1024.0));
    } else if (strcmp(mode, "bench") == 0) {
      const int kFrames = 300;
      bench(&h, "demo", kFrames, ^(int i) {
        scene_demo(vg, &data, (float)i * 0.016f);
      });
      bench(&h, "blend_stress", kFrames, ^(int i) {
        (void)i;
        scene_blend_stress(vg, 300);
      });
      bench(&h, "text", kFrames, ^(int i) {
        (void)i;
        scene_text(vg, 150);
      });

      // Many live textures, one textured draw each; stresses findTexture.
      enum { NTEX = 150, TSZ = 32 };
      static int imgs[NTEX];
      unsigned char* tbuf = (unsigned char*)malloc(TSZ * TSZ * 4);
      for (int i = 0; i < NTEX; i++) {
        make_pattern(tbuf, TSZ, TSZ, i);
        imgs[i] = nvgCreateImageRGBA(vg, TSZ, TSZ, 0, tbuf);
      }
      free(tbuf);
      bench(&h, "many_textures", kFrames, ^(int i) {
        (void)i;
        for (int j = 0; j < NTEX; j++) {
          float x = 10.0f + (float)(j % 30) * 32.0f;
          float y = 10.0f + (float)(j / 30) * 32.0f;
          NVGpaint p = nvgImagePattern(vg, x, y, 28, 28, 0, imgs[j], 1.0f);
          nvgBeginPath(vg);
          nvgRect(vg, x, y, 28, 28);
          nvgFillPaint(vg, p);
          nvgFill(vg);
        }
      });
      for (int i = 0; i < NTEX; i++) nvgDeleteImage(vg, imgs[i]);

      // Bandwidth-heavy: 16 full-framebuffer layers sampling a 1k texture.
      enum { BSZ = 1024 };
      unsigned char* bbuf = (unsigned char*)malloc(BSZ * BSZ * 4);
      make_pattern(bbuf, BSZ, BSZ, 42);
      int bimg = nvgCreateImageRGBA(vg, BSZ, BSZ, 0, bbuf);
      free(bbuf);
      bench(&h, "sampling", kFrames, ^(int i) {
        (void)i;
        scene_sampling(vg, bimg, 16);
      });
      nvgDeleteImage(vg, bimg);
    } else {
      fprintf(stderr, "unknown mode '%s'\n", mode);
      rc = 1;
    }

    freeDemoData(vg, &data);
    mnvgDeleteFramebuffer(h.fb);
    nvgDeleteMTL(vg);
    if (rc == 0) printf("OK\n");
    return rc;
  }
}
