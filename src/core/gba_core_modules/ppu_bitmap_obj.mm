#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {
namespace {

bool SampleObjColorIndex(const std::array<uint8_t, 96 * 1024>& vram, size_t obj_chr_base,
                         bool obj_1d, bool color_256, int src_w, int tx, int ty,
                         uint16_t tile_id, uint16_t palbank, uint16_t* out_color_index) {
  if (out_color_index == nullptr) return false;
  const int tile_x = tx / 8, tile_y = ty / 8;
  const int in_x = tx & 7, in_y = ty & 7;

  uint32_t t_id = tile_id;
  if (color_256) t_id &= ~1u;

  uint32_t tile_units;
  if (obj_1d) {
    const int tiles_per_row = src_w / 8;
    tile_units = t_id + static_cast<uint32_t>(tile_y * (color_256 ? tiles_per_row * 2 : tiles_per_row) + (color_256 ? tile_x * 2 : tile_x));
  } else {
    // 2D Mapping: Hardware uses 32-tile stride (1024 bytes per row of tiles)
    tile_units = t_id + static_cast<uint32_t>(tile_y * 32 + (color_256 ? tile_x * 2 : tile_x));
  }

  const size_t chr_base_off = obj_chr_base + static_cast<size_t>(tile_units) * 32u;
  if (chr_base_off >= vram.size()) return false;

  if (color_256) {
    const uint8_t color = vram[(chr_base_off + static_cast<size_t>(in_y * 8 + in_x)) % vram.size()];
    if (color == 0u) return false;
    *out_color_index = color;
    return true;
  }

  const uint8_t packed = vram[(chr_base_off + static_cast<size_t>(in_y * 4 + in_x / 2)) % vram.size()];
  const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
  if (nib == 0u) return false;
  *out_color_index = static_cast<uint16_t>(palbank * 16u + nib);
  return true;
}

}  // namespace

void GBACore::RenderMode3Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool bg2_enable = (dispcnt & (1u << 10)) != 0;
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  const bool mosaic = (bg2cnt & 0x40) != 0;
  const bool wrap = (bg2cnt & 0x2000) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = (mosaic_reg & 0xF) + 1;
  const int mos_v = ((mosaic_reg >> 4) & 0xF) + 1;

  for (int y = 0; y < kScreenHeight; ++y) {
    const int sy = mosaic ? (y / mos_v) * mos_v : y;
    const int32_t line_refx = affine_line_refs_valid_ ? bg2_refx_line_[sy] : (static_cast<int32_t>(Read32(0x04000028u) << 4) >> 4) + static_cast<int32_t>(pb) * sy;
    const int32_t line_refy = affine_line_refs_valid_ ? bg2_refy_line_[sy] : (static_cast<int32_t>(Read32(0x0400002Cu) << 4) >> 4) + static_cast<int32_t>(pd) * sy;
    for (int x = 0; x < kScreenWidth; ++x) {
      const int sx = mosaic ? (x / mos_h) * mos_h : x;
      const size_t off = static_cast<size_t>(y * kScreenWidth + x);
      if (!bg2_enable || !IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[off] = backdrop;
        BgPriorityBuffer()[off] = 4;
        BgLayerBuffer()[off] = 4;
        continue;
      }
      int tex_x = static_cast<int>((static_cast<int64_t>(line_refx) + static_cast<int64_t>(pa) * sx) >> 8);
      int tex_y = static_cast<int>((static_cast<int64_t>(line_refy) + static_cast<int64_t>(pc) * sx) >> 8);
      if (wrap) {
        tex_x %= 240; if (tex_x < 0) tex_x += 240;
        tex_y %= 160; if (tex_y < 0) tex_y += 160;
      }
      if (tex_x < 0 || tex_y < 0 || tex_x >= 240 || tex_y >= 160) {
        frame_buffer_[off] = backdrop;
        BgPriorityBuffer()[off] = 4;
        BgLayerBuffer()[off] = 4;
        continue;
      }
      const uint32_t vram_off = static_cast<uint32_t>((tex_y * 240 + tex_x) * 2);
      const uint16_t bgr = static_cast<uint16_t>(vram_[vram_off]) | (static_cast<uint16_t>(vram_[vram_off+1]) << 8);
      frame_buffer_[off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[off] = bg2cnt & 3;
      BgLayerBuffer()[off] = 2;
    }
  }
}

void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool bg2_enable = (dispcnt & (1u << 10)) != 0;
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const uint32_t page_base = (dispcnt & 0x10) ? 0xA000 : 0;

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  const bool mosaic = (bg2cnt & 0x40) != 0;
  const bool wrap = (bg2cnt & 0x2000) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = (mosaic_reg & 0xF) + 1;
  const int mos_v = ((mosaic_reg >> 4) & 0xF) + 1;

  for (int y = 0; y < kScreenHeight; ++y) {
    const int sy = mosaic ? (y / mos_v) * mos_v : y;
    const int32_t line_refx = affine_line_refs_valid_ ? bg2_refx_line_[sy] : (static_cast<int32_t>(Read32(0x04000028u) << 4) >> 4) + static_cast<int32_t>(pb) * sy;
    const int32_t line_refy = affine_line_refs_valid_ ? bg2_refy_line_[sy] : (static_cast<int32_t>(Read32(0x0400002Cu) << 4) >> 4) + static_cast<int32_t>(pd) * sy;
    for (int x = 0; x < kScreenWidth; ++x) {
      const int sx = mosaic ? (x / mos_h) * mos_h : x;
      const size_t off = static_cast<size_t>(y * kScreenWidth + x);
      if (!bg2_enable || !IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[off] = backdrop;
        BgPriorityBuffer()[off] = 4;
        continue;
      }
      int tex_x = static_cast<int>((static_cast<int64_t>(line_refx) + static_cast<int64_t>(pa) * sx) >> 8);
      int tex_y = static_cast<int>((static_cast<int64_t>(line_refy) + static_cast<int64_t>(pc) * sx) >> 8);
      if (wrap) {
        tex_x %= 240; if (tex_x < 0) tex_x += 240;
        tex_y %= 160; if (tex_y < 0) tex_y += 160;
      }
      if (tex_x < 0 || tex_y < 0 || tex_x >= 240 || tex_y >= 160) {
        frame_buffer_[off] = backdrop;
        BgPriorityBuffer()[off] = 4;
        BgLayerBuffer()[off] = 4;
        continue;
      }
      const uint8_t idx = vram_[page_base + static_cast<uint32_t>(tex_y * 240 + tex_x)];
      const size_t pal_off = static_cast<size_t>(idx) * 2;
      const uint16_t bgr = static_cast<uint16_t>(palette_ram_[pal_off]) | (static_cast<uint16_t>(palette_ram_[pal_off+1]) << 8);
      frame_buffer_[off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[off] = bg2cnt & 3;
      BgLayerBuffer()[off] = 2;
    }
  }
}

void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool bg2_enable = (dispcnt & (1u << 10)) != 0;
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  const uint32_t page_base = (dispcnt & 0x10) ? 0xA000 : 0;

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  const bool mosaic = (bg2cnt & 0x40) != 0;
  const bool wrap = (bg2cnt & 0x2000) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = (mosaic_reg & 0xF) + 1;
  const int mos_v = ((mosaic_reg >> 4) & 0xF) + 1;

  for (int y = 0; y < kScreenHeight; ++y) {
    const int sy = mosaic ? (y / mos_v) * mos_v : y;
    const int32_t line_refx = affine_line_refs_valid_ ? bg2_refx_line_[sy] : (static_cast<int32_t>(Read32(0x04000028u) << 4) >> 4) + static_cast<int32_t>(pb) * sy;
    const int32_t line_refy = affine_line_refs_valid_ ? bg2_refy_line_[sy] : (static_cast<int32_t>(Read32(0x0400002Cu) << 4) >> 4) + static_cast<int32_t>(pd) * sy;
    for (int x = 0; x < kScreenWidth; ++x) {
      const int sx = mosaic ? (x / mos_h) * mos_h : x;
      const size_t fb_off = static_cast<size_t>(y * kScreenWidth + x);
      if (!bg2_enable || !IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) continue;
      int tex_x = static_cast<int>((static_cast<int64_t>(line_refx) + static_cast<int64_t>(pa) * sx) >> 8);
      int tex_y = static_cast<int>((static_cast<int64_t>(line_refy) + static_cast<int64_t>(pc) * sx) >> 8);
      if (wrap) {
        tex_x %= 160; if (tex_x < 0) tex_x += 160;
        tex_y %= 128; if (tex_y < 0) tex_y += 128;
      }
      if (tex_x < 0 || tex_y < 0 || tex_x >= 160 || tex_y >= 128) continue;
      const uint32_t vram_off = page_base + static_cast<uint32_t>((tex_y * 160 + tex_x) * 2);
      const uint16_t bgr = static_cast<uint16_t>(vram_[vram_off]) | (static_cast<uint16_t>(vram_[vram_off+1]) << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[fb_off] = bg2cnt & 3;
      BgLayerBuffer()[fb_off] = 2;
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
  const uint8_t bg_mode = static_cast<uint8_t>(dispcnt & 0x7u);
  const bool bitmap_mode = bg_mode >= 3u;
  const size_t obj_chr_base = bitmap_mode ? 0x14000u : 0x10000u;
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
    const uint16_t tile_id = bitmap_mode ? static_cast<uint16_t>(attr2 & 0x01FFu)
                                         : static_cast<uint16_t>(attr2 & 0x03FFu);
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);

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
        if (!SampleObjColorIndex(vram_, obj_chr_base, obj_1d, color_256, src_w, tx, ty,
                                 tile_id, palbank, &color_index)) {
          continue;
        }
        const size_t fb_off = static_cast<size_t>(sy) * kScreenWidth + sx;
        mask[fb_off] = 1u;
      }
    }
  }
}

void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 12)) == 0) return;
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);

  EnsureBgPriorityBufferSize();
  EnsureObjDrawnMaskBufferSize(); EnsureObjSemiTransMaskBufferSize();
  EnsureObjPriorityBuffersSize();

  auto& bg_priority = BgPriorityBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  auto& obj_semitrans = ObjSemiTransMaskBuffer();
  auto& obj_priority_buf = ObjPriorityBuffer();
  auto& obj_index_buf = ObjIndexBuffer();

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},     // square
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},     // horizontal
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},     // vertical
  };
  const bool obj_1d = (dispcnt & 0x40) != 0;
  const uint8_t bg_mode = dispcnt & 7;
  const size_t chr_base_val = (bg_mode >= 3) ? 0x14000u : 0x10000u;

  auto get_pal_color = [&](uint16_t idx) {
    const size_t off = (static_cast<size_t>(idx & 0xFFu) + 0x100u) * 2u;
    return Bgr555ToRgba8888(static_cast<uint16_t>(palette_ram_[off]) | (static_cast<uint16_t>(palette_ram_[off+1]) << 8));
  };

  for (int i = 0; i < 128; ++i) {
    const size_t off = i * 8;
    const uint16_t a0 = static_cast<uint16_t>(oam_[off]) | (static_cast<uint16_t>(oam_[off+1]) << 8);
    const uint16_t a1 = static_cast<uint16_t>(oam_[off+2]) | (static_cast<uint16_t>(oam_[off+3]) << 8);
    const uint16_t a2 = static_cast<uint16_t>(oam_[off+4]) | (static_cast<uint16_t>(oam_[off+5]) << 8);

    if ((a0 & 0x0300) == 0x0200) continue;
    const bool affine = a0 & 0x0100;
    const bool double_size = a0 & 0x0200;
    const int shape = (a0 >> 14) & 3;
    const int size = (a1 >> 14) & 3;
    if (shape >= 3) continue;
    const int sw = kObjDim[shape][size][0], sh = kObjDim[shape][size][1];
    const int dw = double_size ? sw*2 : sw, dh = double_size ? sh*2 : sh;

    int y_base = a0 & 0xFF; if (y_base >= 160) y_base -= 256;
    int x_base = a1 & 0x1FF; if (x_base >= 240) x_base -= 512;

    const bool color_256 = a0 & 0x2000;
    const bool mosaic_on = a0 & 0x1000;
    const uint8_t prio = (a2 >> 10) & 3;
    const uint16_t tile_base = (bg_mode >= 3) ? (a2 & 0x1FF) : (a2 & 0x3FF);
    const uint16_t palbank = (a2 >> 12) & 0xF;

    int16_t pa=256, pb=0, pc=0, pd=256;
    if (affine) {
       const int p_idx = (a1 >> 9) & 0x1F;
       pa = (int16_t)(oam_[p_idx*32 + 6] | (oam_[p_idx*32 + 7] << 8));
       pb = (int16_t)(oam_[p_idx*32 + 14] | (oam_[p_idx*32 + 15] << 8));
       pc = (int16_t)(oam_[p_idx*32 + 22] | (oam_[p_idx*32 + 23] << 8));
       pd = (int16_t)(oam_[p_idx*32 + 30] | (oam_[p_idx*32 + 31] << 8));
    }

    for (int py=0; py<dh; ++py) {
      int sy = y_base + py; if (sy < 0 || sy >= kScreenHeight) continue;
      for (int px=0; px<dw; ++px) {
        int sx = x_base + px; if (sx < 0 || sx >= kScreenWidth) continue;
        if (!IsObjVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, sx, sy)) continue;

        const size_t fb_off = static_cast<size_t>(sy * kScreenWidth + sx);
        if (obj_drawn[fb_off] && prio >= obj_priority_buf[fb_off]) continue;
        if (prio > bg_priority[fb_off]) continue;

        int tsx = px, tsy = py;
        if (mosaic_on) {
          const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
          const int mh = ((mosaic_reg >> 8) & 0xF) + 1;
          const int mv = ((mosaic_reg >> 12) & 0xF) + 1;
          tsx = (px / mh) * mh; tsy = (py / mv) * mv;
        }

        int tx, ty;
        if (affine) {
           int ox = tsx - dw/2, oy = tsy - dh/2;
           tx = (pa * ox + pb * oy) >> 8; ty = (pc * ox + pd * oy) >> 8;
           tx += sw/2; ty += sh/2;
           if (tx < 0 || tx >= sw || ty < 0 || ty >= sh) continue;
        } else {
           tx = tsx; ty = tsy;
           if (a1 & 0x1000) tx = sw - 1 - tx;
           if (a1 & 0x2000) ty = sh - 1 - ty;
        }

        uint16_t color_idx = 0;
        if (SampleObjColorIndex(vram_, chr_base_val, obj_1d, color_256, sw, tx, ty, tile_base, palbank, &color_idx)) {
           frame_buffer_[fb_off] = get_pal_color(color_idx);
           obj_drawn[fb_off] = 1;
           obj_priority_buf[fb_off] = prio;
           obj_index_buf[fb_off] = static_cast<uint8_t>(i);
           obj_semitrans[fb_off] = (a0 & 0x0400) ? 1 : 0;
        }
      }
    }
  }
}

}  // namespace gba
