#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {
namespace {

bool SampleObjColorIndex(const std::array<uint8_t, 96 * 1024>& vram, size_t obj_chr_base,
                         bool obj_1d, bool color_256, int src_w, int tx, int ty,
                         uint16_t tile_id, uint16_t palbank, uint16_t* out_color_index) {
  if (out_color_index == nullptr) return false;
  const int tile_x = tx / 8;
  const int tile_y = ty / 8;
  const int in_x = tx & 7;
  const int in_y = ty & 7;

  // OBJ tile indices are addressed in 32-byte units.
  // 256-color OBJ tiles consume two 32-byte indices, so both tile base and
  // row stride need color-depth-aware scaling.
  const int tile_unit_x = color_256 ? (tile_x * 2) : tile_x;
  const int row_stride_units = obj_1d ? (color_256 ? (src_w / 4) : (src_w / 8)) : 32;
  const uint16_t tile_base = color_256 ? static_cast<uint16_t>(tile_id & ~1u) : tile_id;
  const uint32_t tile_units = static_cast<uint32_t>(tile_base) +
                              static_cast<uint32_t>(tile_y * row_stride_units + tile_unit_x);
  const size_t chr_base_off = obj_chr_base + static_cast<size_t>(tile_units) * 32u;
  if (chr_base_off >= vram.size()) return false;

  if (color_256) {
    const size_t chr_off = chr_base_off + static_cast<size_t>(in_y * 8 + in_x);
    if (chr_off >= vram.size()) return false;
    const uint8_t color = vram[chr_off];
    if (color == 0u) return false;
    *out_color_index = color;
    return true;
  }

  const size_t chr_off = chr_base_off + static_cast<size_t>(in_y * 4 + in_x / 2);
  if (chr_off >= vram.size()) return false;
  const uint8_t packed = vram[chr_off];
  const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
  if (nib == 0u) return false;
  *out_color_index = static_cast<uint16_t>(palbank * 16u + nib);
  return true;
}

}  // namespace

void GBACore::RenderMode3Frame() {
  // Mode 3: 240x160 direct color (BGR555) in VRAM.
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(bg2cnt & 0x3u);
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const bool mosaic = (bg2cnt & (1u << 6)) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
  const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
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
    std::fill(bg_layer.begin(), bg_layer.end(), kLayerBackdrop);
    std::fill(second_color.begin(), second_color.end(), backdrop);
    std::fill(second_layer.begin(), second_layer.end(), kLayerBackdrop);
    return;
  }

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[fb_off] = backdrop; second_color[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
      const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
      int sx = static_cast<int>(tex_x_fp >> 8);
      int sy = static_cast<int>(tex_y_fp >> 8);
      if (wrap) {
        sx = ((sx % kScreenWidth) + kScreenWidth) % kScreenWidth;
        sy = ((sy % kScreenHeight) + kScreenHeight) % kScreenHeight;
      }
      if (sx < 0 || sy < 0 || sx >= kScreenWidth || sy >= kScreenHeight) {
        frame_buffer_[fb_off] = backdrop; second_color[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const size_t off = static_cast<size_t>((sy * kScreenWidth + sx) * 2);
      if (off + 1 >= vram_.size()) {
        frame_buffer_[fb_off] = backdrop; second_color[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr555);
      bg_priority[fb_off] = bg2_priority;
      bg_layer[fb_off] = kLayerBg2;
      second_color[fb_off] = backdrop;
      second_layer[fb_off] = kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  EnsureObjDrawnMaskBufferSize();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(bg2cnt & 0x3u);
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const bool mosaic = (bg2cnt & (1u << 6)) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
  const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
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
    std::fill(bg_layer.begin(), bg_layer.end(), kLayerBackdrop);
    std::fill(second_color.begin(), second_color.end(), backdrop);
    std::fill(second_layer.begin(), second_layer.end(), kLayerBackdrop);
    return;
  }

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[fb_off] = backdrop; second_color[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
      const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
      int sx = static_cast<int>(tex_x_fp >> 8);
      int sy = static_cast<int>(tex_y_fp >> 8);
      if (wrap) {
        sx = ((sx % kScreenWidth) + kScreenWidth) % kScreenWidth;
        sy = ((sy % kScreenHeight) + kScreenHeight) % kScreenHeight;
      }
      if (sx < 0 || sy < 0 || sx >= kScreenWidth || sy >= kScreenHeight) {
        frame_buffer_[fb_off] = backdrop; second_color[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const size_t off = page_base + static_cast<size_t>(sy * kScreenWidth + sx);
      const uint8_t index = (off < vram_.size()) ? vram_[off] : 0;
      frame_buffer_[fb_off] = palette_color(index);
      bg_priority[fb_off] = bg2_priority;
      bg_layer[fb_off] = kLayerBg2;
      second_color[fb_off] = backdrop;
      second_layer[fb_off] = kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(bg2cnt & 0x3u);
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const bool mosaic = (bg2cnt & (1u << 6)) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
  const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
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
  std::fill(bg_layer.begin(), bg_layer.end(), kLayerBackdrop);
  std::fill(second_color.begin(), second_color.end(), backdrop);
  std::fill(second_layer.begin(), second_layer.end(), kLayerBackdrop);

  if (!bg2_enabled) return;

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        continue;
      }
      const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
      const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
      int sx = static_cast<int>(tex_x_fp >> 8);
      int sy = static_cast<int>(tex_y_fp >> 8);
      if (wrap) {
        sx = ((sx % kMode5Width) + kMode5Width) % kMode5Width;
        sy = ((sy % kMode5Height) + kMode5Height) % kMode5Height;
      }
      if (sx < 0 || sy < 0 || sx >= kMode5Width || sy >= kMode5Height) continue;
      const size_t off = page_base + static_cast<size_t>((sy * kMode5Width + sx) * 2);
      if (off + 1 >= vram_.size()) continue;
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr555);
      bg_priority[fb_off] = bg2_priority;
      bg_layer[fb_off] = kLayerBg2;
      second_color[fb_off] = backdrop;
      second_layer[fb_off] = kLayerBackdrop;
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
  EnsureObjDrawnMaskBufferSize();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_base = BgBaseColorBuffer();

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},     // square
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},     // horizontal
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},     // vertical
  };
  const bool obj_1d = (dispcnt & (1u << 6)) != 0;
  const uint8_t bg_mode = static_cast<uint8_t>(dispcnt & 0x7u);
  const bool bitmap_mode = bg_mode >= 3u;
  const size_t obj_chr_base = bitmap_mode ? 0x14000u : 0x10000u;

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
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
    const uint16_t tile_id = bitmap_mode ? static_cast<uint16_t>(attr2 & 0x01FFu)
                                         : static_cast<uint16_t>(attr2 & 0x03FFu);
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);

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
        if (!SampleObjColorIndex(vram_, obj_chr_base, obj_1d, color_256, src_w, tx, ty,
                                 tile_id, palbank, &color_index)) {
          continue;
        }
        const size_t fb_off = static_cast<size_t>(sy) * kScreenWidth + sx;
        if (obj_priority > bg_priority[fb_off]) continue;
        uint32_t obj_px = palette_color(color_index);
        if (obj_mode == 1u) {
          const uint8_t window_control = ResolveWindowControl(
              dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), sx, sy);
          const bool effects_enabled = (window_control & (1u << 5)) != 0;
          bool second_target_ok = false;
          if (obj_drawn[fb_off] != 0u) {
            second_target_ok = (bldcnt & (1u << (8 + 4))) != 0;  // OBJ as 2nd target
          } else if (bg_priority[fb_off] == kBackdropPriority) {
            second_target_ok = (bldcnt & (1u << (8 + 5))) != 0;  // BD as 2nd target
          } else {
            const uint8_t layer = (fb_off < bg_layer.size()) ? bg_layer[fb_off] : kLayerBackdrop;
            const uint16_t layer_mask = static_cast<uint16_t>(1u << (8u + std::min<uint8_t>(layer, 5u)));
            second_target_ok = (bldcnt & layer_mask) != 0;
          }
          if (!(effects_enabled && obj_is_1st_target && any_2nd_target && second_target_ok)) {
            frame_buffer_[fb_off] = obj_px;
            bg_priority[fb_off] = obj_priority;
            obj_drawn[fb_off] = 1u;
            continue;
          }
          // Semi-transparent OBJ: approximate hardware blend using current
          // framebuffer pixel as 2nd target.
          const uint32_t under =
              (obj_drawn[fb_off] != 0u) ? frame_buffer_[fb_off]
                                        : ((fb_off < bg_base.size()) ? bg_base[fb_off] : frame_buffer_[fb_off]);
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
        obj_drawn[fb_off] = 1u;
      }
    }
  }
}

}  // namespace gba
