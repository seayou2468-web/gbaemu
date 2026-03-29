import sys
import re

path = "src/core/gba_core_modules/ppu_bitmap_obj.mm"
with open(path, "r") as f:
    content = f.read()

# Improved RenderSprites with priority masking and proper sampling
sprite_body = """void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 12)) == 0) return;
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);

  EnsureBgPriorityBufferSize();
  EnsureObjDrawnMaskBufferSize(); EnsureObjSemiTransMaskBufferSize();
  auto& bg_priority = BgPriorityBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer(); auto& obj_semitrans = ObjSemiTransMaskBuffer();

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},     // square
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},     // horizontal
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},     // vertical
  };
  const bool obj_1d = (dispcnt & 0x40) != 0;
  const uint8_t bg_mode = dispcnt & 7;
  const size_t chr_base = (bg_mode >= 3) ? 0x14000u : 0x10000u;

  auto get_pal_color = [&](uint16_t idx) {
    const size_t off = (idx + 0x100) * 2;
    return Bgr555ToRgba8888(static_cast<uint16_t>(palette_ram_[off]) | (static_cast<uint16_t>(palette_ram_[off+1]) << 8));
  };

  // Render sprites from lowest to highest priority index (127 to 0)
  // so higher index ones are overwritten or checked by priority.
  // Actually, hardware renders them in order, and priority value (0-3) determines BG interaction.
  for (int i = 127; i >= 0; --i) {
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
    const uint16_t tile_base = a2 & 0x3FF;
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

        const size_t fb_off = sy * kScreenWidth + sx;
        // Priority check: higher priority (lower number) wins
        // Here we just render and overwrite, assuming order 127..0.
        // But we must also check BG priority later.

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
        if (SampleObjColorIndex(vram_, chr_base, obj_1d, color_256, sw, tx, ty, tile_base, palbank, &color_idx)) {
           if (prio <= bg_priority[fb_off]) {
              frame_buffer_[fb_off] = get_pal_color(color_idx);
              obj_drawn[fb_off] = 1;
              obj_semitrans[fb_off] = (a0 & 0x0400) ? 1 : 0;
           }
        }
      }
    }
  }
}"""

content = re.sub(r"void GBACore::RenderSprites\(\) \{.*?^\}", sprite_body, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
