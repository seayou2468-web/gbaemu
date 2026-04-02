#include "../gba_core.h"

namespace gba {

namespace {

inline uint32_t Bgr555ToRgba8888(uint16_t bgr555) {
  const uint32_t r5 = bgr555 & 0x1Fu;
  const uint32_t g5 = (bgr555 >> 5) & 0x1Fu;
  const uint32_t b5 = (bgr555 >> 10) & 0x1Fu;
  const uint32_t r8 = (r5 << 3) | (r5 >> 2);
  const uint32_t g8 = (g5 << 3) | (g5 >> 2);
  const uint32_t b8 = (b5 << 3) | (b5 >> 2);
  return 0xFF000000u | (r8 << 16) | (g8 << 8) | b8;
}

}  // namespace

void GBACore::RenderMode3Frame() {
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t vram_off = static_cast<uint32_t>((y * kScreenWidth + x) * 2);
      const uint16_t c = static_cast<uint16_t>(
          static_cast<uint16_t>(vram_[vram_off]) |
          static_cast<uint16_t>(vram_[vram_off + 1] << 8));
      frame_buffer_[y * kScreenWidth + x] = Bgr555ToRgba8888(c);
    }
  }
}

void GBACore::RenderMode4Frame() {
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint32_t page_base = (dispcnt & (1u << 4)) ? 0xA000u : 0u;
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t vram_off = page_base + static_cast<uint32_t>(y * kScreenWidth + x);
      const uint8_t pal_idx = vram_[vram_off];
      const uint32_t pal_off = static_cast<uint32_t>(pal_idx) * 2u;
      const uint16_t c = static_cast<uint16_t>(
          static_cast<uint16_t>(palette_ram_[pal_off & 0x3FFu]) |
          static_cast<uint16_t>(palette_ram_[(pal_off + 1u) & 0x3FFu] << 8));
      frame_buffer_[y * kScreenWidth + x] = Bgr555ToRgba8888(c);
    }
  }
}

void GBACore::RenderMode5Frame() {
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint32_t page_base = (dispcnt & (1u << 4)) ? 0xA000u : 0u;
  constexpr int kMode5Width = 160;
  constexpr int kMode5Height = 128;
  for (int y = 0; y < kMode5Height; ++y) {
    for (int x = 0; x < kMode5Width; ++x) {
      const uint32_t vram_off = page_base + static_cast<uint32_t>((y * kMode5Width + x) * 2);
      const uint16_t c = static_cast<uint16_t>(
          static_cast<uint16_t>(vram_[vram_off]) |
          static_cast<uint16_t>(vram_[vram_off + 1] << 8));
      frame_buffer_[y * kScreenWidth + x] = Bgr555ToRgba8888(c);
    }
  }
}

}  // namespace gba
