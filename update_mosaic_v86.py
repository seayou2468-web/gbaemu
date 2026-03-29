import sys
import re

path = "src/core/gba_core_modules/ppu_bitmap_obj.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# Implement BG Mosaic for Mode 3, 4, 5
# Background mosaic is bits 0-3 (H) and 4-7 (V) of REG_MOSAIC

mode3_body = """void GBACore::RenderMode3Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const bool mosaic = (bg2cnt & 0x40) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = (mosaic_reg & 0xF) + 1;
  const int mos_v = ((mosaic_reg >> 4) & 0xF) + 1;

  for (int y = 0; y < kScreenHeight; ++y) {
    const int sy = mosaic ? (y / mos_v) * mos_v : y;
    for (int x = 0; x < kScreenWidth; ++x) {
      const int sx = mosaic ? (x / mos_h) * mos_h : x;
      const size_t off = static_cast<size_t>(y * kScreenWidth + x);
      const size_t s_off = static_cast<size_t>(sy * kScreenWidth + sx);
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[off] = backdrop;
        BgPriorityBuffer()[off] = 4;
        BgLayerBuffer()[off] = 4;
        continue;
      }
      const uint32_t vram_off = s_off * 2;
      const uint16_t bgr = static_cast<uint16_t>(vram_[vram_off]) | (static_cast<uint16_t>(vram_[vram_off+1]) << 8);
      frame_buffer_[off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[off] = bg2cnt & 3;
      BgLayerBuffer()[off] = 2;
    }
  }
}"""

# Mode 4 and 5 follow similar logic
mode4_body = """void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const uint32_t page_base = (dispcnt & 0x10) ? 0xA000 : 0;

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const bool mosaic = (bg2cnt & 0x40) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = (mosaic_reg & 0xF) + 1;
  const int mos_v = ((mosaic_reg >> 4) & 0xF) + 1;

  for (int y = 0; y < kScreenHeight; ++y) {
    const int sy = mosaic ? (y / mos_v) * mos_v : y;
    for (int x = 0; x < kScreenWidth; ++x) {
      const int sx = mosaic ? (x / mos_h) * mos_h : x;
      const size_t off = static_cast<size_t>(y * kScreenWidth + x);
      const size_t s_off = static_cast<size_t>(sy * kScreenWidth + sx);
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[off] = backdrop;
        BgPriorityBuffer()[off] = 4;
        continue;
      }
      const uint8_t idx = vram_[page_base + s_off];
      const size_t pal_off = static_cast<size_t>(idx) * 2;
      const uint16_t bgr = static_cast<uint16_t>(palette_ram_[pal_off]) | (static_cast<uint16_t>(palette_ram_[pal_off+1]) << 8);
      frame_buffer_[off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[off] = bg2cnt & 3;
      BgLayerBuffer()[off] = 2;
    }
  }
}"""

mode5_body = """void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  const uint32_t page_base = (dispcnt & 0x10) ? 0xA000 : 0;

  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const bool mosaic = (bg2cnt & 0x40) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = (mosaic_reg & 0xF) + 1;
  const int mos_v = ((mosaic_reg >> 4) & 0xF) + 1;

  for (int y = 0; y < 128; ++y) {
    const int sy = mosaic ? (y / mos_v) * mos_v : y;
    for (int x = 0; x < 160; ++x) {
      const int sx = mosaic ? (x / mos_h) * mos_h : x;
      const int tx = x + (240-160)/2, ty = y + (160-128)/2;
      const size_t fb_off = static_cast<size_t>(ty * kScreenWidth + tx);
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, tx, ty)) continue;
      const uint32_t vram_off = page_base + static_cast<size_t>(sy * 160 + sx) * 2;
      const uint16_t bgr = static_cast<uint16_t>(vram_[vram_off]) | (static_cast<uint16_t>(vram_[vram_off+1]) << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[fb_off] = bg2cnt & 3;
      BgLayerBuffer()[fb_off] = 2;
    }
  }
}"""

content = replace_func(content, "RenderMode3Frame", mode3_body)
content = replace_func(content, "RenderMode4Frame", mode4_body)
content = replace_func(content, "RenderMode5Frame", mode5_body)

with open(path, "w") as f:
    f.write(content)
