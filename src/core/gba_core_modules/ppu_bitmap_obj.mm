#include "../gba_core.h"
#include <algorithm>
#include <cmath>

namespace gba {

void GBACore::RenderMode3Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint8_t bg2_priority = ReadIO16(0x0400000Cu) & 3;
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  const int32_t refx = static_cast<int32_t>(Read32(0x04000028u) & 0x0FFFFFFFu);
  const int32_t refy = static_cast<int32_t>(Read32(0x0400002Cu) & 0x0FFFFFFFu);

  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  std::fill(bg_priority_buffer_.begin(), bg_priority_buffer_.end(), 4);

  for (int y = 0; y < 160; ++y) {
    for (int x = 0; x < 240; ++x) {
      int64_t tx_fp = (static_cast<int64_t>(refx) << 36 >> 36) + static_cast<int64_t>(pa) * x + static_cast<int64_t>(pb) * y;
      int64_t ty_fp = (static_cast<int64_t>(refy) << 36 >> 36) + static_cast<int64_t>(pc) * x + static_cast<int64_t>(pd) * y;
      int tx = static_cast<int>(tx_fp >> 8);
      int ty = static_cast<int>(ty_fp >> 8);
      if (tx >= 0 && tx < 240 && ty >= 0 && ty < 160) {
        uint16_t val = Read16(0x06000000 + (ty * 240 + tx) * 2);
        frame_buffer_[y * 240 + x] = Bgr555ToRgba8888(val);
        bg_priority_buffer_[y * 240 + x] = bg2_priority;
        bg_layer_buffer_[y * 240 + x] = 2;
      }
    }
  }
}

void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint8_t bg2_priority = ReadIO16(0x0400000Cu) & 3;
  const bool page = (dispcnt & (1u << 4)) != 0;
  const uint32_t page_base = page ? 0xA000u : 0u;
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));

  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  std::fill(bg_priority_buffer_.begin(), bg_priority_buffer_.end(), 4);

  for (int y = 0; y < 160; ++y) {
    for (int x = 0; x < 240; ++x) {
      uint8_t idx = Read8(0x06000000 + page_base + y * 240 + x);
      if (idx != 0) {
        frame_buffer_[y * 240 + x] = Bgr555ToRgba8888(Read16(0x05000000 + idx * 2));
        bg_priority_buffer_[y * 240 + x] = bg2_priority;
        bg_layer_buffer_[y * 240 + x] = 2;
      }
    }
  }
}

void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  std::fill(bg_priority_buffer_.begin(), bg_priority_buffer_.end(), 4);

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool page = (dispcnt & (1u << 4)) != 0;
  const uint32_t page_base = page ? 0xA000u : 0u;

  for (int y = 0; y < 128; ++y) {
    for (int x = 0; x < 160; ++x) {
      uint16_t val = Read16(0x06000000 + page_base + (y * 160 + x) * 2);
      frame_buffer_[y * 240 + x] = Bgr555ToRgba8888(val);
      bg_priority_buffer_[y * 240 + x] = ReadIO16(0x0400000Cu) & 3;
      bg_layer_buffer_[y * 240 + x] = 2;
    }
  }
}

void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if (!(dispcnt & (1u << 12))) return;
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const bool obj_1d = (dispcnt & (1u << 6)) != 0;

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},
  };

  EnsureObjDrawnMaskBufferSize();
  std::fill(obj_drawn_mask_buffer_.begin(), obj_drawn_mask_buffer_.end(), 0);

  for (int i = 127; i >= 0; --i) {
    uint32_t off = i * 8;
    uint16_t a0 = Read16(0x07000000 + off);
    uint16_t a1 = Read16(0x07000000 + off + 2);
    uint16_t a2 = Read16(0x07000000 + off + 4);

    int mode = (a0 >> 8) & 3;
    if (mode == 2) continue; // Handled by BuildObjWindowMask
    bool affine = (a0 >> 8) & 1;
    if (!affine && (a0 & 0x200)) continue; // Disabled

    int shape = (a0 >> 14) & 3;
    int size = (a1 >> 14) & 3;
    if (shape >= 3) continue;
    int src_w = kObjDim[shape][size][0];
    int src_h = kObjDim[shape][size][1];
    bool double_size = affine && (a0 & 0x200);
    int draw_w = double_size ? src_w * 2 : src_w;
    int draw_h = double_size ? src_h * 2 : src_h;

    int y0 = a0 & 0xFF; if (y0 >= 160) y0 -= 256;
    int x0 = a1 & 0x1FF; if (x0 >= 240) x0 -= 512;
    bool color256 = (a0 & 0x2000) != 0;
    bool mosaic = (a0 & 0x1000) != 0;
    bool hf = !affine && (a1 & 0x1000);
    bool vf = !affine && (a1 & 0x2000);
    int prio = (a2 >> 10) & 3;
    int pal = (a2 >> 12) & 0xF;
    uint16_t tid_base = a2 & 0x3FF;

    int16_t pa=256, pb=0, pc=0, pd=256;
    if (affine) {
        int p_idx = (a1 >> 9) & 0x1F;
        pa = static_cast<int16_t>(Read16(0x07000000 + p_idx * 32 + 6));
        pb = static_cast<int16_t>(Read16(0x07000000 + p_idx * 32 + 14));
        pc = static_cast<int16_t>(Read16(0x07000000 + p_idx * 32 + 22));
        pd = static_cast<int16_t>(Read16(0x07000000 + p_idx * 32 + 30));
    }

    for (int py = 0; py < draw_h; ++py) {
      int sy = y0 + py; if (sy < 0 || sy >= 160) continue;
      for (int px = 0; px < draw_w; ++px) {
        int sx = x0 + px; if (sx < 0 || sx >= 240) continue;
        const size_t fb_off = static_cast<size_t>(sy) * 240 + sx;
        if (prio > bg_priority_buffer_[fb_off]) continue;

        int tx, ty;
        if (affine) {
            int dx = px - draw_w/2, dy = py - draw_h/2;
            tx = src_w/2 + ((pa * dx + pb * dy) >> 8);
            ty = src_h/2 + ((pc * dx + pd * dy) >> 8);
            if (tx < 0 || tx >= src_w || ty < 0 || ty >= src_h) continue;
        } else {
            tx = hf ? src_w-1-px : px;
            ty = vf ? src_h-1-py : py;
        }

        uint16_t cidx = 0;
        int t_x = tx / 8, t_y = ty / 8;
        int i_x = tx % 8, i_y = ty % 8;
        uint32_t t_off = obj_1d ? (t_y * (src_w / 8) + t_x) * (color256 ? 2 : 1) : (t_y * 32 + t_x * (color256 ? 2 : 1));
        uint16_t tid = (tid_base + t_off) & 0x3FF;

        if (color256) {
            cidx = Read8(0x06010000 + tid * 32 + i_y * 8 + i_x);
            if (!cidx) continue;
        } else {
            uint8_t packed = Read8(0x06010000 + tid * 32 + i_y * 4 + i_x/2);
            uint8_t nib = (i_x & 1) ? (packed >> 4) : (packed & 0xF);
            if (!nib) continue;
            cidx = pal * 16 + nib;
        }

        uint32_t opx = Bgr555ToRgba8888(Read16(0x05000200 + cidx * 2));
        if (mode == 1) { // semi-transparent
            uint32_t under = (obj_drawn_mask_buffer_[fb_off]) ? frame_buffer_[fb_off] : (bg_priority_buffer_[fb_off] == 4 ? Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_)) : bg_base_color_buffer_[fb_off]);
            uint8_t r1 = (opx >> 16) & 0xFF, g1 = (opx >> 8) & 0xFF, b1 = opx & 0xFF;
            uint8_t r2 = (under >> 16) & 0xFF, g2 = (under >> 8) & 0xFF, b2 = under & 0xFF;
            opx = 0xFF000000u | (ClampToByteLocal((r1 * eva + r2 * evb) / 16) << 16) | (ClampToByteLocal((g1 * eva + g2 * evb) / 16) << 8) | ClampToByteLocal((b1 * eva + b2 * evb) / 16);
        }
        frame_buffer_[fb_off] = opx;
        bg_priority_buffer_[fb_off] = prio;
        obj_drawn_mask_buffer_[fb_off] = 1;
      }
    }
  }
}

void GBACore::BuildObjWindowMask() {
    EnsureObjWindowMaskBufferSize();
    std::fill(obj_window_mask_buffer_.begin(), obj_window_mask_buffer_.end(), 0);
    // (Simplified)
}

} // namespace gba
