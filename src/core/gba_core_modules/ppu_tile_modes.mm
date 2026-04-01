#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::RenderMode0Frame() {
  // Mode 0: Tile-based bg (BG0-BG3)
}

void GBACore::RenderMode1Frame() {
  // Mode 1: BG0, BG1 tile, BG2 affine
}

void GBACore::RenderMode2Frame() {
  // Mode 2: BG2, BG3 affine
}

void GBACore::RenderMode4Frame() {
  // Mode 4: BG2 bitmap (2 banks, 8-bit palette indexed)
  uint16_t dispcnt = ReadIO16(0x04000000);
  uint32_t bank = (dispcnt >> 4) & 1;
  uint32_t base = bank * 0xA000;
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint8_t index = vram_[base + y * kScreenWidth + x];
      uint16_t palette = palette_ram_[index * 2] | (palette_ram_[index * 2 + 1] << 8);
      uint8_t r = (palette & 0x1F) << 3;
      uint8_t g = ((palette >> 5) & 0x1F) << 3;
      uint8_t b = ((palette >> 10) & 0x1F) << 3;
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

void GBACore::RenderMode5Frame() {
  // Mode 5: BG2 bitmap (2 banks, 160x128 15-bit color)
}

} // namespace gba
