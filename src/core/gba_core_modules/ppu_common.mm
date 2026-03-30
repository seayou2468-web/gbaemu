#ifndef GBA_CORE_PPU_COMMON_IMPL
#define GBA_CORE_PPU_COMMON_IMPL

// ---- BEGIN gba_core_ppu.cpp ----
#include "../gba_core.h"

#include <algorithm>

namespace gba {
namespace {
uint8_t ClampToByteLocal(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}

constexpr int kBackdropPriority = 4;
constexpr uint8_t kLayerBg0 = 0;
constexpr uint8_t kLayerBg1 = 1;
constexpr uint8_t kLayerBg2 = 2;
constexpr uint8_t kLayerBg3 = 3;
constexpr uint8_t kLayerBackdrop = 4;

// NOTE:
// This file is text-included from multiple translation units. Function-local
// statics here would create one buffer per TU, breaking compositor state
// sharing between BG/OBJ/effects passes. Use C++17 inline variables so all TUs
// share exactly one instance program-wide.
inline std::vector<uint8_t> g_bg_priority_buffer;
inline std::vector<uint8_t> g_obj_window_mask_buffer;
inline std::vector<uint8_t> g_obj_drawn_mask_buffer;
inline std::vector<uint8_t> g_obj_semitrans_mask_buffer;
inline std::vector<uint8_t> g_bg_layer_buffer;
inline std::vector<uint32_t> g_bg_base_color_buffer;
inline std::vector<uint32_t> g_bg_second_color_buffer;
inline std::vector<uint8_t> g_bg_second_layer_buffer;
inline std::vector<uint8_t> g_obj_priority_buffer;
inline std::vector<uint8_t> g_obj_index_buffer;

std::vector<uint8_t>& BgPriorityBuffer() {
  return g_bg_priority_buffer;
}

void EnsureBgPriorityBufferSize() {
  auto& buffer = BgPriorityBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, static_cast<uint8_t>(kBackdropPriority));
  } else {
    std::fill(buffer.begin(), buffer.end(), static_cast<uint8_t>(kBackdropPriority));
  }
}

std::vector<uint8_t>& ObjWindowMaskBuffer() {
  return g_obj_window_mask_buffer;
}

std::vector<uint8_t>& ObjDrawnMaskBuffer() {
  return g_obj_drawn_mask_buffer;
}

std::vector<uint8_t>& ObjSemiTransMaskBuffer() {
  return g_obj_semitrans_mask_buffer;
}

std::vector<uint8_t>& BgLayerBuffer() {
  return g_bg_layer_buffer;
}

std::vector<uint32_t>& BgBaseColorBuffer() {
  return g_bg_base_color_buffer;
}

std::vector<uint32_t>& BgSecondColorBuffer() {
  return g_bg_second_color_buffer;
}

std::vector<uint8_t>& ObjPriorityBuffer() { return g_obj_priority_buffer; }
std::vector<uint8_t>& ObjIndexBuffer() { return g_obj_index_buffer; }

void EnsureObjPriorityBuffersSize() {
  const size_t req = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (g_obj_priority_buffer.size() != req) g_obj_priority_buffer.assign(req, 4u);
  else std::fill(g_obj_priority_buffer.begin(), g_obj_priority_buffer.end(), 4u);
  if (g_obj_index_buffer.size() != req) g_obj_index_buffer.assign(req, 255u);
  else std::fill(g_obj_index_buffer.begin(), g_obj_index_buffer.end(), 255u);
}

std::vector<uint8_t>& BgSecondLayerBuffer() {
  return g_bg_second_layer_buffer;
}

void EnsureBgLayerBufferSize() {
  auto& buffer = BgLayerBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, kLayerBackdrop);
  } else {
    std::fill(buffer.begin(), buffer.end(), kLayerBackdrop);
  }
}

void EnsureBgBaseColorBufferSize() {
  auto& buffer = BgBaseColorBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0xFF000000u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0xFF000000u);
  }
}

void EnsureBgSecondBuffersSize() {
  auto& color = BgSecondColorBuffer();
  auto& layer = BgSecondLayerBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (color.size() != required) {
    color.assign(required, 0xFF000000u);
  } else {
    std::fill(color.begin(), color.end(), 0xFF000000u);
  }
  if (layer.size() != required) {
    layer.assign(required, kLayerBackdrop);
  } else {
    std::fill(layer.begin(), layer.end(), kLayerBackdrop);
  }
}

void EnsureObjDrawnMaskBufferSize() {
  auto& buffer = ObjDrawnMaskBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

void EnsureObjSemiTransMaskBufferSize() {
  auto& buffer = ObjSemiTransMaskBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

void EnsureObjWindowMaskBufferSize() {
  auto& buffer = ObjWindowMaskBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

uint32_t Bgr555ToRgba8888(uint16_t bgr) {
  const uint8_t r5 = static_cast<uint8_t>((bgr >> 0) & 0x1F);
  const uint8_t g5 = static_cast<uint8_t>((bgr >> 5) & 0x1F);
  const uint8_t b5 = static_cast<uint8_t>((bgr >> 10) & 0x1F);
  const uint8_t r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
  const uint8_t g = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
  const uint8_t b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
  return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
         (static_cast<uint32_t>(g) << 8) | b;
}

uint16_t ReadBackdropBgr(const std::array<uint8_t, 1024>& palette_ram) {
  return static_cast<uint16_t>(palette_ram[0]) |
         static_cast<uint16_t>(palette_ram[1] << 8);
}

bool IsWithinWindowAxis(int p, int start, int end, int axis_max) {
  const int s = std::clamp(start, 0, axis_max);
  int e = std::clamp(end, 0, axis_max);
  // GBATEK: X1>X2/Y1>Y2 are treated as X2/Y2=max; and X1=X2=0 (Y1=Y2=0)
  // disables that window axis.
  if (s == 0 && e == 0) return false;
  if (s > e) e = axis_max;
  return p >= s && p < e;
}

uint8_t ResolveWindowControl(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                         uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                         const std::vector<uint8_t>& obj_window_mask,
                         int x, int y) {
  const bool win0_enabled = (dispcnt & (1u << 13)) != 0;
  const bool win1_enabled = (dispcnt & (1u << 14)) != 0;
  const bool objwin_enabled = (dispcnt & (1u << 15)) != 0;
  if (!win0_enabled && !win1_enabled && !objwin_enabled) return 0x3Fu;

  const int win0_l = std::min<int>(240, (win0h >> 8) & 0xFFu);
  const int win0_r = std::min<int>(240, win0h & 0xFFu);
  const int win0_t = std::min<int>(160, (win0v >> 8) & 0xFFu);
  const int win0_b = std::min<int>(160, win0v & 0xFFu);
  const int win1_l = std::min<int>(240, (win1h >> 8) & 0xFFu);
  const int win1_r = std::min<int>(240, win1h & 0xFFu);
  const int win1_t = std::min<int>(160, (win1v >> 8) & 0xFFu);
  const int win1_b = std::min<int>(160, win1v & 0xFFu);

  const bool in_win0 = win0_enabled && IsWithinWindowAxis(x, win0_l, win0_r, 240) &&
                       IsWithinWindowAxis(y, win0_t, win0_b, 160);
  const bool in_win1 = win1_enabled && IsWithinWindowAxis(x, win1_l, win1_r, 240) &&
                       IsWithinWindowAxis(y, win1_t, win1_b, 160);

  uint8_t control = static_cast<uint8_t>(winout & 0xFFu);  // outside window
  if (in_win0) control = static_cast<uint8_t>(winin & 0xFFu);
  else if (in_win1) control = static_cast<uint8_t>((winin >> 8) & 0xFFu);
  else if (objwin_enabled) {
    const size_t off = static_cast<size_t>(y) * GBACore::kScreenWidth + x;
    if (off < obj_window_mask.size() && obj_window_mask[off] != 0) {
      control = static_cast<uint8_t>((winout >> 8) & 0x3Fu);
    }
  }
  return control;
}

bool IsBgVisibleByWindow(uint8_t control, int bg) {
  return (control & (1u << bg)) != 0;
}

bool IsBgVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                         uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                         int bg, int x, int y) {
  const uint8_t control =
      ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
  return IsBgVisibleByWindow(control, bg);
}

bool IsObjVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                          uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                          int x, int y) {
  const uint8_t control = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v,
                                               ObjWindowMaskBuffer(), x, y);
  return (control & (1u << 4)) != 0;
}

uint32_t AlphaBlendLocal(uint32_t top, uint32_t bot, uint16_t bldalpha) {
  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const int tr = (top >> 16) & 0xFF, tg = (top >> 8) & 0xFF, tb = top & 0xFF;
  const int br = (bot >> 16) & 0xFF, bg = (bot >> 8) & 0xFF, bb = bot & 0xFF;
  const uint8_t r = static_cast<uint8_t>(std::min(255, (tr * (int)eva + br * (int)evb) >> 4));
  const uint8_t g = static_cast<uint8_t>(std::min(255, (tg * (int)eva + bg * (int)evb) >> 4));
  const uint8_t b = static_cast<uint8_t>(std::min(255, (tb * (int)eva + bb * (int)evb) >> 4));
  return 0xFF000000u | (static_cast<uint32_t>(r) << 16) | (static_cast<uint32_t>(g) << 8) | b;
}

uint16_t LayerToBlendMask(uint8_t layer, bool top_is_obj) {
  if (top_is_obj) return static_cast<uint16_t>(1u << 4);   // OBJ
  if (layer <= kLayerBg3) return static_cast<uint16_t>(1u << layer);  // BG0..BG3
  return static_cast<uint16_t>(1u << 5);  // Backdrop
}
}  // namespace

}  // namespace gba

#endif  // GBA_CORE_PPU_COMMON_IMPL
