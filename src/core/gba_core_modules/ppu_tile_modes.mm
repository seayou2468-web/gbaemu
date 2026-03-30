#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {
namespace {
constexpr uint32_t kBgVramSize = 0x10000u;

uint32_t GetPaletteColor(const std::array<uint8_t, 1024>& palette_ram, uint16_t idx) {
  const size_t off = (static_cast<size_t>(idx) & 0x1FFu) * 2;
  if (off + 1 >= palette_ram.size()) return 0xFF000000u;
  const uint16_t bgr = static_cast<uint16_t>(palette_ram[off]) | (static_cast<uint16_t>(palette_ram[off+1]) << 8);
  return Bgr555ToRgba8888(bgr);
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
  int sx = x, sy = y;
  if (bgcnt & 0x40) {
    int mh = (mosaic_reg & 0xF) + 1;
    int mv = ((mosaic_reg >> 4) & 0xF) + 1;
    sx = (x / mh) * mh; sy = (y / mv) * mv;
  }
  // refx/refy are per-scanline internal origins captured in StepPpu.
  // Applying pb/pd*sy again here double-counts the Y contribution and shifts
  // affine layers (visible in BIOS/logo animations).
  (void)pb;
  (void)pd;
  (void)sy;
  int64_t tx_fp = static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sx;
  int64_t ty_fp = static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sx;
  int tx = static_cast<int>(tx_fp >> 8), ty = static_cast<int>(ty_fp >> 8);

  const int screen_size = (bgcnt >> 14) & 0x3;
  const int size = 128 << screen_size;
  if (bgcnt & 0x2000) { // Wrap
    tx %= size; ty %= size; if (tx < 0) tx += size; if (ty < 0) ty += size;
  } else {
    if (tx < 0 || ty < 0 || tx >= size || ty >= size) return;
  }

  const uint32_t char_base = ((bgcnt >> 2) & 0x3) * 0x4000;
  const uint32_t screen_base = ((bgcnt >> 8) & 0x1F) * 0x800;
  const int tiles_per_row = size / 8;
  const uint32_t map_off = (screen_base + static_cast<uint32_t>(ty / 8) * tiles_per_row + static_cast<uint32_t>(tx / 8)) % kBgVramSize;
  const uint8_t tile = vram[map_off];
  const uint32_t chr_off = (char_base + static_cast<uint32_t>(tile) * 64 + static_cast<uint32_t>(ty % 8) * 8 + static_cast<uint32_t>(tx % 8)) % kBgVramSize;
  const uint8_t color = vram[chr_off];
  if (color) { *out_idx = color; *out_opaque = true; }
}

} // namespace

void GBACore::RenderMode0Frame() {
  const uint32_t backdrop = GetPaletteColor(palette_ram_, 0);
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint16_t winin = ReadIO16(0x04000048), winout = ReadIO16(0x0400004A);
  const uint16_t win0h = ReadIO16(0x04000040), win0v = ReadIO16(0x04000042);
  const uint16_t win1h = ReadIO16(0x04000044), win1v = ReadIO16(0x04000046);
  const uint16_t mosaic_reg = ReadIO16(0x0400004C);

  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& sec_color = BgSecondColorBuffer(); auto& sec_layer = BgSecondLayerBuffer();

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
        uint16_t idx=0; bool opaque=false;
        SampleTextBg(vram_, ReadIO16(0x04000008+bg*2), ReadIO16(0x04000010+bg*4), ReadIO16(0x04000012+bg*4), mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, ReadIO16(0x04000008+bg*2) & 3, static_cast<uint8_t>(bg));
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = h_bg ? GetPaletteColor(palette_ram_, b_idx) : backdrop;
      bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
      sec_color[off] = h_sec ? GetPaletteColor(palette_ram_, s_idx) : backdrop;
      sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode1Frame() {
  const uint32_t backdrop = GetPaletteColor(palette_ram_, 0);
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint16_t winin = ReadIO16(0x04000048), winout = ReadIO16(0x0400004A);
  const uint16_t win0h = ReadIO16(0x04000040), win0v = ReadIO16(0x04000042);
  const uint16_t win1h = ReadIO16(0x04000044), win1v = ReadIO16(0x04000046);
  const uint16_t mosaic_reg = ReadIO16(0x0400004C);

  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& sec_color = BgSecondColorBuffer(); auto& sec_layer = BgSecondLayerBuffer();

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
        uint16_t idx=0; bool opaque=false;
        SampleTextBg(vram_, ReadIO16(0x04000008+bg*2), ReadIO16(0x04000010+bg*4), ReadIO16(0x04000012+bg*4), mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, ReadIO16(0x04000008+bg*2) & 3, static_cast<uint8_t>(bg));
      }
      if ((dispcnt & (1 << 10)) && IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        uint16_t idx=0; bool opaque=false;
        const uint16_t bg2cnt = ReadIO16(0x0400000C);
        const int mosaic_v = ((mosaic_reg >> 4) & 0xF) + 1;
        const int sy = (bg2cnt & 0x40) ? (y / mosaic_v) * mosaic_v : y;
        SampleAffineBg(vram_, bg2cnt, (int16_t)ReadIO16(0x04000020), (int16_t)ReadIO16(0x04000022),
                       (int16_t)ReadIO16(0x04000024), (int16_t)ReadIO16(0x04000026),
                       affine_line_refs_valid_ ? bg2_refx_line_[sy] : static_cast<int32_t>(Read32(0x04000028) << 4) >> 4,
                       affine_line_refs_valid_ ? bg2_refy_line_[sy] : static_cast<int32_t>(Read32(0x0400002C) << 4) >> 4,
                       mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, bg2cnt & 3, 2);
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = h_bg ? GetPaletteColor(palette_ram_, b_idx) : backdrop;
      bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
      sec_color[off] = h_sec ? GetPaletteColor(palette_ram_, s_idx) : backdrop;
      sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode2Frame() {
  const uint32_t backdrop = GetPaletteColor(palette_ram_, 0);
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint16_t winin = ReadIO16(0x04000048), winout = ReadIO16(0x0400004A);
  const uint16_t win0h = ReadIO16(0x04000040), win0v = ReadIO16(0x04000042);
  const uint16_t win1h = ReadIO16(0x04000044), win1v = ReadIO16(0x04000046);
  const uint16_t mosaic_reg = ReadIO16(0x0400004C);

  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& sec_color = BgSecondColorBuffer(); auto& sec_layer = BgSecondLayerBuffer();

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
        const uint16_t bgcnt = ReadIO16(0x04000008+bg*2);
        const int mosaic_v = ((mosaic_reg >> 4) & 0xF) + 1;
        const int sy = (bgcnt & 0x40) ? (y / mosaic_v) * mosaic_v : y;
        SampleAffineBg(vram_, bgcnt, (int16_t)ReadIO16(a_base), (int16_t)ReadIO16(a_base+2),
                       (int16_t)ReadIO16(a_base+4), (int16_t)ReadIO16(a_base+6),
                       affine_line_refs_valid_ ? (bg==2?bg2_refx_line_[sy]:bg3_refx_line_[sy]) : static_cast<int32_t>(Read32(r_base) << 4) >> 4,
                       affine_line_refs_valid_ ? (bg==2?bg2_refy_line_[sy]:bg3_refy_line_[sy]) : static_cast<int32_t>(Read32(r_base+4) << 4) >> 4,
                       mosaic_reg, x, y, &idx, &opaque);
        if (opaque) consider(idx, bgcnt & 3, static_cast<uint8_t>(bg));
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = h_bg ? GetPaletteColor(palette_ram_, b_idx) : backdrop;
      bg_priority[off] = static_cast<uint8_t>(b_prio); bg_layer[off] = b_layer;
      sec_color[off] = h_sec ? GetPaletteColor(palette_ram_, s_idx) : backdrop;
      sec_layer[off] = h_sec ? s_layer : kLayerBackdrop;
    }
  }
}

} // namespace gba
