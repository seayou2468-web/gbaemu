// iOS-focused translation-unit optimization hints (no behavior change).
#if defined(__APPLE__) && defined(__clang__)
#pragma clang optimize on
#endif

#include "./module_includes.h"

// Rebuilt Objective-C++ module from reference implementation sources.
// NOTE: Source bodies are embedded and adapted here (no direct include of reference files).
#if defined(__cplusplus)
extern "C" {
#endif

// ---- BEGIN rewritten from reference implementation/input.c ----
GBA_EXPORT const struct InputPlatformInfo GBAInputInfo = {
  .platformName = "gba",
  .keyId = (const char*[]) {
    "A",
    "B",
    "Select",
    "Start",
    "Right",
    "Left",
    "Up",
    "Down",
    "R",
    "L"
  },
  .nKeys = GBA_KEY_MAX,
  .hat = {
    .up = GBA_KEY_UP,
    .left = GBA_KEY_LEFT,
    .down = GBA_KEY_DOWN,
    .right = GBA_KEY_RIGHT
  }
};
// ---- END rewritten from reference implementation/input.c ----
#if defined(__cplusplus)
}  // extern "C"
#endif
