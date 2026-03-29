import sys
import re

path = "src/core/gba_core_modules/ppu_bitmap_obj.mm"
with open(path, "r") as f:
    content = f.read()

# Fix OBJ 2D mapping for 256 colors as per reference
# "2Dマッピング (0): スプライトが複数タイルで構成される場合、垂直方向の隣接タイルをメモリ上の行から計算する"
# Real hardware 2D mapping uses 32-tile stride.
# For 256-color sprites, tile indices are doubled.

new_sample_obj = """bool SampleObjColorIndex(const std::array<uint8_t, 96 * 1024>& vram, size_t obj_chr_base,
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
}"""

content = re.sub(r"bool SampleObjColorIndex\(.*?\)\s*\{.*?^\}", new_sample_obj, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
