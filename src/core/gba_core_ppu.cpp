#include "gba_core.h"

#include <algorithm>

namespace gba {
namespace {
uint8_t ClampToByteLocal(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}

constexpr int kBackdropPriority = 4;

std::vector<uint8_t>& BgPriorityBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

void EnsureBgPriorityBufferSize() {
  auto& buffer = BgPriorityBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, static_cast<uint8_t>(kBackdropPriority));
  }
}

std::vector<uint8_t>& ObjWindowMaskBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

void EnsureObjWindowMaskBufferSize() {
  auto& buffer = ObjWindowMaskBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

uint32_t Bgr555ToRgba8888(uint16_t bgr) {
  const uint8_t r5 = static_cast<uint8_t>((bgr >> 0) & 0x1F);
  const uint8_t g5 = static_cast<uint8_t>((bgr >> 5) & 0x1F);
  const uint8_t b5 = static_cast<uint8_t>((bgr >> 10) & 0x1F);
  const uint8_t r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
  const uint8_t g = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
  const uint8_t b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
  return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
         (static_cast<uint32_t>(g) << 8) | b;
}

uint16_t ReadBackdropBgr(const std::array<uint8_t, 1024>& palette_ram) {
  return static_cast<uint16_t>(palette_ram[0]) |
         static_cast<uint16_t>(palette_ram[1] << 8);
}

bool IsWithinWindowAxis(int p, int start, int end) {
  // On GBA, equal start/end is commonly treated as full range by software
  // relying on window registers as pass-through defaults.
  if (start == end) return true;
  if (start < end) return p >= start && p < end;
  return p >= start || p < end;
}

uint8_t ResolveWindowControl(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                         uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                         const std::vector<uint8_t>& obj_window_mask,
                         int x, int y) {
  const bool win0_enabled = (dispcnt & (1u << 13)) != 0;
  const bool win1_enabled = (dispcnt & (1u << 14)) != 0;
  const bool objwin_enabled = (dispcnt & (1u << 15)) != 0;
  if (!win0_enabled && !win1_enabled && !objwin_enabled) return 0x3Fu;

  const int win0_l = std::min<int>(240, (win0h >> 8) & 0xFFu);
  const int win0_r = std::min<int>(240, win0h & 0xFFu);
  const int win0_t = std::min<int>(160, (win0v >> 8) & 0xFFu);
  const int win0_b = std::min<int>(160, win0v & 0xFFu);
  const int win1_l = std::min<int>(240, (win1h >> 8) & 0xFFu);
  const int win1_r = std::min<int>(240, win1h & 0xFFu);
  const int win1_t = std::min<int>(160, (win1v >> 8) & 0xFFu);
  const int win1_b = std::min<int>(160, win1v & 0xFFu);

  const bool in_win0 = win0_enabled && IsWithinWindowAxis(x, win0_l, win0_r) &&
                       IsWithinWindowAxis(y, win0_t, win0_b);
  const bool in_win1 = win1_enabled && IsWithinWindowAxis(x, win1_l, win1_r) &&
                       IsWithinWindowAxis(y, win1_t, win1_b);

  uint8_t control = static_cast<uint8_t>(winout & 0xFFu);  // outside window
  if (in_win0) control = static_cast<uint8_t>(winin & 0xFFu);
  else if (in_win1) control = static_cast<uint8_t>((winin >> 8) & 0xFFu);
  else if (objwin_enabled) {
    const size_t off = static_cast<size_t>(y) * GBACore::kScreenWidth + x;
    if (off < obj_window_mask.size() && obj_window_mask[off] != 0) {
      control = static_cast<uint8_t>((winout >> 8) & 0x3Fu);
    }
  }
  return control;
}

bool IsBgVisibleByWindow(uint8_t control, int bg) {
  return (control & (1u << bg)) != 0;
}

bool IsBgVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                         uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                         int bg, int x, int y) {
  const uint8_t control =
      ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
  return IsBgVisibleByWindow(control, bg);
}

bool IsObjVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                          uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                          int x, int y) {
  const uint8_t control = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v,
                                               ObjWindowMaskBuffer(), x, y);
  return (control & (1u << 4)) != 0;
}
}  // namespace
void GBACore::RenderMode3Frame() {
  // Mode 3: 240x160 direct color (BGR555) in VRAM.
  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(ReadIO16(0x0400000Cu) & 0x3u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
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
  const int32_t refx = read_s32_le(0x04000028u);
  const int32_t refy = read_s32_le(0x0400002Cu);

  if (!bg2_enabled) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
    std::fill(bg_priority.begin(), bg_priority.end(), static_cast<uint8_t>(kBackdropPriority));
    return;
  }

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        continue;
      }
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * x + static_cast<int64_t>(pb) * y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * x + static_cast<int64_t>(pd) * y;
      const int sx = static_cast<int>(tex_x_fp >> 8);
      const int sy = static_cast<int>(tex_y_fp >> 8);
      if (sx < 0 || sy < 0 || sx >= kScreenWidth || sy >= kScreenHeight) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        continue;
      }
      const size_t off = static_cast<size_t>((sy * kScreenWidth + sx) * 2);
      if (off + 1 >= vram_.size()) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        continue;
      }
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr555);
      bg_priority[fb_off] = bg2_priority;
    }
  }
}

void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(ReadIO16(0x0400000Cu) & 0x3u);
  const bool page1 = (dispcnt & (1u << 4)) != 0;
  const size_t page_base = page1 ? 0xA000u : 0u;
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
  const int32_t refx = read_s32_le(0x04000028u);
  const int32_t refy = read_s32_le(0x0400002Cu);

  const uint16_t backdrop_bgr = ReadBackdropBgr(palette_ram_);
  const uint32_t backdrop = Bgr555ToRgba8888(backdrop_bgr);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0xFFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return backdrop;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  if (!bg2_enabled) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
    std::fill(bg_priority.begin(), bg_priority.end(), static_cast<uint8_t>(kBackdropPriority));
    return;
  }

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        continue;
      }
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * x + static_cast<int64_t>(pb) * y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * x + static_cast<int64_t>(pd) * y;
      const int sx = static_cast<int>(tex_x_fp >> 8);
      const int sy = static_cast<int>(tex_y_fp >> 8);
      if (sx < 0 || sy < 0 || sx >= kScreenWidth || sy >= kScreenHeight) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        continue;
      }
      const size_t off = page_base + static_cast<size_t>(sy * kScreenWidth + sx);
      const uint8_t index = (off < vram_.size()) ? vram_[off] : 0;
      frame_buffer_[fb_off] = palette_color(index);
      bg_priority[fb_off] = bg2_priority;
    }
  }
}

void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(ReadIO16(0x0400000Cu) & 0x3u);
  const bool page1 = (dispcnt & (1u << 4)) != 0;
  const size_t page_base = page1 ? 0xA000u : 0u;
  constexpr int kMode5Width = 160;
  constexpr int kMode5Height = 128;
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
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
  const int32_t refx = read_s32_le(0x04000028u);
  const int32_t refy = read_s32_le(0x0400002Cu);

  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  std::fill(bg_priority.begin(), bg_priority.end(), static_cast<uint8_t>(kBackdropPriority));

  if (!bg2_enabled) return;

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        continue;
      }
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * x + static_cast<int64_t>(pb) * y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * x + static_cast<int64_t>(pd) * y;
      const int sx = static_cast<int>(tex_x_fp >> 8);
      const int sy = static_cast<int>(tex_y_fp >> 8);
      if (sx < 0 || sy < 0 || sx >= kMode5Width || sy >= kMode5Height) continue;
      const size_t off = page_base + static_cast<size_t>((sy * kMode5Width + sx) * 2);
      if (off + 1 >= vram_.size()) continue;
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr555);
      bg_priority[fb_off] = bg2_priority;
    }
  }
}

void GBACore::BuildObjWindowMask() {
  EnsureObjWindowMaskBufferSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 15)) == 0 || (dispcnt & (1u << 12)) == 0) return;

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},
  };
  const bool obj_1d = (dispcnt & (1u << 6)) != 0;
  auto& mask = ObjWindowMaskBuffer();

  for (int obj = 127; obj >= 0; --obj) {
    const size_t off = static_cast<size_t>(obj * 8);
    if (off + 5 >= oam_.size()) continue;
    const uint16_t attr0 = static_cast<uint16_t>(oam_[off]) |
                           static_cast<uint16_t>(oam_[off + 1] << 8);
    const uint16_t attr1 = static_cast<uint16_t>(oam_[off + 2]) |
                           static_cast<uint16_t>(oam_[off + 3] << 8);
    const uint16_t attr2 = static_cast<uint16_t>(oam_[off + 4]) |
                           static_cast<uint16_t>(oam_[off + 5] << 8);
    if (((attr0 >> 8) & 0x3u) != 2u) continue;  // OBJ window

    const bool affine = (attr0 & (1u << 8)) != 0;
    const bool double_size = affine && ((attr0 & (1u << 9)) != 0);
    const int shape = (attr0 >> 14) & 0x3;
    const int size = (attr1 >> 14) & 0x3;
    if (shape >= 3) continue;
    const int src_w = kObjDim[shape][size][0];
    const int src_h = kObjDim[shape][size][1];
    const int draw_w = double_size ? (src_w * 2) : src_w;
    const int draw_h = double_size ? (src_h * 2) : src_h;

    int y = attr0 & 0xFF;
    int x = attr1 & 0x1FF;
    if (y >= 160) y -= 256;
    if (x >= 240) x -= 512;

    const bool color_256 = (attr0 & (1u << 13)) != 0;
    const bool mosaic = (attr0 & (1u << 12)) != 0;
    const bool hflip = (attr1 & (1u << 12)) != 0;
    const bool vflip = (attr1 & (1u << 13)) != 0;
    const uint16_t tile_id = attr2 & 0x03FFu;
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);
    const size_t obj_chr_base = 0x10000u;

    int16_t pa = 0, pb = 0, pc = 0, pd = 0;
    if (affine) {
      const uint16_t affine_idx = static_cast<uint16_t>((attr1 >> 9) & 0x1Fu);
      const size_t pa_off = static_cast<size_t>(affine_idx) * 0x20u + 0x06u;
      const size_t pb_off = static_cast<size_t>(affine_idx) * 0x20u + 0x0Eu;
      const size_t pc_off = static_cast<size_t>(affine_idx) * 0x20u + 0x16u;
      const size_t pd_off = static_cast<size_t>(affine_idx) * 0x20u + 0x1Eu;
      if (pd_off + 1 >= oam_.size()) continue;
      pa = static_cast<int16_t>(static_cast<uint16_t>(oam_[pa_off]) |
                                static_cast<uint16_t>(oam_[pa_off + 1] << 8));
      pb = static_cast<int16_t>(static_cast<uint16_t>(oam_[pb_off]) |
                                static_cast<uint16_t>(oam_[pb_off + 1] << 8));
      pc = static_cast<int16_t>(static_cast<uint16_t>(oam_[pc_off]) |
                                static_cast<uint16_t>(oam_[pc_off + 1] << 8));
      pd = static_cast<int16_t>(static_cast<uint16_t>(oam_[pd_off]) |
                                static_cast<uint16_t>(oam_[pd_off + 1] << 8));
    }

    for (int py = 0; py < draw_h; ++py) {
      const int sy = y + py;
      if (sy < 0 || sy >= kScreenHeight) continue;
      for (int px = 0; px < draw_w; ++px) {
        const int sx = x + px;
        if (sx < 0 || sx >= kScreenWidth) continue;
        int tx = 0, ty = 0;
        int sample_px = px;
        int sample_py = py;
        if (mosaic) {
          const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
          const int mos_h = static_cast<int>(((mosaic_reg >> 8) & 0xFu) + 1);
          const int mos_v = static_cast<int>(((mosaic_reg >> 12) & 0xFu) + 1);
          sample_px = (px / mos_h) * mos_h;
          sample_py = (py / mos_v) * mos_v;
        }
        if (affine) {
          const int cx = draw_w / 2;
          const int cy = draw_h / 2;
          const int dx = sample_px - cx;
          const int dy = sample_py - cy;
          const int src_cx = src_w / 2;
          const int src_cy = src_h / 2;
          tx = src_cx + static_cast<int>((static_cast<int32_t>(pa) * dx +
                                          static_cast<int32_t>(pb) * dy) >>
                                         8);
          ty = src_cy + static_cast<int>((static_cast<int32_t>(pc) * dx +
                                          static_cast<int32_t>(pd) * dy) >>
                                         8);
          if (tx < 0 || ty < 0 || tx >= src_w || ty >= src_h) continue;
        } else {
          tx = hflip ? (src_w - 1 - sample_px) : sample_px;
          ty = vflip ? (src_h - 1 - sample_py) : sample_py;
        }

        uint16_t color_index = 0;
        if (color_256) {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
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
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 32 +
                                                     in_y * 4 + in_x / 2);
          if (chr_off >= vram_.size()) continue;
          const uint8_t packed = vram_[chr_off];
          const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
          if (nib == 0u) continue;
          color_index = static_cast<uint16_t>(palbank * 16u + nib);
        }
        if (color_256 && color_index == 0u) continue;
        const size_t fb_off = static_cast<size_t>(sy) * kScreenWidth + sx;
        mask[fb_off] = 1u;
      }
    }
  }
}

void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 12)) == 0) return;  // OBJ disable
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const bool obj_is_1st_target = (bldcnt & (1u << 4)) != 0;
  const bool any_2nd_target = ((bldcnt >> 8) & 0x3Fu) != 0;

  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();

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
    if (obj_mode == 2u) continue;  // OBJ-window sprites are consumed by BuildObjWindowMask().
    const bool affine = (attr0 & (1u << 8)) != 0;
    const bool double_size = affine && ((attr0 & (1u << 9)) != 0);

    const int shape = (attr0 >> 14) & 0x3;
    const int size = (attr1 >> 14) & 0x3;
    if (shape >= 3) continue;
    const int src_w = kObjDim[shape][size][0];
    const int src_h = kObjDim[shape][size][1];
    const int draw_w = double_size ? (src_w * 2) : src_w;
    const int draw_h = double_size ? (src_h * 2) : src_h;

    int y = attr0 & 0xFF;
    int x = attr1 & 0x1FF;
    if (y >= 160) y -= 256;
    if (x >= 240) x -= 512;

    const bool color_256 = (attr0 & (1u << 13)) != 0;
    const bool mosaic = (attr0 & (1u << 12)) != 0;
    const bool hflip = (attr1 & (1u << 12)) != 0;
    const bool vflip = (attr1 & (1u << 13)) != 0;
    const uint8_t obj_priority = static_cast<uint8_t>((attr2 >> 10) & 0x3u);
    const uint16_t tile_id = attr2 & 0x03FFu;
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);
    const size_t obj_chr_base = 0x10000u;

    int16_t pa = 0;
    int16_t pb = 0;
    int16_t pc = 0;
    int16_t pd = 0;
    if (affine) {
      const uint16_t affine_idx = static_cast<uint16_t>((attr1 >> 9) & 0x1Fu);
      const size_t pa_off = static_cast<size_t>(affine_idx) * 0x20u + 0x06u;
      const size_t pb_off = static_cast<size_t>(affine_idx) * 0x20u + 0x0Eu;
      const size_t pc_off = static_cast<size_t>(affine_idx) * 0x20u + 0x16u;
      const size_t pd_off = static_cast<size_t>(affine_idx) * 0x20u + 0x1Eu;
      if (pd_off + 1 >= oam_.size()) continue;
      pa = static_cast<int16_t>(static_cast<uint16_t>(oam_[pa_off]) |
                                static_cast<uint16_t>(oam_[pa_off + 1] << 8));
      pb = static_cast<int16_t>(static_cast<uint16_t>(oam_[pb_off]) |
                                static_cast<uint16_t>(oam_[pb_off + 1] << 8));
      pc = static_cast<int16_t>(static_cast<uint16_t>(oam_[pc_off]) |
                                static_cast<uint16_t>(oam_[pc_off + 1] << 8));
      pd = static_cast<int16_t>(static_cast<uint16_t>(oam_[pd_off]) |
                                static_cast<uint16_t>(oam_[pd_off + 1] << 8));
    }

    for (int py = 0; py < draw_h; ++py) {
      const int sy = y + py;
      if (sy < 0 || sy >= kScreenHeight) continue;
      for (int px = 0; px < draw_w; ++px) {
        const int sx = x + px;
        if (sx < 0 || sx >= kScreenWidth) continue;
        if (!IsObjVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, sx, sy)) {
          continue;
        }

        int tx = 0;
        int ty = 0;
        int sample_px = px;
        int sample_py = py;
        if (mosaic) {
          const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
          const int mos_h = static_cast<int>(((mosaic_reg >> 8) & 0xFu) + 1);
          const int mos_v = static_cast<int>(((mosaic_reg >> 12) & 0xFu) + 1);
          sample_px = (px / mos_h) * mos_h;
          sample_py = (py / mos_v) * mos_v;
        }
        if (affine) {
          const int cx = draw_w / 2;
          const int cy = draw_h / 2;
          const int dx = sample_px - cx;
          const int dy = sample_py - cy;
          const int src_cx = src_w / 2;
          const int src_cy = src_h / 2;
          tx = src_cx + static_cast<int>((static_cast<int32_t>(pa) * dx +
                                          static_cast<int32_t>(pb) * dy) >>
                                         8);
          ty = src_cy + static_cast<int>((static_cast<int32_t>(pc) * dx +
                                          static_cast<int32_t>(pd) * dy) >>
                                         8);
          if (tx < 0 || ty < 0 || tx >= src_w || ty >= src_h) continue;
        } else {
          tx = hflip ? (src_w - 1 - sample_px) : sample_px;
          ty = vflip ? (src_h - 1 - sample_py) : sample_py;
        }

        uint16_t color_index = 0;
        if (color_256) {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
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
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 32 +
                                                     in_y * 4 + in_x / 2);
          if (chr_off >= vram_.size()) continue;
          const uint8_t packed = vram_[chr_off];
          const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
          if (nib == 0u) continue;
          color_index = static_cast<uint16_t>(palbank * 16u + nib);
        }
        if (color_256 && color_index == 0u) continue;  // transparent
        const size_t fb_off = static_cast<size_t>(sy) * kScreenWidth + sx;
        if (obj_priority > bg_priority[fb_off]) continue;
        uint32_t obj_px = palette_color(color_index);
        if (obj_mode == 1u) {
          const uint8_t window_control = ResolveWindowControl(
              dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), sx, sy);
          const bool effects_enabled = (window_control & (1u << 5)) != 0;
          if (!(effects_enabled && obj_is_1st_target && any_2nd_target)) {
            frame_buffer_[fb_off] = obj_px;
            bg_priority[fb_off] = obj_priority;
            continue;
          }
          // Semi-transparent OBJ: approximate hardware blend using current
          // framebuffer pixel as 2nd target.
          const uint32_t under = frame_buffer_[fb_off];
          const uint8_t sr = static_cast<uint8_t>((obj_px >> 16) & 0xFFu);
          const uint8_t sg = static_cast<uint8_t>((obj_px >> 8) & 0xFFu);
          const uint8_t sb = static_cast<uint8_t>(obj_px & 0xFFu);
          const uint8_t ur = static_cast<uint8_t>((under >> 16) & 0xFFu);
          const uint8_t ug = static_cast<uint8_t>((under >> 8) & 0xFFu);
          const uint8_t ub = static_cast<uint8_t>(under & 0xFFu);
          const uint8_t rr = ClampToByteLocal(static_cast<int>((sr * eva + ur * evb) / 16u));
          const uint8_t rg = ClampToByteLocal(static_cast<int>((sg * eva + ug * evb) / 16u));
          const uint8_t rb = ClampToByteLocal(static_cast<int>((sb * eva + ub * evb) / 16u));
          obj_px = 0xFF000000u | (static_cast<uint32_t>(rr) << 16) |
                   (static_cast<uint32_t>(rg) << 8) | rb;
        }
        frame_buffer_[fb_off] = obj_px;
        bg_priority[fb_off] = obj_priority;
      }
    }
  }
}

void GBACore::RenderMode0Frame() {
  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
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
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) {
          continue;
        }
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
      bg_priority[static_cast<size_t>(y) * kScreenWidth + x] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
    }
  }
}

void GBACore::RenderMode1Frame() {
  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
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

      if ((dispcnt & (1u << 8)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 0, x, y)) {
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
      if ((dispcnt & (1u << 9)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 1, x, y)) {
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
      if ((dispcnt & (1u << 10)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
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
      bg_priority[static_cast<size_t>(y) * kScreenWidth + x] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
    }
  }
}

void GBACore::RenderMode2Frame() {
  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
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

      if ((dispcnt & (1u << 10)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
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
      if ((dispcnt & (1u << 11)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 3, x, y)) {
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
      bg_priority[static_cast<size_t>(y) * kScreenWidth + x] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
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
    apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
    return;
  }

  // Handle trigger edges (bit7 of NRx4 high byte).
  auto consume_trigger = [&](uint32_t addr) -> bool {
    const uint8_t v = Read8(addr);
    if ((v & 0x80u) == 0) return false;
    Write8(addr, static_cast<uint8_t>(v & 0x7Fu));
    return true;
  };
  if (consume_trigger(0x04000065u)) {
    apu_ch1_active_ = true;
    apu_len_ch1_ = static_cast<uint8_t>(64u - (Read8(0x04000062u) & 0x3Fu));
    apu_env_ch1_ = static_cast<uint8_t>((Read8(0x04000063u) >> 4) & 0xFu);
    apu_env_timer_ch1_ = static_cast<uint8_t>(Read8(0x04000063u) & 0x7u);
    apu_ch1_sweep_freq_ = static_cast<uint16_t>((Read8(0x04000064u)) |
                                                ((Read8(0x04000065u) & 0x7u) << 8));
    const uint8_t nr10 = Read8(0x04000060u);
    apu_ch1_sweep_timer_ = static_cast<uint8_t>((nr10 >> 4) & 0x7u);
    apu_ch1_sweep_enabled_ = (nr10 & 0x7u) != 0 || apu_ch1_sweep_timer_ != 0;
  }
  if (consume_trigger(0x0400006Du)) {
    apu_ch2_active_ = true;
    apu_len_ch2_ = static_cast<uint8_t>(64u - (Read8(0x04000068u) & 0x3Fu));
    apu_env_ch2_ = static_cast<uint8_t>((Read8(0x04000069u) >> 4) & 0xFu);
    apu_env_timer_ch2_ = static_cast<uint8_t>(Read8(0x04000069u) & 0x7u);
  }
  if (consume_trigger(0x04000075u)) {
    apu_ch3_active_ = true;
    apu_len_ch3_ = static_cast<uint16_t>(256u - Read8(0x04000071u));
  }
  if (consume_trigger(0x0400007Du)) {
    apu_ch4_active_ = true;
    apu_len_ch4_ = static_cast<uint8_t>(64u - (Read8(0x04000079u) & 0x3Fu));
    apu_env_ch4_ = static_cast<uint8_t>((Read8(0x04000077u) >> 4) & 0xFu);
    apu_env_timer_ch4_ = static_cast<uint8_t>(Read8(0x04000077u) & 0x7u);
  }

  // 512Hz frame sequencer (16777216 / 512 = 32768 cycles).
  apu_frame_seq_cycles_ += cycles;
  while (apu_frame_seq_cycles_ >= 32768u) {
    apu_frame_seq_cycles_ -= 32768u;
    apu_frame_seq_step_ = static_cast<uint8_t>((apu_frame_seq_step_ + 1u) & 7u);
    const bool length_tick = (apu_frame_seq_step_ % 2u) == 0u;
    const bool sweep_tick = (apu_frame_seq_step_ == 2u || apu_frame_seq_step_ == 6u);
    const bool envelope_tick = apu_frame_seq_step_ == 7u;

    if (length_tick) {
      if ((Read8(0x04000065u) & 0x40u) && apu_ch1_active_ && apu_len_ch1_ > 0 && --apu_len_ch1_ == 0) apu_ch1_active_ = false;
      if ((Read8(0x0400006Du) & 0x40u) && apu_ch2_active_ && apu_len_ch2_ > 0 && --apu_len_ch2_ == 0) apu_ch2_active_ = false;
      if ((Read8(0x04000075u) & 0x40u) && apu_ch3_active_ && apu_len_ch3_ > 0 && --apu_len_ch3_ == 0) apu_ch3_active_ = false;
      if ((Read8(0x0400007Du) & 0x40u) && apu_ch4_active_ && apu_len_ch4_ > 0 && --apu_len_ch4_ == 0) apu_ch4_active_ = false;
    }
    if (envelope_tick) {
      auto step_env = [](uint8_t* vol, uint8_t* timer, uint8_t reg) {
        const uint8_t period = reg & 0x7u;
        if (period == 0) return;
        if (*timer == 0) *timer = period;
        if (--(*timer) != 0) return;
        *timer = period;
        const bool inc = (reg & 0x8u) != 0;
        if (inc) {
          if (*vol < 15u) ++(*vol);
        } else {
          if (*vol > 0u) --(*vol);
        }
      };
      if (apu_ch1_active_) step_env(&apu_env_ch1_, &apu_env_timer_ch1_, Read8(0x04000063u));
      if (apu_ch2_active_) step_env(&apu_env_ch2_, &apu_env_timer_ch2_, Read8(0x04000069u));
      if (apu_ch4_active_) step_env(&apu_env_ch4_, &apu_env_timer_ch4_, Read8(0x04000077u));
    }
    if (sweep_tick && apu_ch1_active_ && apu_ch1_sweep_enabled_) {
      const uint8_t nr10 = Read8(0x04000060u);
      uint8_t sweep_period = static_cast<uint8_t>((nr10 >> 4) & 0x7u);
      if (sweep_period == 0) sweep_period = 8;
      if (apu_ch1_sweep_timer_ == 0) apu_ch1_sweep_timer_ = sweep_period;
      if (--apu_ch1_sweep_timer_ == 0) {
        apu_ch1_sweep_timer_ = sweep_period;
        const uint8_t shift = nr10 & 0x7u;
        if (shift != 0u) {
          const uint16_t delta = static_cast<uint16_t>(apu_ch1_sweep_freq_ >> shift);
          uint16_t next = apu_ch1_sweep_freq_;
          if (nr10 & 0x8u) {
            next = static_cast<uint16_t>(apu_ch1_sweep_freq_ - delta);
          } else {
            next = static_cast<uint16_t>(apu_ch1_sweep_freq_ + delta);
          }
          if (next > 2047u) {
            apu_ch1_active_ = false;
          } else {
            apu_ch1_sweep_freq_ = next;
            Write8(0x04000064u, static_cast<uint8_t>(next & 0xFFu));
            const uint8_t nr14_hi = Read8(0x04000065u);
            Write8(0x04000065u, static_cast<uint8_t>((nr14_hi & ~0x7u) | ((next >> 8) & 0x7u)));
          }
        }
      }
    }
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

  int ch1 = 0;
  int ch2 = 0;
  int ch3 = 0;
  int ch4 = 0;
  if ((soundcnt_x & 0x0001u) && apu_ch1_active_) {  // CH1
    const uint16_t nr11 = ReadIO16(0x04000062u);
    const uint16_t nr12 = ReadIO16(0x04000063u);
    const uint16_t nr13 = ReadIO16(0x04000064u);
    const uint16_t nr14 = ReadIO16(0x04000065u);
    const uint16_t freq = static_cast<uint16_t>(nr13 | ((nr14 & 0x7u) << 8));
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch1_));
    ch1 = (square_sample(&apu_phase_sq1_, freq, nr11) * env_vol) / 15;
  }
  if ((soundcnt_x & 0x0002u) && apu_ch2_active_) {  // CH2
    const uint16_t nr21 = ReadIO16(0x04000068u);
    const uint16_t nr22 = ReadIO16(0x04000069u);
    const uint16_t nr23 = ReadIO16(0x0400006Cu);
    const uint16_t nr24 = ReadIO16(0x0400006Du);
    const uint16_t freq = static_cast<uint16_t>(nr23 | ((nr24 & 0x7u) << 8));
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch2_));
    ch2 = (square_sample(&apu_phase_sq2_, freq, nr21) * env_vol) / 15;
  }
  if ((soundcnt_x & 0x0004u) && apu_ch3_active_) {  // CH3 wave
    const uint16_t nr30 = ReadIO16(0x04000070u);
    const uint16_t nr32 = ReadIO16(0x04000072u);
    if (nr30 & 0x0080u) {
      const uint16_t nr33 = ReadIO16(0x04000074u);
      const uint16_t nr34 = ReadIO16(0x04000075u);
      const uint16_t n = static_cast<uint16_t>(nr33 | ((nr34 & 0x7u) << 8));
      const uint32_t hz = (2048u > n) ? (65536u / std::max<uint16_t>(1u, static_cast<uint16_t>(2048u - n))) : 0u;
      apu_phase_wave_ += hz * std::max<uint32_t>(1u, cycles);
      const bool two_bank_mode = (nr30 & (1u << 5)) != 0;
      const bool bank_select = (nr30 & (1u << 6)) != 0;
      const uint32_t sample_idx = (apu_phase_wave_ / 2048u) & (two_bank_mode ? 15u : 31u);
      const size_t bank_base = two_bank_mode ? (bank_select ? 16u : 0u) : 0u;
      const size_t wave_off = bank_base + static_cast<size_t>(sample_idx / 2u);
      const uint8_t packed = (wave_off < 32u) ? io_regs_[0x90 + wave_off] : 0;
      uint8_t sample4 = (sample_idx & 1u) ? (packed & 0x0Fu) : (packed >> 4);
      const uint16_t vol_code = (nr32 >> 5) & 0x3u;
      if (vol_code == 0) sample4 = 0;
      else if (vol_code == 2) sample4 >>= 1;
      else if (vol_code == 3) sample4 >>= 2;
      ch3 = static_cast<int>(sample4) * 8 - 60;
    }
  }
  if ((soundcnt_x & 0x0008u) && apu_ch4_active_) {  // CH4 noise
    const uint16_t nr42 = ReadIO16(0x04000077u);
    const uint16_t nr43 = ReadIO16(0x04000078u);
    const uint32_t div = (nr43 & 0x7u) == 0 ? 8u : (nr43 & 0x7u) * 16u;
    const uint32_t shift = (nr43 >> 4) & 0xFu;
    const uint32_t period = div << shift;
    const bool narrow_7bit = (nr43 & (1u << 3)) != 0;
    for (uint32_t i = 0; i < std::max<uint32_t>(1u, cycles / std::max<uint32_t>(1u, period)); ++i) {
      const uint16_t x = static_cast<uint16_t>((apu_noise_lfsr_ ^ (apu_noise_lfsr_ >> 1)) & 1u);
      apu_noise_lfsr_ = static_cast<uint16_t>((apu_noise_lfsr_ >> 1) | (x << 14));
      if (narrow_7bit) {
        apu_noise_lfsr_ = static_cast<uint16_t>((apu_noise_lfsr_ & ~0x40u) | (x << 6));
      }
    }
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch4_));
    ch4 = ((apu_noise_lfsr_ & 1u) ? 28 : -28) * env_vol / 15;
  }

  const bool right_ch1 = (soundcnt_l & (1u << 0)) != 0;
  const bool right_ch2 = (soundcnt_l & (1u << 1)) != 0;
  const bool right_ch3 = (soundcnt_l & (1u << 2)) != 0;
  const bool right_ch4 = (soundcnt_l & (1u << 3)) != 0;
  const bool left_ch1 = (soundcnt_l & (1u << 4)) != 0;
  const bool left_ch2 = (soundcnt_l & (1u << 5)) != 0;
  const bool left_ch3 = (soundcnt_l & (1u << 6)) != 0;
  const bool left_ch4 = (soundcnt_l & (1u << 7)) != 0;
  const int right_sum = (right_ch1 ? ch1 : 0) + (right_ch2 ? ch2 : 0) +
                        (right_ch3 ? ch3 : 0) + (right_ch4 ? ch4 : 0);
  const int left_sum = (left_ch1 ? ch1 : 0) + (left_ch2 ? ch2 : 0) +
                       (left_ch3 ? ch3 : 0) + (left_ch4 ? ch4 : 0);

  const int left_vol = (soundcnt_l >> 4) & 0x7;
  const int right_vol = soundcnt_l & 0x7;
  const int psg_master = (soundcnt_h & 0x0003u) == 0 ? 1 : ((soundcnt_h & 0x0003u) == 1 ? 2 : 4);
  int psg_mix = ((left_sum * left_vol) + (right_sum * right_vol)) / 8;
  psg_mix = (psg_mix * psg_master) / 4;

  const int fifo_a_gain = (soundcnt_h & (1u << 2)) ? 2 : 1;
  const int fifo_b_gain = (soundcnt_h & (1u << 3)) ? 2 : 1;
  const int fifo_mix = fifo_a_last_sample_ * fifo_a_gain + fifo_b_last_sample_ * fifo_b_gain;
  const int mixed = psg_mix + fifo_mix;
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
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint16_t bldy = ReadIO16(0x04000054u);
  const uint32_t mode = (bldcnt >> 6) & 0x3u;
  if (mode == 0u) return;

  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const uint8_t back_r = static_cast<uint8_t>((backdrop >> 16) & 0xFFu);
  const uint8_t back_g = static_cast<uint8_t>((backdrop >> 8) & 0xFFu);
  const uint8_t back_b = static_cast<uint8_t>(backdrop & 0xFFu);
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint8_t window_control =
          ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
      if ((window_control & (1u << 5)) == 0) continue;  // color effects masked by window
      uint32_t& px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      uint8_t r = static_cast<uint8_t>((px >> 16) & 0xFFu);
      uint8_t g = static_cast<uint8_t>((px >> 8) & 0xFFu);
      uint8_t b = static_cast<uint8_t>(px & 0xFFu);
      if (mode == 1u) {
        // Improved approximation: blend against current backdrop color instead
        // of hardcoded black. This reduces visible darkening artifacts.
        r = ClampToByteLocal(static_cast<int>((r * eva + back_r * evb) / 16u));
        g = ClampToByteLocal(static_cast<int>((g * eva + back_g * evb) / 16u));
        b = ClampToByteLocal(static_cast<int>((b * eva + back_b * evb) / 16u));
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
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 7)) != 0) {
    // Forced blank: display white regardless of BG mode.
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), 0xFFFFFFFFu);
    EnsureBgPriorityBufferSize();
    std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
              static_cast<uint8_t>(kBackdropPriority));
    return;
  }
  BuildObjWindowMask();
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
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  EnsureBgPriorityBufferSize();
  std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
            static_cast<uint8_t>(kBackdropPriority));
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
