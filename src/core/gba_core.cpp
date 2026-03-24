#include "gba_core.h"

#include <algorithm>

namespace gba {
namespace {
constexpr uint32_t kCyclesPerFrame = 280896;  // 16.78MHz / 59.73Hz

constexpr uint8_t kNintendoLogo[156] = {
    0x24,0xFF,0xAE,0x51,0x69,0x9A,0xA2,0x21,0x3D,0x84,0x82,0x0A,0x84,0xE4,0x09,0xAD,
    0x11,0x24,0x8B,0x98,0xC0,0x81,0x7F,0x21,0xA3,0x52,0xBE,0x19,0x93,0x09,0xCE,0x20,
    0x10,0x46,0x4A,0x4A,0xF8,0x27,0x31,0xEC,0x58,0xC7,0xE8,0x33,0x82,0xE3,0xCE,0xBF,
    0x85,0xF4,0xDF,0x94,0xCE,0x4B,0x09,0xC1,0x94,0x56,0x8A,0xC0,0x13,0x72,0xA7,0xFC,
    0x9F,0x84,0x4D,0x73,0xA3,0xCA,0x9A,0x61,0x58,0x97,0xA3,0x27,0xFC,0x03,0x98,0x76,
    0x23,0x1D,0xC7,0x61,0x03,0x04,0xAE,0x56,0xBF,0x38,0x84,0x00,0x40,0xA7,0x0E,0xFD,
    0xFF,0x52,0xFE,0x03,0x6F,0x95,0x30,0xF1,0x97,0xFB,0xC0,0x85,0x60,0xD6,0x80,0x25,
    0xA9,0x63,0xBE,0x03,0x01,0x4E,0x38,0xE2,0xF9,0xA2,0x34,0xFF,0xBB,0x3E,0x03,0x44,
    0x78,0x00,0x90,0xCB,0x88,0x11,0x3A,0x94,0x65,0xC0,0x7C,0x63,0x87,0xF0,0x3C,0xAF,
    0xD6,0x25,0xE4,0x8B,0x38,0x0A,0xAC,0x72,0x21,0xD4,0xF8,0x07,
};

uint8_t ClampToByte(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}
}  // namespace

bool GBACore::LoadROM(const std::vector<uint8_t>& rom, std::string* error) {
  if (rom.size() < 0xC0) {
    if (error) *error = "ROM too small (needs at least 0xC0 bytes).";
    return false;
  }

  rom_ = rom;
  loaded_ = true;

  rom_info_.title = std::string(reinterpret_cast<const char*>(&rom_[0xA0]), 12);
  rom_info_.title.erase(std::find(rom_info_.title.begin(), rom_info_.title.end(), '\0'),
                        rom_info_.title.end());
  rom_info_.game_code = std::string(reinterpret_cast<const char*>(&rom_[0xAC]), 4);
  rom_info_.maker_code = std::string(reinterpret_cast<const char*>(&rom_[0xB0]), 2);
  rom_info_.fixed_value = rom_[0xB2];
  rom_info_.unit_code = rom_[0xB3];
  rom_info_.device_type = rom_[0xB4];
  rom_info_.version = rom_[0xBC];
  rom_info_.complement_check = rom_[0xBD];
  rom_info_.computed_complement_check = ComputeComplementCheck();
  rom_info_.logo_valid = ValidateNintendoLogo();
  rom_info_.complement_check_valid = (rom_info_.complement_check == rom_info_.computed_complement_check);

  if (rom_info_.fixed_value != 0x96) {
    if (error) *error = "Invalid Nintendo header fixed value at 0xB2.";
    loaded_ = false;
    return false;
  }
  // Some homebrew/test ROMs can intentionally alter logo/complement fields.
  // Keep the validity flags for diagnostics, but do not hard-fail loading.
  if (!rom_info_.logo_valid && error) {
    *error = "Warning: Nintendo logo area mismatch (0x04-0x9F).";
  }
  if (!rom_info_.complement_check_valid && error) {
    *error = "Warning: Header complement check mismatch (0xBD).";
  }

  Reset();
  return true;
}

void GBACore::Reset() {
  frame_count_ = 0;
  executed_cycles_ = 0;
  keys_pressed_mask_ = 0;
  gameplay_state_ = GameplayState{};
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  RenderDebugFrame();
}

void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;
  executed_cycles_ += cycles;
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) { keys_pressed_mask_ = keys_pressed_mask; }

void GBACore::StepFrame() {
  if (!loaded_) return;
  RunCycles(kCyclesPerFrame);
  ++frame_count_;
  UpdateGameplayFromInput();
  RenderDebugFrame();
}

uint8_t GBACore::ComputeComplementCheck() const {
  int sum = 0;
  for (size_t i = 0xA0; i <= 0xBC && i < rom_.size(); ++i) {
    sum += rom_[i];
  }
  return static_cast<uint8_t>((-sum - 0x19) & 0xFF);
}

bool GBACore::ValidateNintendoLogo() const {
  if (rom_.size() < 0xA0) return false;
  for (size_t i = 0; i < sizeof(kNintendoLogo); ++i) {
    if (rom_[0x04 + i] != kNintendoLogo[i]) {
      return false;
    }
  }
  return true;
}

void GBACore::UpdateGameplayFromInput() {
  constexpr int kStep = 2;

  if (keys_pressed_mask_ & kKeyRight) gameplay_state_.player_x += kStep;
  if (keys_pressed_mask_ & kKeyLeft) gameplay_state_.player_x -= kStep;
  if (keys_pressed_mask_ & kKeyDown) gameplay_state_.player_y += kStep;
  if (keys_pressed_mask_ & kKeyUp) gameplay_state_.player_y -= kStep;

  gameplay_state_.player_x = std::clamp(gameplay_state_.player_x, 0, kScreenWidth - 1);
  gameplay_state_.player_y = std::clamp(gameplay_state_.player_y, 0, kScreenHeight - 1);

  if (keys_pressed_mask_ & kKeyA) {
    gameplay_state_.score += 3;
  }
  if (keys_pressed_mask_ & kKeyB) {
    gameplay_state_.score += 1;
  }
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  uint32_t seed = 0;
  for (size_t i = 0; i < std::min<size_t>(rom_.size(), 256); ++i) {
    seed = (seed * 33u) ^ rom_[i];
  }
  seed ^= static_cast<uint32_t>(frame_count_ * 2654435761u);

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint8_t r = static_cast<uint8_t>((x + seed) & 0xFF);
      const uint8_t g = static_cast<uint8_t>((y + (seed >> 8)) & 0xFF);
      const uint8_t b = static_cast<uint8_t>(((x ^ y) + (seed >> 16)) & 0xFF);
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000U | (r << 16) | (g << 8) | b;
    }
  }

  for (int dy = -2; dy <= 2; ++dy) {
    for (int dx = -2; dx <= 2; ++dx) {
      const int px = gameplay_state_.player_x + dx;
      const int py = gameplay_state_.player_y + dy;
      if (px < 0 || py < 0 || px >= kScreenWidth || py >= kScreenHeight) continue;
      const uint8_t base = ClampToByte(80 + static_cast<int>(gameplay_state_.score % 175));
      frame_buffer_[py * kScreenWidth + px] =
          0xFF000000U | (255u << 16) | (base << 8) | static_cast<uint32_t>(255u - base);
    }
  }
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

}  // namespace gba
