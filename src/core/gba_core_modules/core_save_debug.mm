#include "../gba_core.h"

#include <cstring>

namespace gba {

uint64_t GBACore::ComputeFrameHash() const {
  uint64_t h = 1469598103934665603ull;
  for (uint32_t px : frame_buffer_) {
    h ^= px;
    h *= 1099511628211ull;
  }
  return h;
}

bool GBACore::ValidateFrameBuffer(std::string* error) const {
  if (frame_buffer_.size() != static_cast<size_t>(kScreenWidth * kScreenHeight)) {
    if (error) *error = "frame buffer size mismatch";
    return false;
  }
  return true;
}

std::vector<uint8_t> GBACore::SaveStateBlob() const {
  struct StateHeader { uint32_t magic; uint32_t version; uint64_t frame; } h{0x47534156u, 1u, frame_count_};
  std::vector<uint8_t> out(sizeof(h) + ewram_.size() + iwram_.size() + io_regs_.size());
  size_t off = 0;
  std::memcpy(out.data() + off, &h, sizeof(h)); off += sizeof(h);
  std::memcpy(out.data() + off, ewram_.data(), ewram_.size()); off += ewram_.size();
  std::memcpy(out.data() + off, iwram_.data(), iwram_.size()); off += iwram_.size();
  std::memcpy(out.data() + off, io_regs_.data(), io_regs_.size());
  return out;
}

bool GBACore::LoadStateBlob(const std::vector<uint8_t>& blob, std::string* error) {
  struct StateHeader { uint32_t magic; uint32_t version; uint64_t frame; } h{};
  const size_t need = sizeof(h) + ewram_.size() + iwram_.size() + io_regs_.size();
  if (blob.size() < need) { if (error) *error = "state blob too small"; return false; }
  size_t off = 0;
  std::memcpy(&h, blob.data() + off, sizeof(h)); off += sizeof(h);
  if (h.magic != 0x47534156u) { if (error) *error = "invalid state magic"; return false; }
  std::memcpy(ewram_.data(), blob.data() + off, ewram_.size()); off += ewram_.size();
  std::memcpy(iwram_.data(), blob.data() + off, iwram_.size()); off += iwram_.size();
  std::memcpy(io_regs_.data(), blob.data() + off, io_regs_.size());
  frame_count_ = h.frame;
  return true;
}

uint8_t GBACore::DebugRead8(uint32_t addr) const { return Read8(addr); }
uint16_t GBACore::DebugRead16(uint32_t addr) const { return Read16(addr); }
uint32_t GBACore::DebugRead32(uint32_t addr) const { return Read32(addr); }
void GBACore::DebugWrite8(uint32_t addr, uint8_t value) { Write8(addr, value); }
void GBACore::DebugWrite16(uint32_t addr, uint16_t value) { Write16(addr, value); }
void GBACore::DebugWrite32(uint32_t addr, uint32_t value) { Write32(addr, value); }
void GBACore::DebugStepCpuInstructions(uint32_t count) { while (count--) RunCpuSlice(1); }

}  // namespace gba
