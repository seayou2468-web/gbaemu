import sys
import re

path = "src/core/gba_core_modules/ppu_common.mm"
with open(path, "r") as f:
    content = f.read()

# 1. Add new global buffers
new_buffers = """inline std::vector<uint8_t> g_obj_priority_buffer;
inline std::vector<uint8_t> g_obj_index_buffer;"""

content = content.replace("inline std::vector<uint8_t> g_bg_second_layer_buffer;",
                          "inline std::vector<uint8_t> g_bg_second_layer_buffer;\n" + new_buffers)

# 2. Add Ensure functions for new buffers
new_ensure = """std::vector<uint8_t>& ObjPriorityBuffer() { return g_obj_priority_buffer; }
std::vector<uint8_t>& ObjIndexBuffer() { return g_obj_index_buffer; }

void EnsureObjPriorityBuffersSize() {
  const size_t req = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (g_obj_priority_buffer.size() != req) g_obj_priority_buffer.assign(req, 4u);
  else std::fill(g_obj_priority_buffer.begin(), g_obj_priority_buffer.end(), 4u);
  if (g_obj_index_buffer.size() != req) g_obj_index_buffer.assign(req, 255u);
  else std::fill(g_obj_index_buffer.begin(), g_obj_index_buffer.end(), 255u);
}"""

content = content.replace("std::vector<uint8_t>& BgSecondLayerBuffer() {",
                          new_ensure + "\n\nstd::vector<uint8_t>& BgSecondLayerBuffer() {")

# 3. Implement AlphaBlend helper (conceptual, will be used in Compositor)
# Actually, the user suggests implementing it. Let's add it to the internal namespace.
alpha_blend_helper = """uint32_t AlphaBlendLocal(uint32_t top, uint32_t bot, uint16_t bldalpha) {
  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const int tr = (top >> 16) & 0xFF, tg = (top >> 8) & 0xFF, tb = top & 0xFF;
  const int br = (bot >> 16) & 0xFF, bg = (bot >> 8) & 0xFF, bb = bot & 0xFF;
  const uint8_t r = static_cast<uint8_t>(std::min(255, (tr * (int)eva + br * (int)evb) >> 4));
  const uint8_t g = static_cast<uint8_t>(std::min(255, (tg * (int)eva + bg * (int)evb) >> 4));
  const uint8_t b = static_cast<uint8_t>(std::min(255, (tb * (int)eva + bb * (int)evb) >> 4));
  return 0xFF000000u | (static_cast<uint32_t>(r) << 16) | (static_cast<uint32_t>(g) << 8) | b;
}"""

content = content.replace("uint16_t LayerToBlendMask", alpha_blend_helper + "\n\nuint16_t LayerToBlendMask")

with open(path, "w") as f:
    f.write(content)
