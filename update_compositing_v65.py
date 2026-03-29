import sys
import re

path = "src/core/gba_core_modules/render_debug.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# Refine ApplyColorEffects with type-safe min and correct blending
apply_effects_body = """void GBACore::ApplyColorEffects() {
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint16_t bldy = ReadIO16(0x04000054u);
  const uint32_t mode = (bldcnt >> 6) & 0x3u;

  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);

  auto& bg_layer = BgLayerBuffer(); auto& bg_priority = BgPriorityBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer(); auto& obj_semi = ObjSemiTransMaskBuffer();
  auto& bg_base = BgBaseColorBuffer(); auto& bg_second = BgSecondColorBuffer();
  auto& bg_second_layer = BgSecondLayerBuffer();

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);

  for (int i = 0; i < kScreenWidth * kScreenHeight; ++i) {
    const int x = i % kScreenWidth, y = i / kScreenWidth;
    const uint8_t win_ctrl = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
    if (!(win_ctrl & 0x20)) continue;

    const bool top_is_obj = obj_drawn[i] != 0;
    const bool top_is_semi = top_is_obj && obj_semi[i];
    const uint8_t top_l = top_is_obj ? 4 : bg_layer[i];
    const uint16_t top_m = 1 << top_l;

    uint32_t effect = top_is_semi ? 1 : mode;
    if (effect == 0) continue;
    if (!top_is_semi && !(bldcnt & top_m)) continue;

    uint32_t top_color = frame_buffer_[i];
    int r = (top_color >> 16) & 0xFF, g = (top_color >> 8) & 0xFF, b = top_color & 0xFF;

    if (effect == 1) {
      uint8_t bot_l = (top_is_obj) ? bg_layer[i] : bg_second_layer[i];
      uint16_t bot_m = 1 << (8 + bot_l);
      if (!(bldcnt & bot_m)) continue;

      uint32_t bot_color = (top_is_obj) ? bg_base[i] : bg_second[i];
      int br = (bot_color >> 16) & 0xFF, bg_val = (bot_color >> 8) & 0xFF, bb = bot_color & 0xFF;

      r = std::min(255, (int)((r * eva + br * evb) >> 4));
      g = std::min(255, (int)((g * eva + bg_val * evb) >> 4));
      b = std::min(255, (int)((b * eva + bb * evb) >> 4));
    } else if (effect == 2) {
      r += ((255 - r) * evy) >> 4;
      g += ((255 - g) * evy) >> 4;
      b += ((255 - b) * evy) >> 4;
    } else if (effect == 3) {
      r -= (r * evy) >> 4;
      g -= (g * evy) >> 4;
      b -= (b * evy) >> 4;
    }
    frame_buffer_[i] = 0xFF000000 | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
  }
}"""

content = replace_func(content, "ApplyColorEffects", apply_effects_body)

with open(path, "w") as f:
    f.write(content)
