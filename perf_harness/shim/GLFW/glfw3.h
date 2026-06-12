// Stub GLFW/OpenGL header so nanovg's demo.c compiles without GLFW.
// Only saveScreenShot() touches GL, and the harness never calls it.
#ifndef GLFW_STUB_H_
#define GLFW_STUB_H_

#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401

static inline void glReadPixels(int x, int y, int w, int h,
                                unsigned int format, unsigned int type,
                                void* data) {
  (void)x; (void)y; (void)w; (void)h; (void)format; (void)type; (void)data;
}

#endif  // GLFW_STUB_H_
