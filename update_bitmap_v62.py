import sys
import re

path = "src/core/gba_core_modules/ppu_bitmap_obj.mm"
with open(path, "r") as f:
    full_content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# 1. Mode 3: 240x160 15-bit color
mode3_body = """void GBACore::RenderMode3Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t off = static_cast<size_t>(y * kScreenWidth + x);
      const uint32_t vram_off = off * 2;
      const uint16_t bgr = static_cast<uint16_t>(vram_[vram_off]) | (static_cast<uint16_t>(vram_[vram_off+1]) << 8);
      frame_buffer_[off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[off] = 3; // Mode 3 has BG2 at priority 3
      BgLayerBuffer()[off] = 2;
    }
  }
}"""

# 2. Mode 4: 240x160 8-bit palette index
mode4_body = """void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint32_t page_base = (dispcnt & 0x10) ? 0xA000 : 0;
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t off = static_cast<size_t>(y * kScreenWidth + x);
      const uint8_t idx = vram_[page_base + off];
      const size_t pal_off = static_cast<size_t>(idx) * 2;
      const uint16_t bgr = static_cast<uint16_t>(palette_ram_[pal_off]) | (static_cast<uint16_t>(palette_ram_[pal_off+1]) << 8);
      frame_buffer_[off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[off] = 3;
      BgLayerBuffer()[off] = 2;
    }
  }
}"""

# 3. Mode 5: 160x128 15-bit color (centered)
mode5_body = """void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize(); EnsureBgLayerBufferSize(); EnsureBgSecondBuffersSize();
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  const uint16_t dispcnt = ReadIO16(0x04000000);
  const uint32_t page_base = (dispcnt & 0x10) ? 0xA000 : 0;

  for (int y = 0; y < 128; ++y) {
    for (int x = 0; x < 160; ++x) {
      const size_t off = static_cast<size_t>(y * 160 + x);
      const uint32_t vram_off = page_base + off * 2;
      const uint16_t bgr = static_cast<uint16_t>(vram_[vram_off]) | (static_cast<uint16_t>(vram_[vram_off+1]) << 8);
      const int target_x = x + (240-160)/2;
      const int target_y = y + (160-128)/2;
      const size_t fb_off = static_cast<size_t>(target_y * kScreenWidth + target_x);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr);
      BgPriorityBuffer()[fb_off] = 3;
      BgLayerBuffer()[fb_off] = 2;
    }
  }
}"""

content = replace_func(full_content, "RenderMode3Frame", mode3_body)
content = replace_func(content, "RenderMode4Frame", mode4_body)
content = replace_func(content, "RenderMode5Frame", mode5_body)

with open(path, "w") as f:
    f.write(content)
