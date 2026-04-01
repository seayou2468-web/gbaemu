#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

uint8_t GBACore::Read8(uint32_t addr) const {
  switch (addr >> 24) {
    case 0x00: // BIOS (00000000-00003FFF)
      if (addr < 0x4000) return bios_[addr];
      return open_bus_latch_;
    case 0x02: // EWRAM (02000000-0203FFFF)
      return ewram_[addr & 0x3FFFF];
    case 0x03: // IWRAM (03000000-03007FFF)
      return iwram_[addr & 0x7FFF];
    case 0x04: // IO Regs (04000000-040003FE)
      if (addr < 0x04000400) return io_regs_[addr & 0x3FF];
      return 0;
    case 0x05: // Palette RAM (05000000-050003FF)
      return palette_ram_[addr & 0x3FF];
    case 0x06: // VRAM (06000000-06017FFF)
      return vram_[addr & 0x1FFFF];
    case 0x07: // OAM (07000000-070003FF)
      return oam_[addr & 0x3FF];
    case 0x08: // Game Pak ROM (08000000-09FFFFFF)
    case 0x09:
    case 0x0A:
    case 0x0B:
    case 0x0C:
    case 0x0D:
      if ((addr & 0x01FFFFFF) < rom_.size()) return rom_[addr & 0x01FFFFFF];
      return 0;
    case 0x0E: // Game Pak Backup RAM (0E000000-0E00FFFF)
      return ReadBackup8(addr & 0xFFFF);
    default:
      return 0;
  }
}

uint16_t GBACore::Read16(uint32_t addr) const {
  addr &= ~1;
  return Read8(addr) | (Read8(addr + 1) << 8);
}

uint32_t GBACore::Read32(uint32_t addr) const {
  addr &= ~3;
  return Read16(addr) | (Read16(addr + 2) << 16);
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  switch (addr >> 24) {
    case 0x02: // EWRAM
      ewram_[addr & 0x3FFFF] = value;
      break;
    case 0x03: // IWRAM
      iwram_[addr & 0x7FFF] = value;
      break;
    case 0x04: // IO Regs
      if (addr < 0x04000400) {
        io_regs_[addr & 0x3FF] = value;
        // Trigger some I/O effects if needed (handled in StepFrame/RunCpuSlice usually)
      }
      break;
    case 0x05: // Palette RAM
      palette_ram_[addr & 0x3FF] = value;
      break;
    case 0x06: // VRAM
      vram_[addr & 0x1FFFF] = value;
      break;
    case 0x07: // OAM
      oam_[addr & 0x3FF] = value;
      break;
    case 0x0E: // Game Pak Backup RAM
      WriteBackup8(addr & 0xFFFF, value);
      break;
    default:
      break;
  }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  addr &= ~1;
  Write8(addr, value & 0xFF);
  Write8(addr + 1, (value >> 8) & 0xFF);
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  addr &= ~3;
  Write16(addr, value & 0xFFFF);
  Write16(addr + 2, (value >> 16) & 0xFFFF);
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  return Read16(addr);
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  Write16(addr, value);
}

void GBACore::RebuildGamePakWaitstateTables(uint16_t waitcnt) {
  // Logic to update ws_nonseq_16_, etc. based on REG_WAITCNT
  // waitcnt: 0-1: SRAM, 2-3: WS0, 4-5: WS1, 6-7: WS2, etc.
}

void GBACore::SyncKeyInputRegister() {
  uint16_t reg_keyinput = (~keys_pressed_mask_) & 0x03FF;
  WriteIO16(0x04000130, reg_keyinput);
}

void GBACore::RaiseInterrupt(uint16_t mask) {
  uint16_t IF = ReadIO16(0x04000202);
  IF |= mask;
  WriteIO16(0x04000202, IF);
  ServiceInterruptIfNeeded();
}

void GBACore::ServiceInterruptIfNeeded() {
  uint16_t IE = ReadIO16(0x04000200);
  uint16_t IF = ReadIO16(0x04000202);
  uint16_t IME = ReadIO16(0x04000208) & 1;

  if (IME && (IE & IF)) {
    EnterException(0x00000018, 0x12, true, false); // IRQ mode, Disable IRQ, ARM state
    cpu_.halted = false;
  }
}

} // namespace gba
