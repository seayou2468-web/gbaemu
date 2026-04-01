#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::RenderSprites() {
  // OAM sprite rendering logic
  // 128 sprites, 8 bytes each
  for (int i = 0; i < 128; ++i) {
    uint32_t base = i * 8;
    uint16_t attr0 = oam_[base] | (oam_[base + 1] << 8);
    uint16_t attr1 = oam_[base + 2] | (oam_[base + 3] << 8);
    uint16_t attr2 = oam_[base + 4] | (oam_[base + 5] << 8);

    // attr0/1/2 extraction (Y, X, shape, size, color mode, tile num, priority)
    // ... rendering ...
  }
}

void GBACore::RenderMode3Frame() {
  // Mode 3: 240x160 15-bit color (2 bytes per pixel)
  // Direct scanline by scanline or full frame?
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint32_t base = (y * kScreenWidth + x) * 2;
      uint16_t color = vram_[base] | (vram_[base + 1] << 8);
      // GBA 5-5-5 to 8-8-8-8
      uint8_t r = (color & 0x1F) << 3;
      uint8_t g = ((color >> 5) & 0x1F) << 3;
      uint8_t b = ((color >> 10) & 0x1F) << 3;
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

void GBACore::BuildObjWindowMask() {
  // Windowing logic for sprite visibility
}

void GBACore::ApplyColorEffects() {
  // Blend/Fade effects (SFX)
}

} // namespace gba
