#ifndef GBA_CORE_PPU_COMMON_IMPL
#define GBA_CORE_PPU_COMMON_IMPL

#include "../gba_core.h"
#include <algorithm>

namespace gba {

uint8_t GBACore::GBACore::ClampToByteLocal(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}



std::vector<uint8_t>& GBACore::BgPriorityBuffer() { return bg_priority_buffer_; }
std::vector<uint8_t>& GBACore::BgLayerBuffer() { return bg_layer_buffer_; }
std::vector<uint32_t>& GBACore::BgBaseColorBuffer() { return bg_base_color_buffer_; }
std::vector<uint32_t>& GBACore::BgSecondColorBuffer() { return bg_second_color_buffer_; }
std::vector<uint8_t>& GBACore::BgSecondLayerBuffer() { return bg_second_layer_buffer_; }
std::vector<uint8_t>& GBACore::ObjWindowMaskBuffer() const { return const_cast<std::vector<uint8_t>&>(obj_window_mask_buffer_); }
std::vector<uint8_t>& GBACore::ObjDrawnMaskBuffer() { return obj_drawn_mask_buffer_; }

void GBACore::EnsureBgPriorityBufferSize() {
  auto& buffer = BgPriorityBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, static_cast<uint8_t>(GBACore::kBackdropPriority));
  }
}

void GBACore::EnsureBgLayerBufferSize() {
  auto& buffer = BgLayerBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, GBACore::kLayerBackdrop);
  } else {
    std::fill(buffer.begin(), buffer.end(), GBACore::kLayerBackdrop);
  }
}

void GBACore::EnsureBgBaseColorBufferSize() {
  auto& buffer = BgBaseColorBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0xFF000000u);
  }
}

void GBACore::EnsureBgSecondBuffersSize() {
  auto& color = BgSecondColorBuffer();
  auto& layer = BgSecondLayerBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * kScreenHeight;
  if (color.size() != required) {
    color.assign(required, 0xFF000000u);
  } else {
    std::fill(color.begin(), color.end(), 0xFF000000u);
  }
  if (layer.size() != required) {
    layer.assign(required, GBACore::kLayerBackdrop);
  } else {
    std::fill(layer.begin(), layer.end(), GBACore::kLayerBackdrop);
  }
}

void GBACore::EnsureObjDrawnMaskBufferSize() {
  auto& buffer = ObjDrawnMaskBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

void GBACore::EnsureObjWindowMaskBufferSize() {
  auto& buffer = ObjWindowMaskBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

uint32_t GBACore::Bgr555ToRgba8888(uint16_t bgr) {
  const uint8_t r5 = static_cast<uint8_t>((bgr >> 0) & 0x1F);
  const uint8_t g5 = static_cast<uint8_t>((bgr >> 5) & 0x1F);
  const uint8_t b5 = static_cast<uint8_t>((bgr >> 10) & 0x1F);
  const uint8_t r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
  const uint8_t g = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
  const uint8_t b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
  return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
         (static_cast<uint32_t>(g) << 8) | b;
}

uint16_t GBACore::ReadBackdropBgr(const std::array<uint8_t, 1024>& palette_ram) {
  return static_cast<uint16_t>(palette_ram[0]) |
         static_cast<uint16_t>(palette_ram[1] << 8);
}

bool GBACore::IsWithinWindowAxis(int p, int start, int end, int axis_max) const {
  const int s = std::clamp(start, 0, axis_max);
  int e = std::clamp(end, 0, axis_max);
  if (s == 0 && e == 0) return false;
  if (s > e) e = axis_max;
  return p >= s && p < e;
}

uint8_t GBACore::ResolveWindowControl(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                               uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                               const std::vector<uint8_t>& obj_window_mask,
                               int x, int y) const {
  const bool win0_enabled = (dispcnt & (1u << 13)) != 0;
  const bool win1_enabled = (dispcnt & (1u << 14)) != 0;
  const bool objwin_enabled = (dispcnt & (1u << 15)) != 0;
  if (!win0_enabled && !win1_enabled && !objwin_enabled) return 0x3Fu;

  const int win0_l = (win0h >> 8) & 0xFFu;
  const int win0_r = win0h & 0xFFu;
  const int win0_t = (win0v >> 8) & 0xFFu;
  const int win0_b = win0v & 0xFFu;
  const int win1_l = (win1h >> 8) & 0xFFu;
  const int win1_r = win1h & 0xFFu;
  const int win1_t = (win1v >> 8) & 0xFFu;
  const int win1_b = win1v & 0xFFu;

  const bool in_win0 = win0_enabled && IsWithinWindowAxis(x, win0_l, win0_r, 240) &&
                       IsWithinWindowAxis(y, win0_t, win0_b, 160);
  const bool in_win1 = win1_enabled && IsWithinWindowAxis(x, win1_l, win1_r, 240) &&
                       IsWithinWindowAxis(y, win1_t, win1_b, 160);

  uint8_t control = static_cast<uint8_t>(winout & 0x3Fu);  // outside window
  if (in_win0) control = static_cast<uint8_t>(winin & 0x3Fu);
  else if (in_win1) control = static_cast<uint8_t>((winin >> 8) & 0x3Fu);
  else if (objwin_enabled) {
    const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
    if (off < obj_window_mask.size() && obj_window_mask[off] != 0) {
      control = static_cast<uint8_t>((winout >> 8) & 0x3Fu);
    }
  }
  return control;
}

bool GBACore::IsBgVisibleByWindow(uint8_t control, int bg) const {
  return (control & (1u << bg)) != 0;
}

bool GBACore::IsBgVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                           uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                           int bg, int x, int y) const {
  const uint8_t control = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
  return IsBgVisibleByWindow(control, bg);
}

bool GBACore::IsObjVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                            uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                            int x, int y) const {
  const uint8_t control = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
  return (control & (1u << 4)) != 0;
}

uint16_t GBACore::LayerToBlendMask(uint8_t layer, bool top_is_obj) {
  if (top_is_obj) return static_cast<uint16_t>(1u << 4);
  if (layer <= GBACore::kLayerBg3) return static_cast<uint16_t>(1u << layer);
  return static_cast<uint16_t>(1u << 5);
}

}  // namespace gba

#endif  // GBA_CORE_PPU_COMMON_IMPL
