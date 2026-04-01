#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::RenderSprites() {
  uint16_t dispcnt = ReadIO16(0x04000000); if (!(dispcnt & (1 << 12))) return;
  for (int i = 127; i >= 0; --i) {
    uint32_t base = i * 8; uint16_t attr0 = oam_[base] | (oam_[base + 1] << 8); uint16_t attr1 = oam_[base + 2] | (oam_[base + 3] << 8); uint16_t attr2 = oam_[base + 4] | (oam_[base + 5] << 8);
    if ((attr0 >> 8) & 2) continue;
    int y = attr0 & 0xFF; int x = attr1 & 0x1FF; if (x >= 240) x -= 512; if (y >= 160) y -= 256;
    uint8_t shape = (attr0 >> 14) & 3; uint8_t size = (attr1 >> 14) & 3;
    static const int sprite_sizes[4][4][2] = { {{8,8}, {16,16}, {32,32}, {64,64}}, {{16,8}, {32,8}, {32,16}, {64,32}}, {{8,16}, {8,32}, {16,32}, {32,64}}, {{0,0}, {0,0}, {0,0}, {0,0}} };
    int w = sprite_sizes[shape][size][0]; int h = sprite_sizes[shape][size][1];
    uint16_t tile_base = attr2 & 0x3FF; uint8_t palette_bank = (attr2 >> 12) & 0xF;
    for (int sy = 0; sy < h; ++sy) {
        int py = y + sy; if (py < 0 || py >= 160) continue;
        for (int sx = 0; sx < w; ++sx) {
            int px = x + sx; if (px < 0 || px >= 240) continue;
            uint16_t color = *reinterpret_cast<const uint16_t*>(&palette_ram_[0x200 + palette_bank * 32 + (tile_base % 16) * 2]);
            uint8_t r = (color & 0x1F) << 3; uint8_t g = ((color >> 5) & 0x1F) << 3; uint8_t b = ((color >> 10) & 0x1F) << 3;
            frame_buffer_[py * 240 + px] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
    }
  }
}

void GBACore::RenderMode3Frame() {
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint32_t addr = (y * kScreenWidth + x) * 2; uint16_t color = vram_[addr] | (vram_[addr + 1] << 8);
      uint8_t r = (color & 0x1F) << 3; uint8_t g = ((color >> 5) & 0x1F) << 3; uint8_t b = ((color >> 10) & 0x1F) << 3;
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

void GBACore::BuildObjWindowMask() {}
void GBACore::ApplyColorEffects() {}

} // namespace gba
