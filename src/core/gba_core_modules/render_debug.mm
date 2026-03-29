#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {

void GBACore::ApplyColorEffects() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u), winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u), win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u), win1v = ReadIO16(0x04000046u);
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint16_t bldy = ReadIO16(0x04000054u);
  const uint32_t mode = (bldcnt >> 6) & 0x3u;
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);

  auto& bg_layer = BgLayerBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer(); auto& obj_semi = ObjSemiTransMaskBuffer();
  auto& bg_base = BgBaseColorBuffer(); auto& bg_sec = BgSecondColorBuffer();
  auto& bg_sec_layer = BgSecondLayerBuffer();
  const size_t required = static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight);
  if (bg_layer.size() != required) EnsureBgLayerBufferSize();
  if (obj_drawn.size() != required) EnsureObjDrawnMaskBufferSize();
  if (obj_semi.size() != required) EnsureObjSemiTransMaskBufferSize();
  if (bg_base.size() != required) EnsureBgBaseColorBufferSize();
  if (bg_sec.size() != required || bg_sec_layer.size() != required) EnsureBgSecondBuffersSize();

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

    if (effect == 1) { // Alpha Blending
      uint8_t bot_l = (top_is_obj) ? bg_layer[i] : bg_sec_layer[i];
      uint16_t bot_m = 1 << (8 + bot_l);
      if (!(bldcnt & bot_m)) continue;

      uint32_t bot_color = (top_is_obj) ? bg_base[i] : bg_sec[i];
      frame_buffer_[i] = AlphaBlendLocal(top_color, bot_color, bldalpha);
    } else {
      if (effect == 2) { // Brighten
        r += ((255 - r) * evy) >> 4; g += ((255 - g) * evy) >> 4; b += ((255 - b) * evy) >> 4;
      } else if (effect == 3) { // Darken
        r -= (r * evy) >> 4; g -= (g * evy) >> 4; b -= (b * evy) >> 4;
      }
      frame_buffer_[i] = 0xFF000000 | (static_cast<uint32_t>(r) << 16) | (static_cast<uint32_t>(g) << 8) | static_cast<uint32_t>(b);
    }
  }
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const bool forced_blank = (dispcnt & (1u << 7)) != 0;
  if (forced_blank) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), 0xFFFFFFFFu);
    EnsureBgPriorityBufferSize();
    std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
              static_cast<uint8_t>(kBackdropPriority));
    return;
  }
  EnsureObjDrawnMaskBufferSize();
  EnsureObjSemiTransMaskBufferSize();
  EnsureBgBaseColorBufferSize();
  EnsureBgSecondBuffersSize();
  BuildObjWindowMask();
  const uint16_t bg_mode = dispcnt & 0x7u;
  if (bg_mode == 0u) {
    RenderMode0Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 1u) {
    RenderMode1Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 2u) {
    RenderMode2Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 3u) {
    RenderMode3Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 4u) {
    RenderMode4Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 5u) {
    RenderMode5Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  EnsureBgPriorityBufferSize();
  std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
            static_cast<uint8_t>(kBackdropPriority));
}

uint64_t GBACore::ComputeFrameHash() const {
  uint64_t hash = 1469598103934665603ULL;
  constexpr uint64_t kPrime = 1099511628211ULL;

  for (uint32_t px : frame_buffer_) {
    hash ^= px;
    hash *= kPrime;
  }
  hash ^= static_cast<uint64_t>(gameplay_state_.player_x) << 1;
  hash ^= static_cast<uint64_t>(gameplay_state_.player_y) << 9;
  hash ^= static_cast<uint64_t>(gameplay_state_.score) << 17;
  return hash;
}

bool GBACore::ValidateFrameBuffer(std::string* error) const {
  const size_t expected_size = static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight);
  if (frame_buffer_.size() != expected_size) {
    if (error) *error = "Invalid framebuffer size.";
    return false;
  }

  uint32_t first_px = 0;
  bool first_px_set = false;
  bool found_distinct_pixel = false;
  uint32_t row_xor_accum = 0;

  for (int y = 0; y < kScreenHeight; ++y) {
    uint32_t row_hash = 2166136261u;
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if ((px & 0xFF000000u) != 0xFF000000u) {
        if (error) *error = "Found pixel with invalid alpha channel.";
        return false;
      }
      row_hash ^= px;
      row_hash *= 16777619u;
    }

    row_xor_accum ^= row_hash;

    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if (!first_px_set) {
        first_px = px;
        first_px_set = true;
      } else if (px != first_px) {
        found_distinct_pixel = true;
      }
    }
  }

  if (!found_distinct_pixel) {
    if (error) *error = "Framebuffer has no visible variation (all pixels identical).";
    return false;
  }
  if (row_xor_accum == 0u) {
    if (error) *error = "Framebuffer row signatures collapsed unexpectedly.";
    return false;
  }
  return true;
}


}  // namespace gba

// ---- END gba_core_ppu.cpp ----
