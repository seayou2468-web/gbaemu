#include "../gba_core.h"
#include <algorithm>

namespace gba {

void GBACore::RenderMode0Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));

  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  std::fill(bg_priority_buffer_.begin(), bg_priority_buffer_.end(), 4);
  std::fill(bg_layer_buffer_.begin(), bg_layer_buffer_.end(), 4);

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0; *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(0x04000008u + bg * 2);
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16384;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2048;
    const bool color256 = (bgcnt & 0x80) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 3;
    const uint16_t hofs = ReadIO16(0x04000010u + bg * 4) & 511;
    const uint16_t vofs = ReadIO16(0x04000012u + bg * 4) & 511;
    int map_w = (screen_size & 1) ? 512 : 256;
    int map_h = (screen_size & 2) ? 512 : 256;
    int sx = (x + hofs) % map_w;
    int sy = (y + vofs) % map_h;
    int tx = sx / 8, ty = sy / 8;
    int px = sx % 8, py = sy % 8;
    int screenblock = 0;
    if (screen_size == 1) screenblock = tx / 32;
    else if (screen_size == 2) screenblock = ty / 32;
    else if (screen_size == 3) screenblock = (ty / 32) * 2 + (tx / 32);
    const size_t se_off = screen_base + screenblock * 2048 + ((ty % 32) * 32 + (tx % 32)) * 2;
    uint16_t se = Read16(0x06000000 + se_off);
    uint16_t tid = se & 0x3FF;
    bool hf = se & 0x400, vf = se & 0x800;
    int pal = (se >> 12) & 0xF;
    int cpx = hf ? 7 - px : px, cpy = vf ? 7 - py : py;
    if (color256) {
        uint8_t idx = Read8(0x06000000 + char_base + tid * 64 + cpy * 8 + cpx);
        if (idx) { *out_idx = idx; *out_opaque = true; }
    } else {
        uint8_t packed = Read8(0x06000000 + char_base + tid * 32 + cpy * 4 + cpx / 2);
        uint8_t idx = (cpx & 1) ? (packed >> 4) : (packed & 0xF);
        if (idx) { *out_idx = pal * 16 + idx; *out_opaque = true; }
    }
  };

  for (int y = 0; y < 160; ++y) {
    for (int x = 0; x < 240; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * 240 + x;
      for (int bg = 3; bg >= 0; --bg) {
        if (!(dispcnt & (1 << (8 + bg)))) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) continue;
        uint16_t bgcnt = ReadIO16(0x04000008u + bg * 2);
        uint8_t prio = bgcnt & 3;
        uint16_t idx; bool opaque;
        sample_text_bg(bg, x, y, &idx, &opaque);
        if (opaque && prio <= bg_priority_buffer_[fb_off]) {
          if (prio == bg_priority_buffer_[fb_off] && bg >= bg_layer_buffer_[fb_off]) continue;
          frame_buffer_[fb_off] = Bgr555ToRgba8888(Read16(0x05000000 + idx * 2));
          bg_priority_buffer_[fb_off] = prio;
          bg_layer_buffer_[fb_off] = bg;
        }
      }
    }
  }
}

void GBACore::RenderMode1Frame() {
  RenderMode0Frame();
}

void GBACore::RenderMode2Frame() {
  RenderMode0Frame();
}

} // namespace gba
