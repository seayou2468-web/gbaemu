#include "../gba_core.h"
#include "./ppu_common.mm"

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

  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const uint8_t back_r = static_cast<uint8_t>((backdrop >> 16) & 0xFFu);
  const uint8_t back_g = static_cast<uint8_t>((backdrop >> 8) & 0xFFu);
  const uint8_t back_b = static_cast<uint8_t>(backdrop & 0xFFu);
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  auto& obj_semitrans = ObjSemiTransMaskBuffer();
  auto& bg_base = BgBaseColorBuffer();
  auto& bg_second = BgSecondColorBuffer();
  auto& bg_second_layer = BgSecondLayerBuffer();
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      const uint8_t window_control =
          ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
      if ((window_control & (1u << 5)) == 0) continue;  // color effects masked by window
      const bool top_is_obj = (fb_off < obj_drawn.size()) && (obj_drawn[fb_off] != 0u);
      const bool top_is_semitrans_obj =
          top_is_obj && (fb_off < obj_semitrans.size()) && (obj_semitrans[fb_off] != 0u);
      const uint8_t top_layer = (fb_off < bg_layer.size()) ? bg_layer[fb_off] : kLayerBackdrop;
      const uint16_t top_mask = LayerToBlendMask(top_layer, top_is_obj);
      const uint32_t effect_mode = top_is_semitrans_obj ? 1u : mode;
      if (effect_mode == 0u) continue;
      if (!top_is_semitrans_obj && (bldcnt & top_mask) == 0) continue;  // top pixel is not 1st target

      uint32_t& px = frame_buffer_[fb_off];
      uint8_t r = static_cast<uint8_t>((px >> 16) & 0xFFu);
      uint8_t g = static_cast<uint8_t>((px >> 8) & 0xFFu);
      uint8_t b = static_cast<uint8_t>(px & 0xFFu);
      if (effect_mode == 1u) {
        uint8_t sr = back_r;
        uint8_t sg = back_g;
        uint8_t sb = back_b;
        uint16_t second_mask = static_cast<uint16_t>(1u << (8 + 5));  // backdrop
        if (top_is_obj && fb_off < bg_base.size() && fb_off < bg_priority.size() &&
            bg_priority[fb_off] != kBackdropPriority) {
          const uint8_t under_layer = (fb_off < bg_layer.size()) ? bg_layer[fb_off] : kLayerBackdrop;
          second_mask = static_cast<uint16_t>(1u << (8u + std::min<uint8_t>(under_layer, 5u)));
          const uint32_t under = bg_base[fb_off];
          sr = static_cast<uint8_t>((under >> 16) & 0xFFu);
          sg = static_cast<uint8_t>((under >> 8) & 0xFFu);
          sb = static_cast<uint8_t>(under & 0xFFu);
        } else if (!top_is_obj && fb_off < bg_second.size() && fb_off < bg_second_layer.size() &&
                   bg_second_layer[fb_off] != kLayerBackdrop) {
          const uint8_t under_layer = bg_second_layer[fb_off];
          second_mask = static_cast<uint16_t>(1u << (8u + std::min<uint8_t>(under_layer, 5u)));
          const uint32_t under = bg_second[fb_off];
          sr = static_cast<uint8_t>((under >> 16) & 0xFFu);
          sg = static_cast<uint8_t>((under >> 8) & 0xFFu);
          sb = static_cast<uint8_t>(under & 0xFFu);
        }
        if ((bldcnt & second_mask) == 0) continue;
        r = ClampToByteLocal(static_cast<int>((r * eva + sr * evb) / 16u));
        g = ClampToByteLocal(static_cast<int>((g * eva + sg * evb) / 16u));
        b = ClampToByteLocal(static_cast<int>((b * eva + sb * evb) / 16u));
      } else if (effect_mode == 2u) {  // brighten
        r = ClampToByteLocal(static_cast<int>(r + ((255 - r) * evy) / 16u));
        g = ClampToByteLocal(static_cast<int>(g + ((255 - g) * evy) / 16u));
        b = ClampToByteLocal(static_cast<int>(b + ((255 - b) * evy) / 16u));
      } else if (effect_mode == 3u) {  // darken
        r = ClampToByteLocal(static_cast<int>(r - (r * evy) / 16u));
        g = ClampToByteLocal(static_cast<int>(g - (g * evy) / 16u));
        b = ClampToByteLocal(static_cast<int>(b - (b * evy) / 16u));
      }
      px = 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
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
