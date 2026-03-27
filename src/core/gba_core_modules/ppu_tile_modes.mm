#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {

void GBACore::RenderMode0Frame() {
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
    const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const bool mosaic = (bgcnt & (1u << 6)) != 0;
    const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
    const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
    const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
    const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
    const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool color_256 = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int map_w = (screen_size & 1u) ? 64 : 32;
    const int map_h = (screen_size & 2u) ? 64 : 32;
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const int sx = (sample_x + hofs) & (map_w * 8 - 1);
    const int sy = (sample_y + vofs) & (map_h * 8 - 1);
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
      uint8_t best_bg_layer = kLayerBackdrop;
      uint16_t second_idx = 0;
      int second_prio = 4;
      bool have_second = false;
      uint8_t second_bg_layer = kLayerBackdrop;
      for (int bg = 0; bg < 4; ++bg) {
        if ((dispcnt & (1u << (8 + bg))) == 0) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) {
          continue;
        }
        const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
        const int prio = bgcnt & 0x3u;
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(bg, x, y, &idx, &opaque);
        if (!opaque) continue;
        if (!have_bg || prio < best_prio ||
            (prio == best_prio && static_cast<uint8_t>(bg) < best_bg_layer)) {
          if (have_bg) {
            second_prio = best_prio;
            second_idx = best_idx;
            second_bg_layer = best_bg_layer;
            have_second = true;
          }
          best_prio = prio;
          best_idx = idx;
          have_bg = true;
          best_bg_layer = static_cast<uint8_t>(bg);
        } else if (!have_second || prio < second_prio ||
                   (prio == second_prio && static_cast<uint8_t>(bg) < second_bg_layer)) {
          second_prio = prio;
          second_idx = idx;
          second_bg_layer = static_cast<uint8_t>(bg);
          have_second = true;
        }
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = have_bg ? palette_color(best_idx) : backdrop;
      bg_priority[off] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
      bg_layer[off] = have_bg ? best_bg_layer : kLayerBackdrop;
      second_color[off] = have_second ? palette_color(second_idx) : backdrop;
      second_layer[off] = have_second ? second_bg_layer : kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode1Frame() {
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
    const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const bool mosaic = (bgcnt & (1u << 6)) != 0;
    const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
    const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
    const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
    const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
    const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool color_256 = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int map_w = (screen_size & 1u) ? 64 : 32;
    const int map_h = (screen_size & 2u) ? 64 : 32;
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const int sx = (sample_x + hofs) & (map_w * 8 - 1);
    const int sy = (sample_y + vofs) & (map_h * 8 - 1);
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
    const bool mosaic = (bgcnt & (1u << 6)) != 0;
    const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
    const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
    const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
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
      uint32_t raw28 = v & 0x0FFFFFFFu;  // BG2X/BG2Y are signed 28-bit.
      if ((raw28 & 0x08000000u) != 0) raw28 |= 0xF0000000u;
      return static_cast<int32_t>(raw28);
    };
    const int32_t reg_bg2x = read_s32_le(0x04000028u);
    const int32_t reg_bg2y = read_s32_le(0x0400002Cu);

    const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
    const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
    const int32_t bg2x = (affine_line_refs_valid_ && y >= 0 && y < static_cast<int>(mgba_compat::kVideoTotalLines))
      ? bg2_refx_line_[static_cast<size_t>(y)] : reg_bg2x;
    const int32_t bg2y = (affine_line_refs_valid_ && y >= 0 && y < static_cast<int>(mgba_compat::kVideoTotalLines))
      ? bg2_refy_line_[static_cast<size_t>(y)] : reg_bg2y;
    int64_t ref_x = static_cast<int64_t>(bg2x) +
                    static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
    int64_t ref_y = static_cast<int64_t>(bg2y) +
                    static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
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
      uint8_t best_bg_layer = kLayerBackdrop;
      uint16_t second_idx = 0;
      int second_prio = 4;
      bool have_second = false;
      uint8_t second_bg_layer = kLayerBackdrop;

      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!have_bg || prio < best_prio || (prio == best_prio && layer < best_bg_layer)) {
          if (have_bg) {
            second_idx = best_idx;
            second_prio = best_prio;
            second_bg_layer = best_bg_layer;
            have_second = true;
          }
          best_idx = idx;
          best_prio = prio;
          best_bg_layer = layer;
          have_bg = true;
          return;
        }
        if (!have_second || prio < second_prio || (prio == second_prio && layer < second_bg_layer)) {
          second_idx = idx;
          second_prio = prio;
          second_bg_layer = layer;
          have_second = true;
        }
      };

      if ((dispcnt & (1u << 8)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 0, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(0, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x04000008u) & 0x3u;
          consider(idx, prio, kLayerBg0);
        }
      }
      if ((dispcnt & (1u << 9)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 1, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(1, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Au) & 0x3u;
          consider(idx, prio, kLayerBg1);
        }
      }
      if ((dispcnt & (1u << 10)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg2(x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Cu) & 0x3u;
          consider(idx, prio, kLayerBg2);
        }
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = have_bg ? palette_color(best_idx) : backdrop;
      bg_priority[off] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
      bg_layer[off] = have_bg ? best_bg_layer : kLayerBackdrop;
      second_color[off] = have_second ? palette_color(second_idx) : backdrop;
      second_layer[off] = have_second ? second_bg_layer : kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode2Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  struct AffineBgState {
    bool enabled = false;
    bool wrap = false;
    bool mosaic = false;
    uint8_t priority = 4;
    uint8_t layer = kLayerBackdrop;
    uint32_t char_base = 0;
    uint32_t screen_base = 0;
    int mos_h = 1;
    int mos_v = 1;
    int size_px = 128;
    int tiles_per_row = 16;
    int16_t pa = 0;
    int16_t pb = 0;
    int16_t pc = 0;
    int16_t pd = 0;
    int32_t refx = 0;
    int32_t refy = 0;
  };

  auto read_affine_ref28 = [&](uint32_t addr) -> int32_t {
    const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                       (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                       (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                       (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
    uint32_t raw28 = v & 0x0FFFFFFFu;
    if ((raw28 & 0x08000000u) != 0) raw28 |= 0xF0000000u;
    return static_cast<int32_t>(raw28);
  };

  std::array<AffineBgState, 2> affine_bgs{};
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  for (int i = 0; i < 2; ++i) {
    const int bg = 2 + i;
    auto& st = affine_bgs[static_cast<size_t>(i)];
    st.enabled = (dispcnt & (1u << (8 + bg))) != 0;
    st.layer = static_cast<uint8_t>(bg);
    if (!st.enabled) continue;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2u));
    st.priority = static_cast<uint8_t>(bgcnt & 0x3u);
    st.char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    st.screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    st.mosaic = (bgcnt & (1u << 6)) != 0;
    st.wrap = (bgcnt & (1u << 13)) != 0;
    st.mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
    st.mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    st.size_px = 128 << screen_size;
    st.tiles_per_row = st.size_px / 8;

    const uint32_t affine_base = (bg == 2) ? 0x04000020u : 0x04000030u;
    st.pa = static_cast<int16_t>(ReadIO16(affine_base + 0u));
    st.pb = static_cast<int16_t>(ReadIO16(affine_base + 2u));
    st.pc = static_cast<int16_t>(ReadIO16(affine_base + 4u));
    st.pd = static_cast<int16_t>(ReadIO16(affine_base + 6u));
    if (affine_line_refs_valid_) {
      st.refx = (bg == 2) ? bg2_refx_line_[0] : bg3_refx_line_[0];
      st.refy = (bg == 2) ? bg2_refy_line_[0] : bg3_refy_line_[0];
    } else {
      const uint32_t ref_base = (bg == 2) ? 0x04000028u : 0x04000038u;
      st.refx = read_affine_ref28(ref_base);
      st.refy = read_affine_ref28(ref_base + 4u);
    }
  }

  auto sample_affine_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const auto& st = affine_bgs[static_cast<size_t>(bg - 2)];
    if (!st.enabled) return;
    const int sample_x = st.mosaic ? ((x / st.mos_h) * st.mos_h) : x;
    const int sample_y = st.mosaic ? ((y / st.mos_v) * st.mos_v) : y;
    const int32_t base_refx = affine_line_refs_valid_
      ? ((bg == 2) ? bg2_refx_line_[static_cast<size_t>(y)] : bg3_refx_line_[static_cast<size_t>(y)])
      : st.refx;
    const int32_t base_refy = affine_line_refs_valid_
      ? ((bg == 2) ? bg2_refy_line_[static_cast<size_t>(y)] : bg3_refy_line_[static_cast<size_t>(y)])
      : st.refy;
    int64_t tex_x_fp = static_cast<int64_t>(base_refx) +
                       static_cast<int64_t>(st.pa) * sample_x + static_cast<int64_t>(st.pb) * sample_y;
    int64_t tex_y_fp = static_cast<int64_t>(base_refy) +
                       static_cast<int64_t>(st.pc) * sample_x + static_cast<int64_t>(st.pd) * sample_y;
    int tx = static_cast<int>(tex_x_fp >> 8);
    int ty = static_cast<int>(tex_y_fp >> 8);

    if (st.wrap) {
      tx %= st.size_px;
      ty %= st.size_px;
      if (tx < 0) tx += st.size_px;
      if (ty < 0) ty += st.size_px;
    } else if (tx < 0 || ty < 0 || tx >= st.size_px || ty >= st.size_px) {
      return;
    }

    const int tile_x = tx / 8;
    const int tile_y = ty / 8;
    const int pixel_x = tx & 7;
    const int pixel_y = ty & 7;
    const size_t map_off = static_cast<size_t>(st.screen_base + tile_y * st.tiles_per_row + tile_x);
    if (map_off >= vram_.size()) return;
    const uint16_t tile_id = vram_[map_off];
    const size_t chr_off = static_cast<size_t>(st.char_base + tile_id * 64u + pixel_y * 8u + pixel_x);
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
      uint8_t best_bg_layer = kLayerBackdrop;
      uint16_t second_idx = 0;
      int second_prio = 4;
      bool have_second = false;
      uint8_t second_bg_layer = kLayerBackdrop;

      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!have_bg || prio < best_prio || (prio == best_prio && layer < best_bg_layer)) {
          if (have_bg) {
            second_idx = best_idx;
            second_prio = best_prio;
            second_bg_layer = best_bg_layer;
            have_second = true;
          }
          best_idx = idx;
          best_prio = prio;
          best_bg_layer = layer;
          have_bg = true;
          return;
        }
        if (!have_second || prio < second_prio || (prio == second_prio && layer < second_bg_layer)) {
          second_idx = idx;
          second_prio = prio;
          second_bg_layer = layer;
          have_second = true;
        }
      };

      for (int bg = 2; bg <= 3; ++bg) {
        const auto& st = affine_bgs[static_cast<size_t>(bg - 2)];
        if (!st.enabled) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) continue;
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg(bg, x, y, &idx, &opaque);
        if (opaque) {
          consider(idx, st.priority, st.layer);
        }
      }

      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = have_bg ? palette_color(best_idx) : backdrop;
      bg_priority[off] = static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
      bg_layer[off] = have_bg ? best_bg_layer : kLayerBackdrop;
      second_color[off] = have_second ? palette_color(second_idx) : backdrop;
      second_layer[off] = have_second ? second_bg_layer : kLayerBackdrop;
    }
  }
}

}  // namespace gba
