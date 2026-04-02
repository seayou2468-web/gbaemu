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

inline uint16_t ReadLe16(const std::array<uint8_t, 96 * 1024>& vram, uint32_t off) {
  return static_cast<uint16_t>(
      static_cast<uint16_t>(vram[off % vram.size()]) |
      static_cast<uint16_t>(vram[(off + 1u) % vram.size()] << 8));
}

inline int16_t ReadIoS16(const std::array<uint8_t, 1024>& io, uint32_t off) {
  const uint16_t raw = static_cast<uint16_t>(
      static_cast<uint16_t>(io[off & 0x3FFu]) |
      static_cast<uint16_t>(io[(off + 1u) & 0x3FFu] << 8));
  return static_cast<int16_t>(raw);
}

inline int32_t ReadIoS28_8(const std::array<uint8_t, 1024>& io, uint32_t off) {
  uint32_t raw = static_cast<uint32_t>(io[off & 0x3FFu]) |
      (static_cast<uint32_t>(io[(off + 1u) & 0x3FFu]) << 8) |
      (static_cast<uint32_t>(io[(off + 2u) & 0x3FFu]) << 16) |
      (static_cast<uint32_t>(io[(off + 3u) & 0x3FFu]) << 24);
  raw &= 0x0FFFFFFFu;
  if (raw & 0x08000000u) raw |= 0xF0000000u;
  return static_cast<int32_t>(raw);
}
}  // namespace

void GBACore::RenderMode0Frame() {
  const uint16_t backdrop = static_cast<uint16_t>(
      static_cast<uint16_t>(palette_ram_[0]) |
      static_cast<uint16_t>(palette_ram_[1] << 8));
  frame_buffer_.assign(kScreenWidth * kScreenHeight, Bgr555ToRgba8888(backdrop));
  const uint16_t dispcnt = ReadIO16(0x04000000u);

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_color, uint8_t* out_priority) -> bool {
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const uint32_t char_base = static_cast<uint32_t>((bgcnt >> 2) & 0x3u) * 0x4000u;
    const uint32_t screen_base = static_cast<uint32_t>((bgcnt >> 8) & 0x1Fu) * 0x800u;
    const bool is_8bpp = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = static_cast<uint32_t>((bgcnt >> 14) & 0x3u);
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const uint32_t bg_width = (screen_size & 1u) ? 512u : 256u;
    const uint32_t bg_height = (screen_size & 2u) ? 512u : 256u;
    const uint32_t screen_blocks_per_row = (bg_width == 512u) ? 2u : 1u;
    const uint32_t sx = (static_cast<uint32_t>(x) + hofs) % bg_width;
    const uint32_t sy = (static_cast<uint32_t>(y) + vofs) % bg_height;

    const uint32_t tile_x = sx / 8u;
    const uint32_t tile_y = sy / 8u;
    const uint32_t in_tile_x = sx & 7u;
    const uint32_t in_tile_y = sy & 7u;
    const uint32_t screen_block = (tile_x / 32u) + (tile_y / 32u) * screen_blocks_per_row;
    const uint32_t se_idx = (tile_y % 32u) * 32u + (tile_x % 32u);
    const uint32_t se_addr = screen_base + screen_block * 0x800u + se_idx * 2u;
    const uint16_t se = ReadLe16(vram_, se_addr);

    const uint32_t tile_idx = se & 0x03FFu;
    const bool hflip = (se & (1u << 10)) != 0;
    const bool vflip = (se & (1u << 11)) != 0;
    const uint32_t pal_bank = (se >> 12) & 0xFu;
    const uint32_t px = hflip ? (7u - in_tile_x) : in_tile_x;
    const uint32_t py = vflip ? (7u - in_tile_y) : in_tile_y;

    if (is_8bpp) {
      const uint32_t tile_addr = char_base + tile_idx * 64u + py * 8u + px;
      const uint8_t pal_idx = vram_[tile_addr % vram_.size()];
      if (pal_idx == 0) return false;
      const uint32_t pal_off = static_cast<uint32_t>(pal_idx) * 2u;
      *out_color = static_cast<uint16_t>(
          static_cast<uint16_t>(palette_ram_[pal_off & 0x3FFu]) |
          static_cast<uint16_t>(palette_ram_[(pal_off + 1u) & 0x3FFu] << 8));
    } else {
      const uint32_t tile_addr = char_base + tile_idx * 32u + py * 4u + (px / 2u);
      const uint8_t packed = vram_[tile_addr % vram_.size()];
      const uint8_t pal_idx = static_cast<uint8_t>((px & 1u) ? (packed >> 4) : (packed & 0x0Fu));
      if (pal_idx == 0) return false;
      const uint32_t final_idx = pal_bank * 16u + pal_idx;
      const uint32_t pal_off = final_idx * 2u;
      *out_color = static_cast<uint16_t>(
          static_cast<uint16_t>(palette_ram_[pal_off & 0x3FFu]) |
          static_cast<uint16_t>(palette_ram_[(pal_off + 1u) & 0x3FFu] << 8));
    }
    *out_priority = static_cast<uint8_t>(bgcnt & 0x3u);
    return true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_color = backdrop;
      uint8_t best_prio = 4;
      for (int bg = 0; bg < 4; ++bg) {
        if ((dispcnt & (1u << (8 + bg))) == 0) continue;
        uint16_t c = 0;
        uint8_t p = 0;
        if (sample_text_bg(bg, x, y, &c, &p)) {
          if (p < best_prio || (p == best_prio && bg < 3)) {
            best_prio = p;
            best_color = c;
          }
        }
      }
      frame_buffer_[y * kScreenWidth + x] = Bgr555ToRgba8888(best_color);
    }
  }
}

void GBACore::RenderMode1Frame() {
  RenderMode0Frame();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 10)) == 0) return;  // BG2 disabled

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint8_t bg2prio = static_cast<uint8_t>(bg2cnt & 0x3u);
  const uint32_t char_base = static_cast<uint32_t>((bg2cnt >> 2) & 0x3u) * 0x4000u;
  const uint32_t screen_base = static_cast<uint32_t>((bg2cnt >> 8) & 0x1Fu) * 0x800u;
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const uint32_t size_sel = static_cast<uint32_t>((bg2cnt >> 14) & 0x3u);
  const uint32_t size = 128u << size_sel;
  const uint32_t map_dim = size / 8u;

  const int32_t pa = ReadIoS16(io_regs_, 0x20u);
  const int32_t pb = ReadIoS16(io_regs_, 0x22u);
  const int32_t pc = ReadIoS16(io_regs_, 0x24u);
  const int32_t pd = ReadIoS16(io_regs_, 0x26u);
  const int32_t refx = ReadIoS28_8(io_regs_, 0x28u);
  const int32_t refy = ReadIoS28_8(io_regs_, 0x2Cu);

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const int32_t src_x = (refx + pa * x + pb * y) >> 8;
      const int32_t src_y = (refy + pc * x + pd * y) >> 8;
      int32_t tx = src_x;
      int32_t ty = src_y;
      if (wrap) {
        const int32_t s = static_cast<int32_t>(size);
        tx = ((tx % s) + s) % s;
        ty = ((ty % s) + s) % s;
      } else if (tx < 0 || ty < 0 || tx >= static_cast<int32_t>(size) || ty >= static_cast<int32_t>(size)) {
        continue;
      }

      const uint32_t tile_x = static_cast<uint32_t>(tx) / 8u;
      const uint32_t tile_y = static_cast<uint32_t>(ty) / 8u;
      const uint32_t in_tile_x = static_cast<uint32_t>(tx) & 7u;
      const uint32_t in_tile_y = static_cast<uint32_t>(ty) & 7u;
      const uint32_t map_idx = tile_y * map_dim + tile_x;
      const uint8_t tile_idx = vram_[(screen_base + map_idx) % vram_.size()];
      const uint32_t tile_addr = char_base + static_cast<uint32_t>(tile_idx) * 64u + in_tile_y * 8u + in_tile_x;
      const uint8_t pal_idx = vram_[tile_addr % vram_.size()];
      if (pal_idx == 0) continue;
      const uint32_t pal_off = static_cast<uint32_t>(pal_idx) * 2u;
      const uint16_t color = static_cast<uint16_t>(
          static_cast<uint16_t>(palette_ram_[pal_off & 0x3FFu]) |
          static_cast<uint16_t>(palette_ram_[(pal_off + 1u) & 0x3FFu] << 8));
      // Cheap priority resolve against existing pixel: only overwrite backdrop/text lower-priority.
      if (bg2prio <= 1) {
        frame_buffer_[y * kScreenWidth + x] = Bgr555ToRgba8888(color);
      }
    }
  }
}

void GBACore::RenderMode2Frame() {
  const uint16_t backdrop = static_cast<uint16_t>(
      static_cast<uint16_t>(palette_ram_[0]) |
      static_cast<uint16_t>(palette_ram_[1] << 8));
  frame_buffer_.assign(kScreenWidth * kScreenHeight, Bgr555ToRgba8888(backdrop));
  const uint16_t dispcnt = ReadIO16(0x04000000u);

  auto render_affine_bg = [&](int bg, uint32_t pa_off, uint32_t pb_off, uint32_t pc_off, uint32_t pd_off,
                              uint32_t x_off, uint32_t y_off) {
    if ((dispcnt & (1u << (8 + bg))) == 0) return;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const uint32_t char_base = static_cast<uint32_t>((bgcnt >> 2) & 0x3u) * 0x4000u;
    const uint32_t screen_base = static_cast<uint32_t>((bgcnt >> 8) & 0x1Fu) * 0x800u;
    const bool wrap = (bgcnt & (1u << 13)) != 0;
    const uint32_t size_sel = static_cast<uint32_t>((bgcnt >> 14) & 0x3u);
    const uint32_t size = 128u << size_sel;
    const uint32_t map_dim = size / 8u;

    const int32_t pa = ReadIoS16(io_regs_, pa_off);
    const int32_t pb = ReadIoS16(io_regs_, pb_off);
    const int32_t pc = ReadIoS16(io_regs_, pc_off);
    const int32_t pd = ReadIoS16(io_regs_, pd_off);
    const int32_t refx = ReadIoS28_8(io_regs_, x_off);
    const int32_t refy = ReadIoS28_8(io_regs_, y_off);

    for (int y = 0; y < kScreenHeight; ++y) {
      for (int x = 0; x < kScreenWidth; ++x) {
        const int32_t src_x = (refx + pa * x + pb * y) >> 8;
        const int32_t src_y = (refy + pc * x + pd * y) >> 8;
        int32_t tx = src_x;
        int32_t ty = src_y;
        if (wrap) {
          const int32_t s = static_cast<int32_t>(size);
          tx = ((tx % s) + s) % s;
          ty = ((ty % s) + s) % s;
        } else if (tx < 0 || ty < 0 || tx >= static_cast<int32_t>(size) || ty >= static_cast<int32_t>(size)) {
          continue;
        }
        const uint32_t tile_x = static_cast<uint32_t>(tx) / 8u;
        const uint32_t tile_y = static_cast<uint32_t>(ty) / 8u;
        const uint32_t in_tile_x = static_cast<uint32_t>(tx) & 7u;
        const uint32_t in_tile_y = static_cast<uint32_t>(ty) & 7u;
        const uint32_t map_idx = tile_y * map_dim + tile_x;
        const uint8_t tile_idx = vram_[(screen_base + map_idx) % vram_.size()];
        const uint32_t tile_addr = char_base + static_cast<uint32_t>(tile_idx) * 64u + in_tile_y * 8u + in_tile_x;
        const uint8_t pal_idx = vram_[tile_addr % vram_.size()];
        if (pal_idx == 0) continue;
        const uint32_t pal_off = static_cast<uint32_t>(pal_idx) * 2u;
        const uint16_t color = static_cast<uint16_t>(
            static_cast<uint16_t>(palette_ram_[pal_off & 0x3FFu]) |
            static_cast<uint16_t>(palette_ram_[(pal_off + 1u) & 0x3FFu] << 8));
        frame_buffer_[y * kScreenWidth + x] = Bgr555ToRgba8888(color);
      }
    }
  };

  render_affine_bg(2, 0x20u, 0x22u, 0x24u, 0x26u, 0x28u, 0x2Cu);
  render_affine_bg(3, 0x30u, 0x32u, 0x34u, 0x36u, 0x38u, 0x3Cu);
}

}  // namespace gba
