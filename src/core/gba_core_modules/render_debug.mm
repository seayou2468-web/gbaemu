#include "../gba_core.h"
// #include "./ppu_common.mm"

namespace gba {

void GBACore::ApplyColorEffects() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint16_t bldy = ReadIO16(0x04000054u);
  const uint32_t mode = (bldcnt >> 6) & 0x3u;
  if (mode == 0u) return;

  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));

  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  auto& bg_base = BgBaseColorBuffer();
  auto& bg_second = BgSecondColorBuffer();
  auto& bg_second_layer = BgSecondLayerBuffer();

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      const uint8_t win_ctrl = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, obj_window_mask_buffer_, x, y);
      if (!(win_ctrl & (1u << 5))) continue;

      const bool top_is_obj = (obj_drawn[fb_off] != 0u);
      const uint8_t top_layer = bg_layer[fb_off];
      const uint16_t top_mask = top_is_obj ? (1u << 4) : (top_layer == 4 ? (1u << 5) : (1u << top_layer));

      if (!(bldcnt & top_mask)) continue;

      uint32_t& px = frame_buffer_[fb_off];
      uint8_t r1 = (px >> 16) & 0xFF, g1 = (px >> 8) & 0xFF, b1 = px & 0xFF;

      if (mode == 1u) { // Alpha blend
        uint32_t under_px = backdrop;
        uint16_t bot_mask = (1u << (8 + 5));
        if (top_is_obj) {
           if (bg_priority[fb_off] != 4) {
             under_px = bg_base[fb_off];
             bot_mask = (1u << (8 + bg_layer[fb_off]));
           }
        } else {
           if (bg_second_layer[fb_off] != 4) {
             under_px = bg_second[fb_off];
             bot_mask = (1u << (8 + bg_second_layer[fb_off]));
           }
        }
        if (!(bldcnt & bot_mask)) continue;
        uint8_t r2 = (under_px >> 16) & 0xFF, g2 = (under_px >> 8) & 0xFF, b2 = under_px & 0xFF;
        px = 0xFF000000u | (ClampToByteLocal((r1 * eva + r2 * evb) / 16) << 16) |
                          (ClampToByteLocal((g1 * eva + g2 * evb) / 16) << 8) |
                           ClampToByteLocal((b1 * eva + b2 * evb) / 16);
      } else if (mode == 2u) { // Brighten
        px = 0xFF000000u | (ClampToByteLocal(r1 + ((255 - r1) * evy) / 16) << 16) |
                          (ClampToByteLocal(g1 + ((255 - g1) * evy) / 16) << 8) |
                           ClampToByteLocal(b1 + ((255 - b1) * evy) / 16);
      } else if (mode == 3u) { // Darken
        px = 0xFF000000u | (ClampToByteLocal(r1 - (r1 * evy) / 16) << 16) |
                          (ClampToByteLocal(g1 - (g1 * evy) / 16) << 8) |
                           ClampToByteLocal(b1 - (b1 * evy) / 16);
      }
    }
  }
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 7)) != 0) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), 0xFFFFFFFFu);
    EnsureBgPriorityBufferSize();
    std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
              static_cast<uint8_t>(GBACore::kBackdropPriority));
    return;
  }
  EnsureObjDrawnMaskBufferSize();
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
            static_cast<uint8_t>(GBACore::kBackdropPriority));
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
