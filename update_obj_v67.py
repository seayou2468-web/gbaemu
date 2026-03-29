import sys
import re

path = "src/core/gba_core_modules/ppu_bitmap_obj.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# Improved RenderSprites with priority masking, mode-specific indexing, and correct 1D mapping
sprite_body = """void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 12)) == 0) return;
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);

  EnsureBgPriorityBufferSize();
  EnsureObjDrawnMaskBufferSize(); EnsureObjSemiTransMaskBufferSize();
  EnsureObjPriorityBuffersSize(); // NEW: initialize obj priority/index buffers

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

  // Hardware renders in index order 0..127.
  // Lower OAM index has priority for same OBJ priority value.
  for (int i = 0; i < 128; ++i) {
    const size_t off = i * 8;
    const uint16_t a0 = static_cast<uint16_t>(oam_[off]) | (static_cast<uint16_t>(oam_[off+1]) << 8);
    const uint16_t a1 = static_cast<uint16_t>(oam_[off+2]) | (static_cast<uint16_t>(oam_[off+3]) << 8);
    const uint16_t a2 = static_cast<uint16_t>(oam_[off+4]) | (static_cast<uint16_t>(oam_[off+5]) << 8);

    if ((a0 & 0x0300) == 0x0200) continue; // OBJ-window
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
    const uint8_t prio = (a2 >> 10) & 3;
    // Correct tile base for Bitmap modes
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

        // Accurate Priority Check:
        // 1. Lower OBJ priority value (0-3) wins.
        // 2. Same priority: Lower OAM index wins (hardware order).
        // Since we are iterating 0..127, we only overwrite if priority is strictly better.
        if (obj_drawn[fb_off] && prio >= obj_priority_buf[fb_off]) continue;
        // Interaction with BG:
        if (prio > bg_priority[fb_off]) continue;

        int tx, ty;
        if (affine) {
           int ox = px - dw/2, oy = py - dh/2;
           tx = (pa * ox + pb * oy) >> 8; ty = (pc * ox + pd * oy) >> 8;
           tx += sw/2; ty += sh/2;
           if (tx < 0 || tx >= sw || ty < 0 || ty >= sh) continue;
        } else {
           tx = px; ty = py;
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
}"""

content = replace_func(content, "RenderSprites", sprite_body)

# Fix 1D mapping in SampleObjColorIndex as well
new_sample = """bool SampleObjColorIndex(const std::array<uint8_t, 96 * 1024>& vram, size_t obj_chr_base,
                         bool obj_1d, bool color_256, int src_w, int tx, int ty,
                         uint16_t tile_id, uint16_t palbank, uint16_t* out_color_index) {
  if (out_color_index == nullptr) return false;
  const int tile_x = tx / 8;
  const int tile_y = ty / 8;
  const int in_x = tx & 7;
  const int in_y = ty & 7;

  const int tiles_per_row = src_w / 8;
  const int row_stride_units = obj_1d ? (color_256 ? tiles_per_row * 2 : tiles_per_row) : 32;
  const uint32_t tile_base = color_256 ? static_cast<uint32_t>(tile_id & ~1u) : static_cast<uint32_t>(tile_id);
  const uint32_t tile_units = tile_base + static_cast<uint32_t>(tile_y * row_stride_units + (color_256 ? tile_x * 2 : tile_x));

  const size_t chr_base_off = obj_chr_base + static_cast<size_t>(tile_units) * 32u;
  if (chr_base_off >= vram.size()) return false;

  if (color_256) {
    const size_t chr_off = (chr_base_off + static_cast<size_t>(in_y * 8 + in_x)) % vram.size();
    const uint8_t color = vram[chr_off];
    if (color == 0u) return false;
    *out_color_index = color;
    return true;
  }

  const size_t chr_off = (chr_base_off + static_cast<size_t>(in_y * 4 + in_x / 2)) % vram.size();
  const uint8_t packed = vram[chr_off];
  const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
  if (nib == 0u) return false;
  *out_color_index = static_cast<uint16_t>(palbank * 16u + nib);
  return true;
}"""

content = re.sub(r"bool SampleObjColorIndex\(.*?\)\s*\{.*?^\}", new_sample, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
