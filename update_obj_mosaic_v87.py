import sys
import re

path = "src/core/gba_core_modules/ppu_bitmap_obj.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# Ensure OBJ Mosaic uses bits 8-11 (H) and 12-15 (V) of REG_MOSAIC
sprite_body_match = re.search(r"void GBACore::RenderSprites\(\) \{(.*?)\n\}", content, flags=re.DOTALL | re.MULTILINE)
sprite_inner = sprite_body_match.group(1)

# Correct Mosaic sampling inside the loop
new_mosaic_logic = """
        int tsx = px, tsy = py;
        if (mosaic) {
          const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
          const int mos_h = ((mosaic_reg >> 8) & 0xF) + 1;
          const int mos_v = ((mosaic_reg >> 12) & 0xF) + 1;
          tsx = (px / mos_h) * mos_h;
          tsy = (py / mos_v) * mos_v;
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
"""

# Replace the previous tx/ty calculation block
sprite_inner = re.sub(r"int tx, ty;.*?if \(affine\) \{.*?\} else \{.*?\}", new_mosaic_logic, sprite_inner, flags=re.DOTALL)

content = replace_func(content, "RenderSprites", "void GBACore::RenderSprites() {" + sprite_inner + "\n}")

with open(path, "w") as f:
    f.write(content)
