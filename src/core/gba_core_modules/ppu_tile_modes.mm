#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {
namespace {
constexpr uint32_t kBgVramSize = 0x10000u;
inline bool SampleAffineBgAt(const std::array<uint8_t, 96*1024>& vram, uint16_t bgcnt,
                             int tx, int ty, uint16_t* out_idx);
inline bool SampleAffineBgFromCoord(const std::array<uint8_t, 96*1024>& vram, uint16_t bgcnt,
                                    int16_t pa, int16_t pc, int32_t refx, int32_t refy, int sx,
                                    uint16_t* out_idx);

uint32_t GetPaletteColor(const std::array<uint8_t, 1024>& palette_ram, uint16_t idx) {
  const size_t off = (static_cast<size_t>(idx) & 0x1FFu) * 2;
  if (off + 1 >= palette_ram.size()) return 0xFF000000u;
  const uint16_t bgr = static_cast<uint16_t>(palette_ram[off]) | (static_cast<uint16_t>(palette_ram[off+1]) << 8);
  return Bgr555ToRgba8888(bgr);
}

void BuildPaletteCache(const std::array<uint8_t, 1024>& palette_ram, std::array<uint32_t, 512>* out) {
  if (out == nullptr) return;
  for (size_t i = 0; i < out->size(); ++i) {
    const size_t off = i * 2u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram[off]) |
                         (static_cast<uint16_t>(palette_ram[off + 1u]) << 8);
    (*out)[i] = Bgr555ToRgba8888(bgr);
  }
}

void SampleTextBg(const std::array<uint8_t, 96*1024>& vram, uint16_t bgcnt, uint16_t hofs, uint16_t vofs,
                  uint16_t mosaic_reg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
  *out_opaque = false;
  int sx = x, sy = y;
  if (bgcnt & 0x40) {
    int mh = (mosaic_reg & 0xF) + 1;
    int mv = ((mosaic_reg >> 4) & 0xF) + 1;
    sx = (x / mh) * mh; sy = (y / mv) * mv;
  }
  sx = (sx + hofs) & 0x1FF; sy = (sy + vofs) & 0x1FF;

  const uint32_t char_base = ((bgcnt >> 2) & 0x3) * 0x4000;
  const uint32_t screen_base = ((bgcnt >> 8) & 0x1F) * 0x800;
  const int screen_size = (bgcnt >> 14) & 0x3;

  int tx = sx / 8, ty = sy / 8;
  uint32_t map_addr = screen_base;
  if (screen_size == 1) { if (tx >= 32) { map_addr += 0x800; tx -= 32; } }
  else if (screen_size == 2) { if (ty >= 32) { map_addr += 0x800; ty -= 32; } }
  else if (screen_size == 3) {
    if (tx >= 32) { map_addr += 0x800; tx -= 32; }
    if (ty >= 32) { map_addr += 0x1000; ty -= 32; }
  }
  tx &= 31; ty &= 31;
  map_addr += (static_cast<uint32_t>(ty) * 32 + static_cast<uint32_t>(tx)) * 2;
  map_addr %= kBgVramSize;
  if (map_addr + 1 >= kBgVramSize) return;
  const uint16_t info = static_cast<uint16_t>(vram[map_addr]) | (static_cast<uint16_t>(vram[map_addr+1]) << 8);
  const uint16_t tile = info & 0x3FF;
  int px = sx % 8, py = sy % 8;
  if (info & 0x400) px = 7 - px;
  if (info & 0x800) py = 7 - py;

  if (bgcnt & 0x80) { // 8bpp
    const uint32_t off = (char_base + static_cast<uint32_t>(tile) * 64 + static_cast<uint32_t>(py) * 8 + static_cast<uint32_t>(px)) % kBgVramSize;
    const uint8_t color = vram[off];
    if (color) { *out_idx = color; *out_opaque = true; }
  } else { // 4bpp
    const uint32_t off = (char_base + static_cast<uint32_t>(tile) * 32 + static_cast<uint32_t>(py) * 4 + static_cast<uint32_t>(px) / 2) % kBgVramSize;
    const uint8_t val = vram[off];
    const uint8_t color = (px & 1) ? (val >> 4) : (val & 0xF);
    if (color) { *out_idx = ((info >> 12) & 0xF) * 16 + color; *out_opaque = true; }
  }
}

void SampleAffineBg(const std::array<uint8_t, 96*1024>& vram, uint16_t bgcnt,
                    int16_t pa, int16_t pb, int16_t pc, int16_t pd, int32_t refx, int32_t refy,
                    uint16_t mosaic_reg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
  *out_opaque = false;

  int sx = x;
  int sy = y;

  if (bgcnt & 0x40) {
    int mh = (mosaic_reg & 0xF) + 1;
    int mv = ((mosaic_reg >> 4) & 0xF) + 1;
    sx = (x / mh) * mh;
    sy = (y / mv) * mv;
  }

  const int32_t u = refx + static_cast<int32_t>(pa) * sx;
  const int32_t v = refy + static_cast<int32_t>(pc) * sx;

  uint16_t idx = 0;
  if (SampleAffineBgAt(vram, bgcnt, u >> 8, v >> 8, &idx)) {
    *out_idx = idx;
    *out_opaque = true;
  }
}

inline bool SampleAffineBgAt(const std::array<uint8_t, 96*1024>& vram, uint16_t bgcnt,
                             int tx, int ty, uint16_t* out_idx) {
  const int screen_size = (bgcnt >> 14) & 0x3;
  const int size = 128 << screen_size;
  if (bgcnt & 0x2000) {
    tx %= size; ty %= size;
    if (tx < 0) tx += size;
    if (ty < 0) ty += size;
  } else if (tx < 0 || ty < 0 || tx >= size || ty >= size) {
    return false;
  }
  const uint32_t char_base = ((bgcnt >> 2) & 0x3) * 0x4000;
  const uint32_t screen_base = ((bgcnt >> 8) & 0x1F) * 0x800;
  const int tiles_per_row = size / 8;
  uint32_t map_off =
    screen_base +
    static_cast<uint32_t>(ty / 8) * static_cast<uint32_t>(tiles_per_row) +
    static_cast<uint32_t>(tx / 8);

map_off &= 0xFFFF;
  const uint8_t tile = vram[map_off];
  const uint32_t chr_off = (char_base + static_cast<uint32_t>(tile) * 64 +
                            static_cast<uint32_t>(ty & 7) * 8 +
                            static_cast<uint32_t>(tx & 7)) % kBgVramSize;
  const uint8_t color = vram[chr_off];
  if (color == 0u) return false;
  if (out_idx) *out_idx = color;
  return true;
}

inline bool SampleAffineBgFromCoord(const std::array<uint8_t, 96*1024>& vram, uint16_t bgcnt,
                                    int16_t pa, int16_t pc, int32_t refx, int32_t refy, int sx,
                                    uint16_t* out_idx) {
  const int32_t tx_fp = refx + static_cast<int32_t>(pa) * sx;
  const int32_t ty_fp = refy + static_cast<int32_t>(pc) * sx;
  return SampleAffineBgAt(vram, bgcnt, tx_fp >> 8, ty_fp >> 8, out_idx);
}

} // namespace

void GBACore::RenderMode0Frame() {
  std::array<uint32_t, 512> pal_cache{};
  BuildPaletteCache(palette_ram_, &pal_cache);
  const uint32_t backdrop = pal_cache[0];
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint16_t winin = ReadIO16(0x04000048), winout = ReadIO16(0x0400004A);
  const uint16_t win0h = ReadIO16(0x04000040), win0v = ReadIO16(0x04000042);
  const uint16_t win1h = ReadIO16(0x04000044), win1v = ReadIO16(0x04000046);
  const uint16_t mosaic_reg = ReadIO16(0x0400004C);

  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& sec_color = BgSecondColorBuffer(); auto& sec_layer = BgSecondLayerBuffer();
  auto& sec_prio = BgSecondPriorityBuffer();

  for (int y=0; y<kScreenHeight; ++y) {
    for (int x=0; x<kScreenWidth; ++x) {
      uint16_t b_idx = 0; int b_prio = 4; uint8_t b_layer = kLayerBackdrop; bool h_bg = false;
      uint16_t s_idx = 0; int s_prio = 4; uint8_t s_layer = kLayerBackdrop; bool h_sec = false;
      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!h_bg || prio < b_prio || (prio == b_prio && layer < b_layer)) {
          if (h_bg) { s_idx = b_idx; s_prio = b_prio; s_layer = b_layer; h_sec = true; }
          b_idx = idx; b_prio = prio; b_layer = layer; h_bg = true;
        } else if (!h_sec || prio < s_prio || (prio == s_prio && layer < s_layer)) {
          s_idx = idx; s_prio = prio; s_layer = layer; h_sec = true;
        }
      };
      for (int bg=0; bg<4; ++bg) {
        if (!(dispcnt & (1 << (8+bg)))) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) continue;
        const uint16_t bgcnt = bg_scroll_line_valid_ ? bg_cnt_line_[y][bg] : ReadIO16(0x04000008+bg*2);
        uint16_t idx=0; bool opaque=false;
        const uint16_t hofs = bg_scroll_line_valid_ ? bg_hofs_line_[y][bg] : ReadIO16(0x04000010+bg*4);
        const uint16_t vofs = bg_scroll_line_valid_ ? bg_vofs_line_[y][bg] : ReadIO16(0x04000012+bg*4);
        SampleTextBg(vram_, bgcnt, hofs, vofs, mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, bgcnt & 3, static_cast<uint8_t>(bg));
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = h_bg ? pal_cache[static_cast<size_t>(b_idx) & 0x1FFu] : backdrop;
      bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
      sec_color[off] = h_sec ? pal_cache[static_cast<size_t>(s_idx) & 0x1FFu] : backdrop;
      sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
      sec_prio[off] = h_sec ? static_cast<uint8_t>(s_prio) : static_cast<uint8_t>(kBackdropPriority);
    }
  }
}

void GBACore::RenderMode1Frame() {
  std::array<uint32_t, 512> pal_cache{};
  BuildPaletteCache(palette_ram_, &pal_cache);
  const uint32_t backdrop = pal_cache[0];
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint16_t winin = ReadIO16(0x04000048), winout = ReadIO16(0x0400004A);
  const uint16_t win0h = ReadIO16(0x04000040), win0v = ReadIO16(0x04000042);
  const uint16_t win1h = ReadIO16(0x04000044), win1v = ReadIO16(0x04000046);
  const uint16_t mosaic_reg = ReadIO16(0x0400004C);
  const int mosaic_h = (mosaic_reg & 0xF) + 1;

  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& sec_color = BgSecondColorBuffer(); auto& sec_layer = BgSecondLayerBuffer();
  auto& sec_prio = BgSecondPriorityBuffer();

  for (int y=0; y<kScreenHeight; ++y) {
    for (int x=0; x<kScreenWidth; ++x) {
      uint16_t b_idx = 0; int b_prio = 4; uint8_t b_layer = kLayerBackdrop; bool h_bg = false;
      uint16_t s_idx = 0; int s_prio = 4; uint8_t s_layer = kLayerBackdrop; bool h_sec = false;
      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!h_bg || prio < b_prio || (prio == b_prio && layer < b_layer)) {
          if (h_bg) { s_idx = b_idx; s_prio = b_prio; s_layer = b_layer; h_sec = true; }
          b_idx = idx; b_prio = prio; b_layer = layer; h_bg = true;
        } else if (!h_sec || prio < s_prio || (prio == s_prio && layer < s_layer)) {
          s_idx = idx; s_prio = prio; s_layer = layer; h_sec = true;
        }
      };
      for (int bg=0; bg<2; ++bg) {
        if (!(dispcnt & (1 << (8+bg)))) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) continue;
        const uint16_t bgcnt = bg_scroll_line_valid_ ? bg_cnt_line_[y][bg] : ReadIO16(0x04000008+bg*2);
        uint16_t idx=0; bool opaque=false;
        const uint16_t hofs = bg_scroll_line_valid_ ? bg_hofs_line_[y][bg] : ReadIO16(0x04000010+bg*4);
        const uint16_t vofs = bg_scroll_line_valid_ ? bg_vofs_line_[y][bg] : ReadIO16(0x04000012+bg*4);
        SampleTextBg(vram_, bgcnt, hofs, vofs, mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, bgcnt & 3, static_cast<uint8_t>(bg));
      }
      if ((dispcnt & (1 << 10)) && IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        uint16_t idx=0; bool opaque=false;
        const uint16_t bg2cnt = bg_affine_params_line_valid_ ? bg_cnt_line_[y][2] : ReadIO16(0x0400000C);
        const int mosaic_v = ((mosaic_reg >> 4) & 0xF) + 1;
        const int sy = (bg2cnt & 0x40) ? (y / mosaic_v) * mosaic_v : y;
        const int16_t pa = bg_affine_params_line_valid_ ? bg2_affine_line_[sy].pa : static_cast<int16_t>(ReadIO16(0x04000020));
        const int16_t pb = bg_affine_params_line_valid_ ? bg2_affine_line_[sy].pb : static_cast<int16_t>(ReadIO16(0x04000022));
        const int16_t pc = bg_affine_params_line_valid_ ? bg2_affine_line_[sy].pc : static_cast<int16_t>(ReadIO16(0x04000024));
        const int16_t pd = bg_affine_params_line_valid_ ? bg2_affine_line_[sy].pd : static_cast<int16_t>(ReadIO16(0x04000026));
        const int32_t refx = affine_line_refs_valid_
                              ? bg2_refx_line_[sy]
                              : (static_cast<int32_t>(Read32(0x04000028) << 4) >> 4) + static_cast<int32_t>(pb) * sy;
        const int32_t refy = affine_line_refs_valid_
                              ? bg2_refy_line_[sy]
                              : (static_cast<int32_t>(Read32(0x0400002C) << 4) >> 4) + static_cast<int32_t>(pd) * sy;
        SampleAffineBg(vram_, bg2cnt, pa, pb, pc, pd, refx, refy, mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, bg2cnt & 3, 2);
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = h_bg ? pal_cache[static_cast<size_t>(b_idx) & 0x1FFu] : backdrop;
      bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
      sec_color[off] = h_sec ? pal_cache[static_cast<size_t>(s_idx) & 0x1FFu] : backdrop;
      sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
      sec_prio[off] = h_sec ? static_cast<uint8_t>(s_prio) : static_cast<uint8_t>(kBackdropPriority);
    }
  }
}

void GBACore::RenderMode2Frame() {
  std::array<uint32_t, 512> pal_cache{};
  BuildPaletteCache(palette_ram_, &pal_cache);
  const uint32_t backdrop = pal_cache[0];
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint16_t winin = ReadIO16(0x04000048), winout = ReadIO16(0x0400004A);
  const uint16_t win0h = ReadIO16(0x04000040), win0v = ReadIO16(0x04000042);
  const uint16_t win1h = ReadIO16(0x04000044), win1v = ReadIO16(0x04000046);
  const uint16_t mosaic_reg = ReadIO16(0x0400004C);
  const int mosaic_h = (mosaic_reg & 0xF) + 1;

  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& sec_color = BgSecondColorBuffer(); auto& sec_layer = BgSecondLayerBuffer();
  auto& sec_prio = BgSecondPriorityBuffer();
  const bool windows_enabled = (dispcnt & ((1u << 13) | (1u << 14) | (1u << 15))) != 0;

  if (!windows_enabled) {
    const uint16_t bg2cnt_now = bg_affine_params_line_valid_ ? bg_cnt_line_[0][2] : ReadIO16(0x0400000C);
    const uint16_t bg3cnt_now = bg_affine_params_line_valid_ ? bg_cnt_line_[0][3] : ReadIO16(0x0400000E);
    const bool bg2_mosaic = (bg2cnt_now & 0x40u) != 0u;
    const bool bg3_mosaic = (bg3cnt_now & 0x40u) != 0u;
    if (!bg2_mosaic && !bg3_mosaic) {
      for (int y = 0; y < kScreenHeight; ++y) {
        const uint16_t bg2cnt = bg_affine_params_line_valid_ ? bg_cnt_line_[y][2] : ReadIO16(0x0400000C);
        const uint16_t bg3cnt = bg_affine_params_line_valid_ ? bg_cnt_line_[y][3] : ReadIO16(0x0400000E);
        const int16_t pa2 = bg_affine_params_line_valid_ ? bg2_affine_line_[y].pa : static_cast<int16_t>(ReadIO16(0x04000020));
const int16_t pb2 = bg_affine_params_line_valid_ ? bg2_affine_line_[y].pb : static_cast<int16_t>(ReadIO16(0x04000022));
const int16_t pc2 = bg_affine_params_line_valid_ ? bg2_affine_line_[y].pc : static_cast<int16_t>(ReadIO16(0x04000024));
const int16_t pd2 = bg_affine_params_line_valid_ ? bg2_affine_line_[y].pd : static_cast<int16_t>(ReadIO16(0x04000026));
        const int16_t pa3 = bg_affine_params_line_valid_ ? bg3_affine_line_[y].pa : static_cast<int16_t>(ReadIO16(0x04000030));
        const int16_t pc3 = bg_affine_params_line_valid_ ? bg3_affine_line_[y].pc : static_cast<int16_t>(ReadIO16(0x04000034));
        int32_t u2 = affine_line_refs_valid_
                               ? bg2_refx_line_[y]
                               : (static_cast<int32_t>(Read32(0x04000028) << 4) >> 4) + static_cast<int32_t>(pb2) * y;
        int32_t v2 = affine_line_refs_valid_
                               ? bg2_refy_line_[y]
                               : (static_cast<int32_t>(Read32(0x0400002C) << 4) >> 4) + static_cast<int32_t>(pd2) * y;
        const int16_t pb3 = bg_affine_params_line_valid_ ? bg3_affine_line_[y].pb : static_cast<int16_t>(ReadIO16(0x04000032));
        const int16_t pd3 = bg_affine_params_line_valid_ ? bg3_affine_line_[y].pd : static_cast<int16_t>(ReadIO16(0x04000036));
        int32_t u3 = affine_line_refs_valid_
                               ? bg3_refx_line_[y]
                               : (static_cast<int32_t>(Read32(0x04000038) << 4) >> 4) + static_cast<int32_t>(pb3) * y;
        int32_t v3 = affine_line_refs_valid_
                               ? bg3_refy_line_[y]
                               : (static_cast<int32_t>(Read32(0x0400003C) << 4) >> 4) + static_cast<int32_t>(pd3) * y;
        for (int x = 0; x < kScreenWidth; ++x) {
          uint16_t b_idx = 0; int b_prio = 4; uint8_t b_layer = kLayerBackdrop; bool h_bg = false;
          uint16_t s_idx = 0; int s_prio = 4; uint8_t s_layer = kLayerBackdrop; bool h_sec = false;
          auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
            if (!h_bg || prio < b_prio || (prio == b_prio && layer < b_layer)) {
              if (h_bg) { s_idx = b_idx; s_prio = b_prio; s_layer = b_layer; h_sec = true; }
              b_idx = idx; b_prio = prio; b_layer = layer; h_bg = true;
            } else if (!h_sec || prio < s_prio || (prio == s_prio && layer < s_layer)) {
              s_idx = idx; s_prio = prio; s_layer = layer; h_sec = true;
            }
          };
          if (dispcnt & (1u << 10)) {
            uint16_t idx;
            if (SampleAffineBgAt(vram_, bg2cnt, static_cast<int>(u2 >> 8), static_cast<int>(v2 >> 8), &idx)) {
              consider(idx, bg2cnt & 3, 2);
            }
          }
          if (dispcnt & (1u << 11)) {
            uint16_t idx;
            if (SampleAffineBgAt(vram_, bg3cnt, static_cast<int>(u3 >> 8), static_cast<int>(v3 >> 8), &idx)) {
              consider(idx, bg3cnt & 3, 3);
            }
          }
          const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
          frame_buffer_[off] = h_bg ? pal_cache[static_cast<size_t>(b_idx) & 0x1FFu] : backdrop;
          bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
          sec_color[off] = h_sec ? pal_cache[static_cast<size_t>(s_idx) & 0x1FFu] : backdrop;
          sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
          sec_prio[off] = h_sec ? static_cast<uint8_t>(s_prio) : static_cast<uint8_t>(kBackdropPriority);
          u2 += pa2; v2 += pc2; u3 += pa3; v3 += pc3;
        }
      }
      return;
    }
  }

  for (int y=0; y<kScreenHeight; ++y) {
    for (int x=0; x<kScreenWidth; ++x) {
      uint16_t b_idx = 0; int b_prio = 4; uint8_t b_layer = kLayerBackdrop; bool h_bg = false;
      uint16_t s_idx = 0; int s_prio = 4; uint8_t s_layer = kLayerBackdrop; bool h_sec = false;
      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!h_bg || prio < b_prio || (prio == b_prio && layer < b_layer)) {
          if (h_bg) { s_idx = b_idx; s_prio = b_prio; s_layer = b_layer; h_sec = true; }
          b_idx = idx; b_prio = prio; b_layer = layer; h_bg = true;
        } else if (!h_sec || prio < s_prio || (prio == s_prio && layer < s_layer)) {
          s_idx = idx; s_prio = prio; s_layer = layer; h_sec = true;
        }
      };
      for (int bg=2; bg<=3; ++bg) {
        if (!(dispcnt & (1 << (8+bg)))) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) continue;
        uint16_t idx=0; bool opaque=false;
        const uint32_t a_base = (bg==2)?0x04000020:0x04000030;
        const uint32_t r_base = (bg==2)?0x04000028:0x04000038;
        const uint16_t bgcnt = bg_affine_params_line_valid_ ? bg_cnt_line_[y][bg] : ReadIO16(0x04000008+bg*2);
        const int mosaic_v = ((mosaic_reg >> 4) & 0xF) + 1;
        const int sy = (bgcnt & 0x40) ? (y / mosaic_v) * mosaic_v : y;
        const int16_t pa = bg_affine_params_line_valid_
                               ? (bg==2 ? bg2_affine_line_[sy].pa : bg3_affine_line_[sy].pa)
                               : static_cast<int16_t>(ReadIO16(a_base));
        const int16_t pb = bg_affine_params_line_valid_
                               ? (bg==2 ? bg2_affine_line_[sy].pb : bg3_affine_line_[sy].pb)
                               : static_cast<int16_t>(ReadIO16(a_base+2));
        const int16_t pc = bg_affine_params_line_valid_
                               ? (bg==2 ? bg2_affine_line_[sy].pc : bg3_affine_line_[sy].pc)
                               : static_cast<int16_t>(ReadIO16(a_base+4));
        const int16_t pd = bg_affine_params_line_valid_
                               ? (bg==2 ? bg2_affine_line_[sy].pd : bg3_affine_line_[sy].pd)
                               : static_cast<int16_t>(ReadIO16(a_base+6));
        const int32_t refx = affine_line_refs_valid_
                                 ? (bg == 2 ? bg2_refx_line_[sy] : bg3_refx_line_[sy])
                                 : (static_cast<int32_t>(Read32(r_base) << 4) >> 4) + static_cast<int32_t>(pb) * sy;
        const int32_t refy = affine_line_refs_valid_
                                 ? (bg == 2 ? bg2_refy_line_[sy] : bg3_refy_line_[sy])
                                 : (static_cast<int32_t>(Read32(r_base + 4) << 4) >> 4) + static_cast<int32_t>(pd) * sy;
        const int sx = (bgcnt & 0x40) ? (x / mosaic_h) * mosaic_h : x;
        if (SampleAffineBgFromCoord(vram_, bgcnt, pa, pc, refx, refy, sx, &idx)) {
          opaque = true;
        }
        if (opaque) consider(idx, bgcnt & 3, static_cast<uint8_t>(bg));
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = h_bg ? pal_cache[static_cast<size_t>(b_idx) & 0x1FFu] : backdrop;
      bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
      sec_color[off] = h_sec ? pal_cache[static_cast<size_t>(s_idx) & 0x1FFu] : backdrop;
      sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
      sec_prio[off] = h_sec ? static_cast<uint8_t>(s_prio) : static_cast<uint8_t>(kBackdropPriority);
    }
  }
}

} // namespace gba
