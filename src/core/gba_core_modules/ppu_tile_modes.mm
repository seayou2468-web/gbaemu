#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::RenderMode0Frame() {
  uint16_t dispcnt = ReadIO16(0x04000000);

  // BG0-BG3 rendering logic
  for (int priority = 3; priority >= 0; --priority) {
    for (int bg = 3; bg >= 0; --bg) {
      if (!(dispcnt & (1 << (8 + bg)))) continue;

      uint16_t bgcnt = ReadIO16(0x04000008 + bg * 2);
      if (((bgcnt >> 2) & 3) != priority) continue;

      // Scan tile data, palette data...
    }
  }
}

void GBACore::RenderMode1Frame() {
  uint16_t dispcnt = ReadIO16(0x04000000);
  if (dispcnt & (1 << 8)) RenderMode0Frame(); // BG0
  if (dispcnt & (1 << 9)) RenderMode0Frame(); // BG1
  if (dispcnt & (1 << 10)) RenderMode2Frame(); // BG2 (Affine)
}

void GBACore::RenderMode2Frame() {
  // BG2, BG3 Affine rendering
}

void GBACore::RenderMode4Frame() {
  uint16_t dispcnt = ReadIO16(0x04000000);
  uint32_t bank = (dispcnt >> 4) & 1;
  uint32_t vbase = bank * 0xA000;
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint8_t index = vram_[vbase + y * kScreenWidth + x];
      uint16_t palette = *reinterpret_cast<const uint16_t*>(&palette_ram_[index * 2]);
      uint8_t r = (palette & 0x1F) << 3;
      uint8_t g = ((palette >> 5) & 0x1F) << 3;
      uint8_t b = ((palette >> 10) & 0x1F) << 3;
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

void GBACore::RenderMode5Frame() {
  uint16_t dispcnt = ReadIO16(0x04000000);
  uint32_t bank = (dispcnt >> 4) & 1;
  uint32_t vbase = bank * 0xA000;
  for (int y = 0; y < 128; ++y) {
    for (int x = 0; x < 160; ++x) {
      uint32_t addr = vbase + (y * 160 + x) * 2;
      uint16_t color = *reinterpret_cast<const uint16_t*>(&vram_[addr]);
      uint8_t r = (color & 0x1F) << 3;
      uint8_t g = ((color >> 5) & 0x1F) << 3;
      uint8_t b = ((color >> 10) & 0x1F) << 3;
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

} // namespace gba
