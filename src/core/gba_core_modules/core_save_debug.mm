#include "../gba_core.h"
#include "../../debug/trace.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::LoadSaveRAM(const std::vector<uint8_t>& data) {
  size_t copy_size = std::min(data.size(), sram_.size());
  std::copy(data.begin(), data.begin() + copy_size, sram_.begin());
  // If eeprom size is needed, we should handle that as well
}

std::vector<uint8_t> GBACore::ExportBackupData() const {
  // Return the content of SRAM/EEPROM/Flash
  // For now just SRAM
  return std::vector<uint8_t>(sram_.begin(), sram_.end());
}

uint64_t GBACore::ComputeFrameHash() const {
  uint64_t hash = 0xCBF29CE484222325ULL;
  for (uint32_t p : frame_buffer_) {
    hash ^= static_cast<uint64_t>(p);
    hash *= 0x100000001B3ULL;
  }
  return hash;
}

bool GBACore::ValidateFrameBuffer(std::string* error) const {
  if (frame_buffer_.size() != kScreenWidth * kScreenHeight) {
    if (error) *error = "Frame buffer size mismatch";
    return false;
  }
  // Check for some invalid colors or anomalies if needed
  return true;
}

void GBACore::RenderDebugFrame() {
  // Logic to render debug information like tiles or sprites in frame buffer
  // This is used for development/troubleshooting
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF00FF00); // placeholder: green
}

} // namespace gba
