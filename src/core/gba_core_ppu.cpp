#include "gba_core.h"

#include <algorithm>

namespace gba {
namespace {
uint8_t ClampToByteLocal(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}
}  // namespace
void GBACore::RenderMode3Frame() {
  // Mode 3: 240x160 direct color (BGR555) in VRAM.
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t off = static_cast<size_t>((y * kScreenWidth + x) * 2);
      if (off + 1 >= vram_.size()) continue;
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      const uint8_t r5 = static_cast<uint8_t>((bgr555 >> 0) & 0x1F);
      const uint8_t g5 = static_cast<uint8_t>((bgr555 >> 5) & 0x1F);
      const uint8_t b5 = static_cast<uint8_t>((bgr555 >> 10) & 0x1F);
      const uint8_t r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
      const uint8_t g = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
      const uint8_t b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
      frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x] =
          0xFF000000u | (static_cast<uint32_t>(r) << 16) |
          (static_cast<uint32_t>(g) << 8) | b;
    }
  }
}

void GBACore::RenderMode4Frame() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool page1 = (dispcnt & (1u << 4)) != 0;
  const size_t page_base = page1 ? 0xA000u : 0u;

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0xFFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    const uint8_t r = static_cast<uint8_t>(((bgr >> 0) & 0x1Fu) * 255u / 31u);
    const uint8_t g = static_cast<uint8_t>(((bgr >> 5) & 0x1Fu) * 255u / 31u);
    const uint8_t b = static_cast<uint8_t>(((bgr >> 10) & 0x1Fu) * 255u / 31u);
    return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t off = page_base + static_cast<size_t>(y * kScreenWidth + x);
      const uint8_t index = (off < vram_.size()) ? vram_[off] : 0;
      frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x] = palette_color(index);
    }
  }
}

void GBACore::RenderMode5Frame() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool page1 = (dispcnt & (1u << 4)) != 0;
  const size_t page_base = page1 ? 0xA000u : 0u;
  constexpr int kMode5Width = 160;
  constexpr int kMode5Height = 128;
  const uint16_t backdrop_bgr = static_cast<uint16_t>(palette_ram_[0]) |
                                static_cast<uint16_t>(palette_ram_[1] << 8);
  const uint8_t bg_r = static_cast<uint8_t>(((backdrop_bgr >> 0) & 0x1Fu) * 255u / 31u);
  const uint8_t bg_g = static_cast<uint8_t>(((backdrop_bgr >> 5) & 0x1Fu) * 255u / 31u);
  const uint8_t bg_b = static_cast<uint8_t>(((backdrop_bgr >> 10) & 0x1Fu) * 255u / 31u);
  const uint32_t backdrop = 0xFF000000u | (static_cast<uint32_t>(bg_r) << 16) |
                            (static_cast<uint32_t>(bg_g) << 8) | bg_b;

  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);

  for (int y = 0; y < kMode5Height; ++y) {
    for (int x = 0; x < kMode5Width; ++x) {
      const size_t off = page_base + static_cast<size_t>((y * kMode5Width + x) * 2);
      if (off + 1 >= vram_.size()) continue;
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      const uint8_t r5 = static_cast<uint8_t>((bgr555 >> 0) & 0x1F);
      const uint8_t g5 = static_cast<uint8_t>((bgr555 >> 5) & 0x1F);
      const uint8_t b5 = static_cast<uint8_t>((bgr555 >> 10) & 0x1F);
      const uint8_t r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
      const uint8_t g = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
      const uint8_t b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
      frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x] =
          0xFF000000u | (static_cast<uint32_t>(r) << 16) |
          (static_cast<uint32_t>(g) << 8) | b;
    }
  }
}

void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 12)) == 0) return;  // OBJ disable

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},     // square
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},     // horizontal
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},     // vertical
  };
  const bool obj_1d = (dispcnt & (1u << 6)) != 0;

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    const uint8_t r = static_cast<uint8_t>(((bgr >> 0) & 0x1Fu) * 255u / 31u);
    const uint8_t g = static_cast<uint8_t>(((bgr >> 5) & 0x1Fu) * 255u / 31u);
    const uint8_t b = static_cast<uint8_t>(((bgr >> 10) & 0x1Fu) * 255u / 31u);
    return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
  };

  for (int obj = 127; obj >= 0; --obj) {
    const size_t off = static_cast<size_t>(obj * 8);
    if (off + 5 >= oam_.size()) continue;
    const uint16_t attr0 = static_cast<uint16_t>(oam_[off]) |
                           static_cast<uint16_t>(oam_[off + 1] << 8);
    const uint16_t attr1 = static_cast<uint16_t>(oam_[off + 2]) |
                           static_cast<uint16_t>(oam_[off + 3] << 8);
    const uint16_t attr2 = static_cast<uint16_t>(oam_[off + 4]) |
                           static_cast<uint16_t>(oam_[off + 5] << 8);

    const uint16_t obj_mode = (attr0 >> 8) & 0x3u;
    if (obj_mode == 2u) continue;  // OBJ window unsupported
    const bool affine = (attr0 & (1u << 8)) != 0;
    if (affine) continue;  // affine sprite path not yet implemented

    const int shape = (attr0 >> 14) & 0x3;
    const int size = (attr1 >> 14) & 0x3;
    if (shape >= 3) continue;
    const int w = kObjDim[shape][size][0];
    const int h = kObjDim[shape][size][1];

    int y = attr0 & 0xFF;
    int x = attr1 & 0x1FF;
    if (y >= 160) y -= 256;
    if (x >= 240) x -= 512;

    const bool color_256 = (attr0 & (1u << 13)) != 0;
    const bool hflip = (attr1 & (1u << 12)) != 0;
    const bool vflip = (attr1 & (1u << 13)) != 0;
    const uint16_t tile_id = attr2 & 0x03FFu;
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);
    const size_t obj_chr_base = 0x10000u;

    for (int py = 0; py < h; ++py) {
      const int sy = y + py;
      if (sy < 0 || sy >= kScreenHeight) continue;
      const int ty = vflip ? (h - 1 - py) : py;
      for (int px = 0; px < w; ++px) {
        const int sx = x + px;
        if (sx < 0 || sx >= kScreenWidth) continue;
        const int tx = hflip ? (w - 1 - px) : px;

        uint16_t color_index = 0;
        if (color_256) {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 64 +
                                                     in_y * 8 + in_x);
          if (chr_off >= vram_.size()) continue;
          color_index = vram_[chr_off];
        } else {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 32 +
                                                     in_y * 4 + in_x / 2);
          if (chr_off >= vram_.size()) continue;
          const uint8_t packed = vram_[chr_off];
          const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
          color_index = static_cast<uint16_t>(palbank * 16u + nib);
        }
        if ((color_index & 0xFFu) == 0) continue;  // transparent
        frame_buffer_[static_cast<size_t>(sy) * kScreenWidth + sx] = palette_color(color_index);
      }
    }
  }
}

void GBACore::RenderMode0Frame() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    const uint8_t r = static_cast<uint8_t>(((bgr >> 0) & 0x1Fu) * 255u / 31u);
    const uint8_t g = static_cast<uint8_t>(((bgr >> 5) & 0x1Fu) * 255u / 31u);
    const uint8_t b = static_cast<uint8_t>(((bgr >> 10) & 0x1Fu) * 255u / 31u);
    return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
  };

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool color_256 = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int map_w = (screen_size & 1u) ? 64 : 32;
    const int map_h = (screen_size & 2u) ? 64 : 32;
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const int sx = (x + hofs) & (map_w * 8 - 1);
    const int sy = (y + vofs) & (map_h * 8 - 1);
    const int tile_x = sx / 8;
    const int tile_y = sy / 8;
    const int pixel_x = sx & 7;
    const int pixel_y = sy & 7;

    const int sc_x = tile_x / 32;
    const int sc_y = tile_y / 32;
    const int local_x = tile_x & 31;
    const int local_y = tile_y & 31;
    int screenblock = 0;
    switch (screen_size) {
      case 0: screenblock = 0; break;
      case 1: screenblock = sc_x; break;
      case 2: screenblock = sc_y; break;
      case 3: screenblock = sc_y * 2 + sc_x; break;
      default: screenblock = 0; break;
    }

    const size_t se_off = static_cast<size_t>(screen_base + screenblock * 0x800u +
                                              (local_y * 32 + local_x) * 2u);
    if (se_off + 1 >= vram_.size()) return;
    const uint16_t se = static_cast<uint16_t>(vram_[se_off]) |
                        static_cast<uint16_t>(vram_[se_off + 1] << 8);
    const uint16_t tile_id = se & 0x03FFu;
    const bool hflip = (se & (1u << 10)) != 0;
    const bool vflip = (se & (1u << 11)) != 0;
    const uint16_t palbank = static_cast<uint16_t>((se >> 12) & 0xFu);

    const int tx = hflip ? (7 - pixel_x) : pixel_x;
    const int ty = vflip ? (7 - pixel_y) : pixel_y;
    if (color_256) {
      const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + ty * 8u + tx);
      const uint16_t idx = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
      if ((idx & 0xFFu) == 0u) return;
      *out_idx = idx;
      *out_opaque = true;
      return;
    }
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 32u + ty * 4u + tx / 2);
    const uint8_t packed = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
    const uint8_t nibble = (tx & 1) ? (packed >> 4) : (packed & 0x0F);
    if (nibble == 0) return;
    *out_idx = static_cast<uint16_t>(palbank * 16u + nibble);
    *out_opaque = true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_idx = 0;
      int best_prio = 4;
      bool have_bg = false;
      for (int bg = 0; bg < 4; ++bg) {
        if ((dispcnt & (1u << (8 + bg))) == 0) continue;
        const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
        const int prio = bgcnt & 0x3u;
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(bg, x, y, &idx, &opaque);
        if (!opaque) continue;
        if (!have_bg || prio < best_prio) {
          best_prio = prio;
          best_idx = idx;
          have_bg = true;
        }
      }
      frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x] = palette_color(have_bg ? best_idx : 0);
    }
  }
}

void GBACore::RenderMode1Frame() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    const uint8_t r = static_cast<uint8_t>(((bgr >> 0) & 0x1Fu) * 255u / 31u);
    const uint8_t g = static_cast<uint8_t>(((bgr >> 5) & 0x1Fu) * 255u / 31u);
    const uint8_t b = static_cast<uint8_t>(((bgr >> 10) & 0x1Fu) * 255u / 31u);
    return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
  };

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool color_256 = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int map_w = (screen_size & 1u) ? 64 : 32;
    const int map_h = (screen_size & 2u) ? 64 : 32;
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const int sx = (x + hofs) & (map_w * 8 - 1);
    const int sy = (y + vofs) & (map_h * 8 - 1);
    const int tile_x = sx / 8;
    const int tile_y = sy / 8;
    const int pixel_x = sx & 7;
    const int pixel_y = sy & 7;

    const int sc_x = tile_x / 32;
    const int sc_y = tile_y / 32;
    const int local_x = tile_x & 31;
    const int local_y = tile_y & 31;
    int screenblock = 0;
    switch (screen_size) {
      case 0: screenblock = 0; break;
      case 1: screenblock = sc_x; break;
      case 2: screenblock = sc_y; break;
      case 3: screenblock = sc_y * 2 + sc_x; break;
      default: screenblock = 0; break;
    }
    const size_t se_off = static_cast<size_t>(screen_base + screenblock * 0x800u +
                                              (local_y * 32 + local_x) * 2u);
    if (se_off + 1 >= vram_.size()) return;
    const uint16_t se = static_cast<uint16_t>(vram_[se_off]) |
                        static_cast<uint16_t>(vram_[se_off + 1] << 8);
    const uint16_t tile_id = se & 0x03FFu;
    const bool hflip = (se & (1u << 10)) != 0;
    const bool vflip = (se & (1u << 11)) != 0;
    const uint16_t palbank = static_cast<uint16_t>((se >> 12) & 0xFu);
    const int tx = hflip ? (7 - pixel_x) : pixel_x;
    const int ty = vflip ? (7 - pixel_y) : pixel_y;

    if (color_256) {
      const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + ty * 8u + tx);
      const uint16_t idx = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
      if ((idx & 0xFFu) == 0u) return;
      *out_idx = idx;
      *out_opaque = true;
      return;
    }
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 32u + ty * 4u + tx / 2);
    const uint8_t packed = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
    const uint8_t nibble = (tx & 1) ? (packed >> 4) : (packed & 0x0F);
    if (nibble == 0) return;
    *out_idx = static_cast<uint16_t>(palbank * 16u + nibble);
    *out_opaque = true;
  };

  auto sample_affine_bg2 = [&](int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(0x0400000Cu);
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool wrap = (bgcnt & (1u << 13)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int size_px = 128 << screen_size;
    const int tiles_per_row = size_px / 8;

    const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
    const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
    const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
    const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));

    auto read_s32_le = [&](uint32_t addr) -> int32_t {
      const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                         (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                         (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                         (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
      int32_t s = static_cast<int32_t>(v);
      if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
      return s;
    };
    const int32_t bg2x = read_s32_le(0x04000028u);
    const int32_t bg2y = read_s32_le(0x0400002Cu);

    int64_t ref_x = static_cast<int64_t>(bg2x) + static_cast<int64_t>(pa) * x + static_cast<int64_t>(pb) * y;
    int64_t ref_y = static_cast<int64_t>(bg2y) + static_cast<int64_t>(pc) * x + static_cast<int64_t>(pd) * y;
    int tx = static_cast<int>(ref_x >> 8);
    int ty = static_cast<int>(ref_y >> 8);

    if (wrap) {
      tx %= size_px;
      ty %= size_px;
      if (tx < 0) tx += size_px;
      if (ty < 0) ty += size_px;
    } else if (tx < 0 || ty < 0 || tx >= size_px || ty >= size_px) {
      return;
    }

    const int tile_x = tx / 8;
    const int tile_y = ty / 8;
    const int pixel_x = tx & 7;
    const int pixel_y = ty & 7;
    const size_t map_off = static_cast<size_t>(screen_base + tile_y * tiles_per_row + tile_x);
    if (map_off >= vram_.size()) return;
    const uint16_t tile_id = vram_[map_off];
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + pixel_y * 8u + pixel_x);
    if (chr_off >= vram_.size()) return;
    const uint16_t idx = vram_[chr_off];
    if ((idx & 0xFFu) == 0u) return;
    *out_idx = idx;
    *out_opaque = true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_idx = 0;
      int best_prio = 4;
      bool have_bg = false;

      if ((dispcnt & (1u << 8)) != 0) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(0, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x04000008u) & 0x3u;
          best_idx = idx;
          best_prio = prio;
          have_bg = true;
        }
      }
      if ((dispcnt & (1u << 9)) != 0) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(1, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Au) & 0x3u;
          if (!have_bg || prio < best_prio) {
            best_idx = idx;
            best_prio = prio;
            have_bg = true;
          }
        }
      }
      if ((dispcnt & (1u << 10)) != 0) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg2(x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Cu) & 0x3u;
          if (!have_bg || prio < best_prio) {
            best_idx = idx;
            best_prio = prio;
            have_bg = true;
          }
        }
      }
      frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x] = palette_color(have_bg ? best_idx : 0);
    }
  }
}

void GBACore::RenderMode2Frame() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    const uint8_t r = static_cast<uint8_t>(((bgr >> 0) & 0x1Fu) * 255u / 31u);
    const uint8_t g = static_cast<uint8_t>(((bgr >> 5) & 0x1Fu) * 255u / 31u);
    const uint8_t b = static_cast<uint8_t>(((bgr >> 10) & 0x1Fu) * 255u / 31u);
    return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
  };

  auto sample_affine_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;

    const uint32_t bgcnt_addr = static_cast<uint32_t>(0x04000008u + bg * 2u);
    const uint16_t bgcnt = ReadIO16(bgcnt_addr);
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool wrap = (bgcnt & (1u << 13)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int size_px = 128 << screen_size;
    const int tiles_per_row = size_px / 8;

    const uint32_t affine_base = (bg == 2) ? 0x04000020u : 0x04000030u;
    const int16_t pa = static_cast<int16_t>(ReadIO16(affine_base + 0u));
    const int16_t pb = static_cast<int16_t>(ReadIO16(affine_base + 2u));
    const int16_t pc = static_cast<int16_t>(ReadIO16(affine_base + 4u));
    const int16_t pd = static_cast<int16_t>(ReadIO16(affine_base + 6u));

    const uint32_t ref_base = (bg == 2) ? 0x04000028u : 0x04000038u;
    auto read_s32_le = [&](uint32_t addr) -> int32_t {
      const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                         (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                         (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                         (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
      int32_t s = static_cast<int32_t>(v);
      if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
      return s;
    };
    const int32_t refx = read_s32_le(ref_base);
    const int32_t refy = read_s32_le(ref_base + 4u);

    int64_t tex_x_fp = static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * x + static_cast<int64_t>(pb) * y;
    int64_t tex_y_fp = static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * x + static_cast<int64_t>(pd) * y;
    int tx = static_cast<int>(tex_x_fp >> 8);
    int ty = static_cast<int>(tex_y_fp >> 8);

    if (wrap) {
      tx %= size_px;
      ty %= size_px;
      if (tx < 0) tx += size_px;
      if (ty < 0) ty += size_px;
    } else if (tx < 0 || ty < 0 || tx >= size_px || ty >= size_px) {
      return;
    }

    const int tile_x = tx / 8;
    const int tile_y = ty / 8;
    const int pixel_x = tx & 7;
    const int pixel_y = ty & 7;
    const size_t map_off = static_cast<size_t>(screen_base + tile_y * tiles_per_row + tile_x);
    if (map_off >= vram_.size()) return;
    const uint16_t tile_id = vram_[map_off];
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + pixel_y * 8u + pixel_x);
    if (chr_off >= vram_.size()) return;
    const uint16_t idx = vram_[chr_off];
    if ((idx & 0xFFu) == 0u) return;

    *out_idx = idx;
    *out_opaque = true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_idx = 0;
      int best_prio = 4;
      bool have_bg = false;

      if ((dispcnt & (1u << 10)) != 0) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg(2, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Cu) & 0x3u;
          best_idx = idx;
          best_prio = prio;
          have_bg = true;
        }
      }
      if ((dispcnt & (1u << 11)) != 0) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg(3, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Eu) & 0x3u;
          if (!have_bg || prio < best_prio) {
            best_idx = idx;
            best_prio = prio;
            have_bg = true;
          }
        }
      }

      frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x] = palette_color(have_bg ? best_idx : 0);
    }
  }
}

void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHBlankStartCycle = 1006u;
  ppu_cycle_accum_ += cycles;
  uint16_t dispstat = ReadIO16(0x04000004u);
  const bool was_hblank = (dispstat & 0x0002u) != 0;
  const bool now_hblank = ppu_cycle_accum_ >= kHBlankStartCycle;
  if (now_hblank) {
    dispstat |= 0x0002u;
  } else {
    dispstat &= static_cast<uint16_t>(~0x0002u);
  }
  if (!was_hblank && now_hblank && (dispstat & (1u << 4))) {
    RaiseInterrupt(1u << 1);  // HBlank IRQ
  }
  WriteIO16(0x04000004u, dispstat);

  while (ppu_cycle_accum_ >= kCyclesPerScanline) {
    ppu_cycle_accum_ -= kCyclesPerScanline;
    uint16_t vcount = ReadIO16(0x04000006u);
    vcount = static_cast<uint16_t>((vcount + 1u) % kTotalScanlines);
    WriteIO16(0x04000006u, vcount);

    dispstat = ReadIO16(0x04000004u);
    const bool was_vblank = (dispstat & 0x0001u) != 0;
    const bool in_vblank = vcount >= kVisibleScanlines;
    if (in_vblank) {
      dispstat |= 0x0001u;
      if (!was_vblank && (dispstat & (1u << 3))) {
        RaiseInterrupt(0x0001u);  // VBlank IRQ
      }
    } else {
      dispstat &= static_cast<uint16_t>(~0x0001u);
    }

    const uint16_t vcount_compare = static_cast<uint16_t>((dispstat >> 8) & 0x00FFu);
    const bool vcount_match = (vcount == vcount_compare);
    if (vcount_match) {
      if ((dispstat & 0x0004u) == 0u && (dispstat & (1u << 5))) {
        RaiseInterrupt(1u << 2);  // VCount IRQ
      }
      dispstat |= 0x0004u;
    } else {
      dispstat &= static_cast<uint16_t>(~0x0004u);
    }

    // New scanline starts outside HBlank.
    dispstat &= static_cast<uint16_t>(~0x0002u);
    WriteIO16(0x04000004u, dispstat);
  }
}

void GBACore::StepTimers(uint32_t cycles) {
  static constexpr uint32_t kPrescalerLut[4] = {1, 64, 256, 1024};
  bool overflowed[4] = {false, false, false, false};
  for (size_t i = 0; i < timers_.size(); ++i) {
    TimerState& t = timers_[i];
    const uint16_t cnt_h = ReadIO16(static_cast<uint32_t>(0x04000102u + i * 4u));
    t.control = cnt_h;
    if ((cnt_h & 0x0080u) == 0) continue;  // disabled
    const bool count_up = (cnt_h & 0x0004u) != 0;

    auto tick_once = [&](bool* ov) {
      const uint16_t old = t.counter;
      t.counter = static_cast<uint16_t>(t.counter + 1u);
      if (t.counter == 0) {
        t.counter = ReadIO16(static_cast<uint32_t>(0x04000100u + i * 4u));
        ConsumeAudioFifoOnTimer(i);
        if (cnt_h & 0x0040u) {
          RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(3u + i)));
        }
        *ov = true;
      }
      if (old == 0xFFFFu) return;
    };

    if (count_up && i > 0) {
      if (overflowed[i - 1]) {
        tick_once(&overflowed[i]);
      }
      WriteIO16(static_cast<uint32_t>(0x04000100u + i * 4u), t.counter);
      continue;
    }

    const uint32_t prescaler = kPrescalerLut[cnt_h & 0x3u];
    t.prescaler_accum += cycles;
    while (t.prescaler_accum >= prescaler) {
      t.prescaler_accum -= prescaler;
      tick_once(&overflowed[i]);
    }
    WriteIO16(static_cast<uint32_t>(0x04000100u + i * 4u), t.counter);
  }
}

void GBACore::StepDma() {
  const uint16_t dispstat = ReadIO16(0x04000004u);
  const bool in_vblank = (dispstat & 0x0001u) != 0;
  const bool in_hblank = (dispstat & 0x0002u) != 0;
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base = static_cast<uint32_t>(0x040000B0u + ch * 12u);
    const uint32_t src = Read32(base + 0u);
    const uint32_t dst = Read32(base + 4u);
    const uint16_t cnt_l = ReadIO16(base + 8u);
    const uint16_t cnt_h = ReadIO16(base + 10u);
    if ((cnt_h & 0x8000u) == 0) continue;
    const uint16_t start_timing = static_cast<uint16_t>((cnt_h >> 12) & 0x3u);
    bool fire_now = false;
    if (start_timing == 0u) fire_now = true;                  // Immediate
    if (start_timing == 1u && in_vblank) fire_now = true;     // VBlank
    if (start_timing == 2u && in_hblank) fire_now = true;     // HBlank
    if (start_timing == 3u && ch == 3) fire_now = true;       // Video capture/special fallback
    if (!fire_now) continue;

    const bool word32 = (cnt_h & (1u << 10)) != 0;
    uint32_t count = cnt_l;
    if (count == 0) count = (ch == 3) ? 0x10000u : 0x4000u;

    const int dst_ctl = (cnt_h >> 5) & 0x3;
    const int src_ctl = (cnt_h >> 7) & 0x3;
    const int step = word32 ? 4 : 2;
    int dst_step = step;
    int src_step = step;
    if (dst_ctl == 1) dst_step = -step;
    if (dst_ctl == 2) dst_step = 0;
    if (src_ctl == 1) src_step = -step;
    if (src_ctl == 2) src_step = 0;

    uint32_t src_cur = src;
    uint32_t dst_cur = dst;
    for (uint32_t n = 0; n < count; ++n) {
      if (word32) {
        Write32(dst_cur, Read32(src_cur));
      } else {
        Write16(dst_cur, Read16(src_cur));
      }
      src_cur = static_cast<uint32_t>(static_cast<int64_t>(src_cur) + src_step);
      dst_cur = static_cast<uint32_t>(static_cast<int64_t>(dst_cur) + dst_step);
    }

    Write32(base + 0u, src_cur);
    Write32(base + 4u, (dst_ctl == 3) ? dst : dst_cur);
    const bool repeat = (cnt_h & (1u << 9)) != 0;
    uint16_t next_cnt_h = cnt_h;
    if (!(repeat && start_timing != 0u)) {
      next_cnt_h = static_cast<uint16_t>(cnt_h & ~0x8000u);
    }
    WriteIO16(base + 10u, next_cnt_h);
    if (cnt_h & (1u << 14)) {
      RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(8u + ch)));
    }
  }
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  if (fifo.size() > 32u) {
    fifo.erase(fifo.begin(), fifo.begin() + static_cast<std::ptrdiff_t>(fifo.size() - 32u));
  }
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer1 = (soundcnt_h & (1u << 10)) != 0;
  const bool fifo_b_timer1 = (soundcnt_h & (1u << 14)) != 0;
  auto pop_fifo = [&](std::vector<uint8_t>* fifo, int16_t* last_sample) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->erase(fifo->begin());
      *last_sample = static_cast<int16_t>(sample);
    } else {
      *last_sample = 0;
    }
  };
  if ((timer_index == 0u && !fifo_a_timer1) || (timer_index == 1u && fifo_a_timer1)) {
    pop_fifo(&fifo_a_, &fifo_a_last_sample_);
  }
  if ((timer_index == 0u && !fifo_b_timer1) || (timer_index == 1u && fifo_b_timer1)) {
    pop_fifo(&fifo_b_, &fifo_b_last_sample_);
  }
}

void GBACore::StepApu(uint32_t cycles) {
  // Lightweight APU model: PSG + FIFO mix.
  const uint16_t soundcnt_x = ReadIO16(0x04000084u);
  const uint16_t soundcnt_l = ReadIO16(0x04000080u);
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const uint16_t master = (soundcnt_x & 0x0080u) ? 1u : 0u;
  if (!master) {
    audio_mix_level_ = 0;
    return;
  }

  auto duty_high_steps = [](uint16_t duty) -> int {
    switch (duty & 0x3u) {
      case 0: return 1;  // 12.5%
      case 1: return 2;  // 25%
      case 2: return 4;  // 50%
      case 3: return 6;  // 75%
      default: return 4;
    }
  };
  auto square_sample = [&](uint32_t* phase, uint16_t freq_reg, uint16_t duty_reg) -> int {
    const uint16_t n = static_cast<uint16_t>(freq_reg & 0x07FFu);
    const uint32_t hz = (2048u > n) ? (131072u / std::max<uint16_t>(1u, static_cast<uint16_t>(2048u - n))) : 0u;
    *phase += hz * std::max<uint32_t>(1u, cycles);
    const int step = static_cast<int>((*phase / 1024u) & 7u);
    const int high = duty_high_steps(static_cast<uint16_t>(duty_reg >> 6));
    return (step < high) ? 48 : -48;
  };

  int psg_mix = 0;
  if (soundcnt_x & 0x0001u) {  // CH1
    const uint16_t nr11 = ReadIO16(0x04000062u);
    const uint16_t nr13 = ReadIO16(0x04000064u);
    const uint16_t nr14 = ReadIO16(0x04000065u);
    const uint16_t freq = static_cast<uint16_t>(nr13 | ((nr14 & 0x7u) << 8));
    psg_mix += square_sample(&apu_phase_sq1_, freq, nr11);
  }
  if (soundcnt_x & 0x0002u) {  // CH2
    const uint16_t nr21 = ReadIO16(0x04000068u);
    const uint16_t nr23 = ReadIO16(0x0400006Cu);
    const uint16_t nr24 = ReadIO16(0x0400006Du);
    const uint16_t freq = static_cast<uint16_t>(nr23 | ((nr24 & 0x7u) << 8));
    psg_mix += square_sample(&apu_phase_sq2_, freq, nr21);
  }
  if (soundcnt_x & 0x0004u) {  // CH3 wave
    const uint16_t nr30 = ReadIO16(0x04000070u);
    const uint16_t nr32 = ReadIO16(0x04000072u);
    if (nr30 & 0x0080u) {
      const uint16_t nr33 = ReadIO16(0x04000074u);
      const uint16_t nr34 = ReadIO16(0x04000075u);
      const uint16_t n = static_cast<uint16_t>(nr33 | ((nr34 & 0x7u) << 8));
      const uint32_t hz = (2048u > n) ? (65536u / std::max<uint16_t>(1u, static_cast<uint16_t>(2048u - n))) : 0u;
      apu_phase_wave_ += hz * std::max<uint32_t>(1u, cycles);
      const uint32_t sample_idx = (apu_phase_wave_ / 2048u) & 31u;
      const size_t wave_off = static_cast<size_t>(sample_idx / 2u);
      const uint8_t packed = (wave_off < 16u) ? io_regs_[0x90 + wave_off] : 0;
      uint8_t sample4 = (sample_idx & 1u) ? (packed & 0x0Fu) : (packed >> 4);
      const uint16_t vol_code = (nr32 >> 5) & 0x3u;
      if (vol_code == 0) sample4 = 0;
      else if (vol_code == 2) sample4 >>= 1;
      else if (vol_code == 3) sample4 >>= 2;
      psg_mix += static_cast<int>(sample4) * 8 - 60;
    }
  }
  if (soundcnt_x & 0x0008u) {  // CH4 noise
    const uint16_t nr43 = ReadIO16(0x04000078u);
    const uint32_t div = (nr43 & 0x7u) == 0 ? 8u : (nr43 & 0x7u) * 16u;
    const uint32_t shift = (nr43 >> 4) & 0xFu;
    const uint32_t period = div << shift;
    for (uint32_t i = 0; i < std::max<uint32_t>(1u, cycles / std::max<uint32_t>(1u, period)); ++i) {
      const uint16_t x = static_cast<uint16_t>((apu_noise_lfsr_ ^ (apu_noise_lfsr_ >> 1)) & 1u);
      apu_noise_lfsr_ = static_cast<uint16_t>((apu_noise_lfsr_ >> 1) | (x << 14));
    }
    psg_mix += (apu_noise_lfsr_ & 1u) ? 28 : -28;
  }

  const int left_vol = (soundcnt_l >> 4) & 0x7;
  const int right_vol = soundcnt_l & 0x7;
  psg_mix = (psg_mix * (left_vol + right_vol + 1)) / 4;

  const int fifo_a_gain = (soundcnt_h & (1u << 2)) ? 2 : 1;
  const int fifo_b_gain = (soundcnt_h & (1u << 3)) ? 2 : 1;
  const int fifo_mix = fifo_a_last_sample_ * fifo_a_gain + fifo_b_last_sample_ * fifo_b_gain;
  const int mixed = psg_mix + fifo_mix + static_cast<int>(cycles / 128u);
  audio_mix_level_ = static_cast<uint16_t>(ClampToByteLocal(mixed) & 0xFFu);
}

void GBACore::SyncKeyInputRegister() {
  const uint16_t active_low = static_cast<uint16_t>((~keys_pressed_mask_) & 0x03FFu);
  const size_t keyinput_off = static_cast<size_t>(0x04000130u - 0x04000000u);
  io_regs_[keyinput_off] = static_cast<uint8_t>(active_low & 0xFFu);
  io_regs_[keyinput_off + 1] = static_cast<uint8_t>((active_low >> 8) & 0x03u);

  const uint16_t keycnt = ReadIO16(0x04000132u);
  if ((keycnt & 0x4000u) == 0) return;  // IRQ disabled
  const uint16_t mask = keycnt & 0x03FFu;
  const bool and_mode = (keycnt & 0x8000u) != 0;
  const uint16_t pressed = static_cast<uint16_t>(keys_pressed_mask_ & 0x03FFu);
  const bool hit = and_mode ? ((pressed & mask) == mask) : ((pressed & mask) != 0);
  if (hit) {
    RaiseInterrupt(1u << 12);  // Keypad interrupt
  }
}

void GBACore::RaiseInterrupt(uint16_t mask) {
  const size_t off = static_cast<size_t>(0x04000202u - 0x04000000u);
  const uint16_t if_reg = static_cast<uint16_t>(io_regs_[off]) |
                          static_cast<uint16_t>(io_regs_[off + 1] << 8);
  const uint16_t next = static_cast<uint16_t>(if_reg | mask);
  io_regs_[off] = static_cast<uint8_t>(next & 0xFF);
  io_regs_[off + 1] = static_cast<uint8_t>((next >> 8) & 0xFF);
}

void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state) {
  const uint32_t old_cpsr = cpu_.cpsr;
  SwitchCpuMode(new_mode & 0x1Fu);
  if (HasSpsr(GetCpuMode())) cpu_.spsr[GetCpuMode()] = old_cpsr;
  cpu_.regs[14] = cpu_.regs[15] + ((old_cpsr & (1u << 5)) ? 2u : 4u);
  cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | (new_mode & 0x1Fu);
  cpu_.active_mode = new_mode & 0x1Fu;
  if (disable_irq) cpu_.cpsr |= (1u << 7);
  if (thumb_state) {
    cpu_.cpsr |= (1u << 5);
    cpu_.regs[15] = vector_addr & ~1u;
  } else {
    cpu_.cpsr &= ~(1u << 5);
    cpu_.regs[15] = vector_addr & ~3u;
  }
}

void GBACore::ServiceInterruptIfNeeded() {
  const uint16_t ime = ReadIO16(0x04000208u) & 0x1u;
  if (ime == 0) return;
  if (cpu_.cpsr & (1u << 7)) return;  // I flag set
  const uint16_t ie = ReadIO16(0x04000200u);
  const uint16_t iflags = ReadIO16(0x04000202u);
  const uint16_t pending = static_cast<uint16_t>(ie & iflags);
  if (pending == 0) return;
  WriteIO16(0x04000202u, pending);
  EnterException(0x00000018u, 0x12u, true, false);  // IRQ mode
}

void GBACore::ApplyColorEffects() {
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint16_t bldy = ReadIO16(0x04000054u);
  const uint32_t mode = (bldcnt >> 6) & 0x3u;
  if (mode == 0u) return;

  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);
  for (uint32_t& px : frame_buffer_) {
    uint8_t r = static_cast<uint8_t>((px >> 16) & 0xFFu);
    uint8_t g = static_cast<uint8_t>((px >> 8) & 0xFFu);
    uint8_t b = static_cast<uint8_t>(px & 0xFFu);
    if (mode == 1u) {  // alpha blend (approximate against backdrop black)
      r = ClampToByteLocal(static_cast<int>((r * eva) / 16u));
      g = ClampToByteLocal(static_cast<int>((g * eva) / 16u));
      b = ClampToByteLocal(static_cast<int>((b * eva) / 16u));
    } else if (mode == 2u) {  // brighten
      r = ClampToByteLocal(static_cast<int>(r + ((255 - r) * evy) / 16u));
      g = ClampToByteLocal(static_cast<int>(g + ((255 - g) * evy) / 16u));
      b = ClampToByteLocal(static_cast<int>(b + ((255 - b) * evy) / 16u));
    } else if (mode == 3u) {  // darken
      r = ClampToByteLocal(static_cast<int>(r - (r * evy) / 16u));
      g = ClampToByteLocal(static_cast<int>(g - (g * evy) / 16u));
      b = ClampToByteLocal(static_cast<int>(b - (b * evy) / 16u));
    }
    px = 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
         (static_cast<uint32_t>(g) << 8) | b;
  }
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 7)) != 0) {
    // Forced blank: display white regardless of BG mode.
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), 0xFFFFFFFFu);
    return;
  }
  const uint16_t bg_mode = dispcnt & 0x7u;
  if (bg_mode == 0u) {
    RenderMode0Frame();
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 1u) {
    RenderMode1Frame();
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 2u) {
    RenderMode2Frame();
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 3u) {
    RenderMode3Frame();
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 4u) {
    RenderMode4Frame();
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 5u) {
    RenderMode5Frame();
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  const uint16_t backdrop_bgr = static_cast<uint16_t>(palette_ram_[0]) |
                                static_cast<uint16_t>(palette_ram_[1] << 8);
  const uint8_t bg_r = static_cast<uint8_t>(((backdrop_bgr >> 0) & 0x1Fu) * 255u / 31u);
  const uint8_t bg_g = static_cast<uint8_t>(((backdrop_bgr >> 5) & 0x1Fu) * 255u / 31u);
  const uint8_t bg_b = static_cast<uint8_t>(((backdrop_bgr >> 10) & 0x1Fu) * 255u / 31u);
  const uint32_t backdrop = 0xFF000000u | (static_cast<uint32_t>(bg_r) << 16) |
                            (static_cast<uint32_t>(bg_g) << 8) | bg_b;
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
}

uint64_t GBACore::ComputeFrameHash() const {
  uint64_t hash = 1469598103934665603ULL;
  constexpr uint64_t kPrime = 1099511628211ULL;

  for (uint32_t px : frame_buffer_) {
    hash ^= px;
    hash *= kPrime;
  }
  hash ^= static_cast<uint64_t>(gameplay_state_.player_x) << 1;
  hash ^= static_cast<uint64_t>(gameplay_state_.player_y) << 9;
  hash ^= static_cast<uint64_t>(gameplay_state_.score) << 17;
  return hash;
}

bool GBACore::ValidateFrameBuffer(std::string* error) const {
  const size_t expected_size = static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight);
  if (frame_buffer_.size() != expected_size) {
    if (error) *error = "Invalid framebuffer size.";
    return false;
  }

  uint32_t first_px = 0;
  bool first_px_set = false;
  bool found_distinct_pixel = false;
  uint32_t row_xor_accum = 0;

  for (int y = 0; y < kScreenHeight; ++y) {
    uint32_t row_hash = 2166136261u;
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if ((px & 0xFF000000u) != 0xFF000000u) {
        if (error) *error = "Found pixel with invalid alpha channel.";
        return false;
      }
      row_hash ^= px;
      row_hash *= 16777619u;
    }

    row_xor_accum ^= row_hash;

    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if (!first_px_set) {
        first_px = px;
        first_px_set = true;
      } else if (px != first_px) {
        found_distinct_pixel = true;
      }
    }
  }

  if (!found_distinct_pixel) {
    if (error) *error = "Framebuffer has no visible variation (all pixels identical).";
    return false;
  }
  if (row_xor_accum == 0u) {
    if (error) *error = "Framebuffer row signatures collapsed unexpectedly.";
    return false;
  }
  return true;
}


}  // namespace gba
