import sys
import re

# 1. Update gba_core.h to add internal affine registers
header_path = "src/core/gba_core.h"
with open(header_path, "r") as f:
    h_content = f.read()

new_members = """  int32_t bg2_refx_internal_ = 0;
  int32_t bg2_refy_internal_ = 0;
  int32_t bg3_refx_internal_ = 0;
  int32_t bg3_refy_internal_ = 0;"""

if "bg2_refx_internal_" not in h_content:
    h_content = h_content.replace("std::array<TimerState, 4> timers_{};",
                                  "std::array<TimerState, 4> timers_{};\n" + new_members)

with open(header_path, "w") as f:
    f.write(h_content)

# 2. Update memory_bus.mm
bus_path = "src/core/gba_core_modules/memory_bus.mm"
with open(bus_path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# Aligned Open Bus Update
update_open_bus = """void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  // val is the 32-bit word from the bus
  if (addr < 0x02000000u) return;

  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    return;
  }

  // Real hardware puts the full 32-bit word on the data bus for most regions
  open_bus_latch_ = val;
}"""

# Corrected Read accessors
read32 = """uint32_t GBACore::Read32(uint32_t addr) const {
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return open_bus_latch_;
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 4);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16 = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return static_cast<uint16_t>(open_bus_latch_ >> ((addr & 2u) * 8u));
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 2);
  const uint32_t shift = (addr & 2u) * 8u;
  uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr & 1u) res = (res >> 8) | (res << 8);
  return res;
}"""

read8 = """uint8_t GBACore::Read8(uint32_t addr) const {
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return static_cast<uint8_t>(open_bus_latch_ >> ((addr & 3u) * 8u));
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 1);
  return static_cast<uint8_t>(val >> ((addr & 3u) * 8u));
}"""

# Update ReadBus32 to set mapped flag or just simplify
readbus32 = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;
  if (a < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      if (bios_loaded_ && a < bios_.size()) {
        const size_t off = static_cast<size_t>(a);
        const uint32_t val = static_cast<uint32_t>(bios_[off]) | (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                             (static_cast<uint32_t>(bios_[off + 2]) << 16) | (static_cast<uint32_t>(bios_[off + 3]) << 24);
        if (a == (cpu_.regs[15] & ~3u)) bios_fetch_latch_ = val;
        else bios_data_latch_ = val;
        return val;
      }
    }
    return open_bus_latch_;
  }

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) return Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu, ewram_.size());
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) return Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu, iwram_.size());
  if (a >= 0x04000000u && a <= 0x040003FCu) {
    return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
  }
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if (a >= 0x07000000u) {
      if (dispstat & 1) return Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());
    } else if ((dispstat & 1) || (dispstat & 2)) {
      if (a >= 0x06000000u) return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());
      return Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());
    }
    return open_bus_latch_;
  }
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) return (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) { return (off < rom_.size()) ? rom_[off] : static_cast<uint8_t>(open_bus_latch_ >> ((off & 3) * 8)); };
      return rb(base) | (static_cast<uint32_t>(rb(base+1)) << 8) | (static_cast<uint32_t>(rb(base+2)) << 16) | (static_cast<uint32_t>(rb(base+3)) << 24);
    }
  }
  if (a >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(a)) | (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) | (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }
  return open_bus_latch_;
}"""

# WriteIO16 with immediate re-evaluation and Affine internal updates
write_io16_body = """void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;

  switch(addr) {
    case 0x04000000u: value &= 0xFF7Fu; break;
    case 0x04000004u: {
      const uint16_t old = ReadIO16(addr);
      const uint16_t vcount = ReadIO16(0x04000006u);
      const uint16_t lyc = (value >> 8) & 0xFF;
      value = (value & 0xFFB8u) | (old & 0x0003u);
      if (vcount == lyc) value |= 0x0004u; else value &= ~0x0004u;
      break;
    }
    case 0x04000006u: return;
    case 0x04000028u: bg2_refx_internal_ = (int32_t)( (static_cast<uint32_t>(value) | (static_cast<uint32_t>(ReadIO16(0x0400002Au)) << 16)) << 4 ) >> 4; break;
    case 0x0400002Au: bg2_refx_internal_ = (int32_t)( (static_cast<uint32_t>(ReadIO16(0x04000028u)) | (static_cast<uint32_t>(value) << 16)) << 4 ) >> 4; break;
    case 0x0400002Cu: bg2_refy_internal_ = (int32_t)( (static_cast<uint32_t>(value) | (static_cast<uint32_t>(ReadIO16(0x0400002Eu)) << 16)) << 4 ) >> 4; break;
    case 0x0400002Eu: bg2_refy_internal_ = (int32_t)( (static_cast<uint32_t>(ReadIO16(0x0400002Cu)) | (static_cast<uint32_t>(value) << 16)) << 4 ) >> 4; break;
    case 0x04000038u: bg3_refx_internal_ = (int32_t)( (static_cast<uint32_t>(value) | (static_cast<uint32_t>(ReadIO16(0x0400003Au)) << 16)) << 4 ) >> 4; break;
    case 0x0400003Au: bg3_refx_internal_ = (int32_t)( (static_cast<uint32_t>(ReadIO16(0x04000038u)) | (static_cast<uint32_t>(value) << 16)) << 4 ) >> 4; break;
    case 0x0400003Cu: bg3_refy_internal_ = (int32_t)( (static_cast<uint32_t>(value) | (static_cast<uint32_t>(ReadIO16(0x0400003Eu)) << 16)) << 4 ) >> 4; break;
    case 0x0400003Eu: bg3_refy_internal_ = (int32_t)( (static_cast<uint32_t>(ReadIO16(0x0400003Cu)) | (static_cast<uint32_t>(value) << 16)) << 4 ) >> 4; break;
    case 0x04000202u: {
      const uint16_t old = ReadIO16(addr);
      value = old & ~value;
      break;
    }
  }

  if (addr >= 0x04000100u && addr <= 0x0400010Eu) {
    const uint32_t tidx = (addr - 0x04000100u) / 4u;
    if (addr & 2) {
      const uint16_t old = ReadIO16(addr);
      timers_[tidx].control = value;
      if (!(old & 0x80u) && (value & 0x80u)) {
        timers_[tidx].counter = timers_[tidx].reload;
        timers_[tidx].prescaler_accum = 0;
        io_regs_[0x100u + tidx*4] = timers_[tidx].reload & 0xFF;
        io_regs_[0x101u + tidx*4] = (timers_[tidx].reload >> 8) & 0xFF;
      }
    } else {
      timers_[tidx].reload = value;
      if (!(timers_[tidx].control & 0x80u)) timers_[tidx].counter = value;
    }
  }

  io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}"""

content = replace_func(content, "UpdateOpenBus", update_open_bus)
content = replace_func(content, "ReadBus32", readbus32)
content = replace_func(content, "Read32", read32)
content = replace_func(content, "Read16", read16)
content = replace_func(content, "Read8", read8)
content = replace_func(content, "WriteIO16", write_io16_body)

with open(bus_path, "w") as f:
    f.write(content)

# 3. Update timing_dma.mm for proper Affine tracking
timing_path = "src/core/gba_core_modules/timing_dma.mm"
with open(timing_path, "r") as f:
    t_content = f.read()

step_ppu_v2 = """void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHDrawCycles = mgba_compat::kVideoHDrawCycles;
  constexpr uint32_t kScanlineCycles = mgba_compat::kVideoScanlineCycles;

  auto write_io_raw16 = [&](uint32_t addr, uint16_t value) {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1 < io_regs_.size()) {
      io_regs_[off] = value & 0xFF;
      io_regs_[off + 1] = (value >> 8) & 0xFF;
    }
  };

  uint32_t remaining = cycles;
  while (remaining > 0) {
    uint16_t dispstat = ReadIO16(0x04000004u);
    const uint16_t vcount = ReadIO16(0x04000006u);
    const bool in_hblank = (dispstat & 2) != 0;
    const uint32_t next_event = in_hblank ? kScanlineCycles : kHDrawCycles;
    const uint32_t dist = (ppu_cycle_accum_ < next_event) ? (next_event - ppu_cycle_accum_) : 1u;
    const uint32_t step = std::min(remaining, dist);
    ppu_cycle_accum_ += step;
    remaining -= step;

    if (ppu_cycle_accum_ >= kHDrawCycles && !in_hblank) {
      dispstat |= 0x0002u;
      if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);
      write_io_raw16(0x04000004u, dispstat);
      StepDma();
    }

    if (ppu_cycle_accum_ >= kScanlineCycles) {
      ppu_cycle_accum_ = 0;
      const uint16_t next_vcount = (vcount + 1u) % mgba_compat::kVideoTotalLines;
      write_io_raw16(0x04000006u, next_vcount);

      dispstat &= ~0x0002u;
      const bool was_vblank = (dispstat & 1) != 0;
      const bool now_vblank = (next_vcount >= 160 && next_vcount < 227);
      if (now_vblank) {
        dispstat |= 0x0001u;
        if (!was_vblank && (dispstat & (1u << 3))) RaiseInterrupt(1u << 0);
        write_io_raw16(0x04000004u, dispstat);
        if (!was_vblank) StepDma();
      } else {
        dispstat &= ~0x0001u;
      }

      const uint16_t vcount_compare = (dispstat >> 8) & 0x00FFu;
      if (next_vcount == vcount_compare) {
        if (!(dispstat & 0x0004u) && (dispstat & (1u << 5))) RaiseInterrupt(1u << 2);
        dispstat |= 0x0004u;
      } else {
        dispstat &= ~0x0004u;
      }
      write_io_raw16(0x04000004u, dispstat);

      if (next_vcount == 0) {
        // Frame start: reload internal affine refs
        auto rb28 = [&](uint32_t addr) {
          uint32_t r = Read32(addr) & 0x0FFFFFFFu;
          return static_cast<int32_t>(r << 4) >> 4;
        };
        bg2_refx_internal_ = rb28(0x04000028u);
        bg2_refy_internal_ = rb28(0x0400002Cu);
        bg3_refx_internal_ = rb28(0x04000038u);
        bg3_refy_internal_ = rb28(0x0400003Cu);
      } else {
        // End of line: advance internal affine refs
        bg2_refx_internal_ += (int16_t)ReadIO16(0x04000022u); // PB
        bg2_refy_internal_ += (int16_t)ReadIO16(0x04000026u); // PD
        bg3_refx_internal_ += (int16_t)ReadIO16(0x04000032u); // PB
        bg3_refy_internal_ += (int16_t)ReadIO16(0x04000036u); // PD
      }

      if (next_vcount < mgba_compat::kVideoTotalLines) {
        bg2_refx_line_[next_vcount] = bg2_refx_internal_;
        bg2_refy_line_[next_vcount] = bg2_refy_internal_;
        bg3_refx_line_[next_vcount] = bg3_refx_internal_;
        bg3_refy_line_[next_vcount] = bg3_refy_internal_;
        affine_line_captured_[next_vcount] = 1;
        affine_line_refs_valid_ = true;
      }
    }
  }
}"""

t_content = re.sub(r"void GBACore::StepPpu\(uint32_t cycles\) \{.*?^\}", step_ppu_v2, t_content, flags=re.DOTALL | re.MULTILINE)
with open(timing_path, "w") as f:
    f.write(t_content)
