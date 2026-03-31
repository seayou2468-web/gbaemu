#include "../gba_core.h"
#include "./ppu_common.mm"

namespace gba {

void GBACore::StepPpuSingleCycle() {
  constexpr uint32_t kHD = 1008;
  constexpr uint32_t kSL = 1232;
  constexpr uint32_t kVIS = 160;
  constexpr uint32_t kTOT = 228;

  auto rd16 = [&](size_t off) -> uint16_t {
    return static_cast<uint16_t>(io_regs_[off]) |
           (static_cast<uint16_t>(io_regs_[off + 1u]) << 8);
  };
  auto wr16 = [&](size_t off, uint16_t v) {
    io_regs_[off] = static_cast<uint8_t>(v & 0xFFu);
    io_regs_[off + 1u] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  };
  auto rd28 = [&](size_t off) -> int32_t {
    uint32_t raw = static_cast<uint32_t>(io_regs_[off]) |
                   (static_cast<uint32_t>(io_regs_[off + 1u]) << 8) |
                   (static_cast<uint32_t>(io_regs_[off + 2u]) << 16) |
                   (static_cast<uint32_t>(io_regs_[off + 3u]) << 24);
    raw &= 0x0FFFFFFFu;
    return static_cast<int32_t>(raw << 4) >> 4;
  };

  const uint16_t vcount = rd16(0x0006u);

  ppu_cycle_accum_++;
  if (ppu_cycle_accum_ == kHD) {
    uint16_t dispstat = rd16(0x0004u);
    dispstat |= 0x0002u;
    wr16(0x0004u, dispstat);
    if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);
    if (vcount < kVIS) StepDmaHBlank();
  }

  if (ppu_cycle_accum_ < kSL) return;

  ppu_cycle_accum_ = 0;
  uint16_t nvc = static_cast<uint16_t>((vcount + 1u) % kTOT);
  wr16(0x0006u, nvc);

  uint16_t dispstat = rd16(0x0004u);
  dispstat &= static_cast<uint16_t>(~0x0002u);
  const bool was_vblank = (dispstat & 0x0001u) != 0u;
  const bool now_vblank = (nvc >= kVIS);
  if (now_vblank) {
    dispstat |= 0x0001u;
    if (!was_vblank) {
      RenderDebugFrame();
      frame_rendered_in_vblank_ = true;
      if (dispstat & (1u << 3)) RaiseInterrupt(1u << 0);
      StepDmaVBlank();
    }
  } else {
    dispstat &= static_cast<uint16_t>(~0x0001u);
  }

  const uint16_t lyc = static_cast<uint16_t>((dispstat >> 8) & 0xFFu);
  if (nvc == lyc) {
    if ((dispstat & 0x0004u) == 0u && (dispstat & (1u << 5))) RaiseInterrupt(1u << 2);
    dispstat |= 0x0004u;
  } else {
    dispstat &= static_cast<uint16_t>(~0x0004u);
  }
  wr16(0x0004u, dispstat);

  if (nvc == 0u) {
    bg2_refx_internal_ = rd28(0x0028u);
    bg2_refy_internal_ = rd28(0x002Cu);
    bg3_refx_internal_ = rd28(0x0038u);
    bg3_refy_internal_ = rd28(0x003Cu);
  } else {
    bg2_refx_internal_ += static_cast<int16_t>(rd16(0x0022u));
    bg2_refy_internal_ += static_cast<int16_t>(rd16(0x0026u));
    bg3_refx_internal_ += static_cast<int16_t>(rd16(0x0032u));
    bg3_refy_internal_ += static_cast<int16_t>(rd16(0x0036u));
  }

  if (nvc < mgba_compat::kVideoTotalLines) {
      bg2_refx_line_[nvc] = bg2_refx_internal_;
      bg2_refy_line_[nvc] = bg2_refy_internal_;
      bg3_refx_line_[nvc] = bg3_refx_internal_;
      bg3_refy_line_[nvc] = bg3_refy_internal_;
  }
}

} // namespace gba
