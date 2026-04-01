#include "../gba_core.h"
#include "../../debug/trace.h"
#include <algorithm>
#include <cstring>

namespace gba {

static const uint8_t kWaitstatesNonseq16[] = { 0, 0, 2, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4 };
static const uint8_t kWaitstatesSeq16[] = { 0, 0, 2, 0, 0, 0, 0, 0, 2, 2, 4, 4, 8, 8, 4 };
static const uint8_t kWaitstatesNonseq32[] = { 0, 0, 5, 0, 0, 1, 1, 0, 7, 7, 9, 9, 13, 13, 9 };
static const uint8_t kWaitstatesSeq32[] = { 0, 0, 5, 0, 0, 1, 1, 0, 5, 5, 9, 9, 17, 17, 9 };

uint8_t GBACore::Read8(uint32_t addr) const {
  uint32_t region = addr >> 24;
  AddWaitstates(addr, 1, false);
  switch (region) {
    case 0x00: if (addr < 0x4000) { if (cpu_.regs[15] < 0x4000) { bios_fetch_latch_ = *reinterpret_cast<const uint32_t*>(&bios_[addr & ~3]); return bios_[addr]; } return (bios_fetch_latch_ >> ((addr & 3) * 8)) & 0xFF; } return (open_bus_latch_ >> ((addr & 3) * 8)) & 0xFF;
    case 0x02: return ewram_[addr & 0x3FFFF];
    case 0x03: return iwram_[addr & 0x7FFF];
    case 0x04: if (addr < 0x04000400) { uint16_t val = ReadIO16(addr & ~1); return (val >> ((addr & 1) * 8)) & 0xFF; } return 0;
    case 0x05: return palette_ram_[addr & 0x3FF];
    case 0x06: { uint32_t vaddr = addr & 0x1FFFF; if (vaddr >= 0x18000) vaddr -= 0x8000; return vram_[vaddr]; }
    case 0x07: return oam_[addr & 0x3FF];
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: if ((addr & 0x01FFFFFF) < rom_.size()) return rom_[addr & 0x01FFFFFF]; return ((addr >> 1) >> ((addr & 1) * 8)) & 0xFF;
    case 0x0E: return ReadBackup8(addr);
    default: return (open_bus_latch_ >> ((addr & 3) * 8)) & 0xFF;
  }
}

uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1) return Read8(addr) | (Read8(addr + 1) << 8);
  uint32_t region = addr >> 24; AddWaitstates(addr, 2, false);
  switch (region) {
    case 0x00: if (addr < 0x4000) { if (cpu_.regs[15] < 0x4000) { bios_fetch_latch_ = *reinterpret_cast<const uint32_t*>(&bios_[addr & ~3]); return *reinterpret_cast<const uint16_t*>(&bios_[addr]); } return (bios_fetch_latch_ >> ((addr & 2) * 8)) & 0xFFFF; } return (open_bus_latch_ >> ((addr & 2) * 8)) & 0xFFFF;
    case 0x02: return *reinterpret_cast<const uint16_t*>(&ewram_[addr & 0x3FFFE]);
    case 0x03: return *reinterpret_cast<const uint16_t*>(&iwram_[addr & 0x7FFE]);
    case 0x04: return (addr < 0x04000400) ? ReadIO16(addr) : 0;
    case 0x05: return *reinterpret_cast<const uint16_t*>(&palette_ram_[addr & 0x3FE]);
    case 0x06: { uint32_t vaddr = addr & 0x1FFFE; if (vaddr >= 0x18000) vaddr -= 0x8000; return *reinterpret_cast<const uint16_t*>(&vram_[vaddr]); }
    case 0x07: return *reinterpret_cast<const uint16_t*>(&oam_[addr & 0x3FE]);
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: if ((addr & 0x01FFFFFF) < rom_.size() - 1) return *reinterpret_cast<const uint16_t*>(&rom_[addr & 0x01FFFFFF]); return (addr >> 1) & 0xFFFF;
    case 0x0E: return ReadBackup8(addr) | (ReadBackup8(addr + 1) << 8);
    default: return (open_bus_latch_ >> ((addr & 2) * 8)) & 0xFFFF;
  }
}

uint32_t GBACore::Read32(uint32_t addr) const {
  if (addr & 3) return RotateRight(Read32(addr & ~3), (addr & 3) * 8);
  uint32_t region = addr >> 24; AddWaitstates(addr, 4, false);
  switch (region) {
    case 0x00: if (addr < 0x4000) { if (cpu_.regs[15] < 0x4000) { bios_fetch_latch_ = *reinterpret_cast<const uint32_t*>(&bios_[addr]); return bios_fetch_latch_; } return bios_fetch_latch_; } return open_bus_latch_;
    case 0x02: return *reinterpret_cast<const uint32_t*>(&ewram_[addr & 0x3FFFC]);
    case 0x03: return *reinterpret_cast<const uint32_t*>(&iwram_[addr & 0x7FFC]);
    case 0x04: return (addr < 0x04000400) ? (ReadIO16(addr) | (ReadIO16(addr + 2) << 16)) : 0;
    case 0x05: return *reinterpret_cast<const uint32_t*>(&palette_ram_[addr & 0x3FC]);
    case 0x06: { uint32_t vaddr = addr & 0x1FFFC; if (vaddr >= 0x18000) vaddr -= 0x8000; return *reinterpret_cast<const uint32_t*>(&vram_[vaddr]); }
    case 0x07: return *reinterpret_cast<const uint32_t*>(&oam_[addr & 0x3FC]);
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: if ((addr & 0x01FFFFFF) < rom_.size() - 3) return *reinterpret_cast<const uint32_t*>(&rom_[addr & 0x01FFFFFF]); return (addr >> 1);
    case 0x0E: return ReadBackup8(addr) | (ReadBackup8(addr + 1) << 8) | (ReadBackup8(addr + 2) << 16) | (ReadBackup8(addr + 3) << 24);
    default: return open_bus_latch_;
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  uint32_t region = addr >> 24; AddWaitstates(addr, 1, true);
  switch (region) {
    case 0x02: ewram_[addr & 0x3FFFF] = value; break;
    case 0x03: iwram_[addr & 0x7FFF] = value; break;
    case 0x04: if (addr < 0x04000400) WriteIO16(addr & ~1, (ReadIO16(addr & ~1) & (0xFF00 >> ((addr & 1) * 8))) | (value << ((addr & 1) * 8))); break;
    case 0x05: Write16(addr & ~1, (value << 8) | value); break;
    case 0x06: { uint32_t vaddr = addr & 0x1FFFF; if (vaddr >= 0x10000) { if (vaddr >= 0x18000) vaddr -= 0x8000; vram_[vaddr] = value; } break; }
    case 0x0E: WriteBackup8(addr, value); break;
    default: break;
  }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  uint32_t region = (addr >> 24) & 0xF; AddWaitstates(addr, 2, true);
  switch (region) {
    case 0x02: *reinterpret_cast<uint16_t*>(&ewram_[addr & 0x3FFFE]) = value; break;
    case 0x03: *reinterpret_cast<uint16_t*>(&iwram_[addr & 0x7FFE]) = value; break;
    case 0x04: if (addr < 0x04000400) WriteIO16(addr, value); break;
    case 0x05: *reinterpret_cast<uint16_t*>(&palette_ram_[addr & 0x3FE]) = value; break;
    case 0x06: { uint32_t vaddr = addr & 0x1FFFE; if (vaddr >= 0x18000) vaddr -= 0x8000; *reinterpret_cast<uint16_t*>(&vram_[vaddr]) = value; break; }
    case 0x07: *reinterpret_cast<uint16_t*>(&oam_[addr & 0x3FE]) = value; break;
    case 0x0E: WriteBackup8(addr, value & 0xFF); WriteBackup8(addr + 1, value >> 8); break;
    default: break;
  }
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  uint32_t region = (addr >> 24) & 0xF; AddWaitstates(addr, 4, true);
  switch (region) {
    case 0x02: *reinterpret_cast<uint32_t*>(&ewram_[addr & 0x3FFFC]) = value; break;
    case 0x03: *reinterpret_cast<uint32_t*>(&iwram_[addr & 0x7FFC]) = value; break;
    case 0x04: if (addr < 0x04000400) { WriteIO16(addr, value & 0xFFFF); WriteIO16(addr + 2, value >> 16); } break;
    case 0x05: *reinterpret_cast<uint32_t*>(&palette_ram_[addr & 0x3FC]) = value; break;
    case 0x06: { uint32_t vaddr = addr & 0x1FFFC; if (vaddr >= 0x18000) vaddr -= 0x8000; *reinterpret_cast<uint32_t*>(&vram_[vaddr]) = value; break; }
    case 0x07: *reinterpret_cast<uint32_t*>(&oam_[addr & 0x3FC]) = value; break;
    case 0x0E: WriteBackup8(addr, value & 0xFF); WriteBackup8(addr + 1, (value >> 8) & 0xFF); WriteBackup8(addr + 2, (value >> 16) & 0xFF); WriteBackup8(addr + 3, value >> 24); break;
    default: break;
  }
}

void GBACore::AddWaitstates(uint32_t addr, int size, bool is_write) const {
  uint32_t region = (addr >> 24) & 0xF; bool is_seq = (addr == last_access_addr_ + last_access_size_) && (region == (last_access_addr_ >> 24));
  uint32_t wait = (size == 4) ? (is_seq ? kWaitstatesSeq32[region] : kWaitstatesNonseq32[region]) : (is_seq ? kWaitstatesSeq16[region] : kWaitstatesNonseq16[region]);
  waitstates_accum_ += wait; last_access_addr_ = addr; last_access_size_ = size;
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= 0x3FE; uint16_t val = *reinterpret_cast<const uint16_t*>(&io_regs_[addr]);
  switch (addr) { case 0x130: return (~keys_pressed_mask_) & 0x03FF; default: return val; }
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= 0x3FE; uint16_t old_val = *reinterpret_cast<uint16_t*>(&io_regs_[addr]); *reinterpret_cast<uint16_t*>(&io_regs_[addr]) = value;
  switch (addr) {
    case 0x004: *reinterpret_cast<uint16_t*>(&io_regs_[addr]) = (value & 0xFFF8) | (old_val & 0x0007); break;
    case 0x0BA: case 0x0C6: case 0x0D2: case 0x0DE: if ((value & (1 << 15)) && !(old_val & (1 << 15))) StepDma(); break;
    case 0x202: *reinterpret_cast<uint16_t*>(&io_regs_[addr]) = old_val & ~value; break;
    case 0x204: RebuildGamePakWaitstateTables(value); break;
    default: break;
  }
}

void GBACore::SyncKeyInputRegister() { WriteIO16(0x130, (~keys_pressed_mask_) & 0x03FF); }
void GBACore::RebuildGamePakWaitstateTables(uint16_t waitcnt) { (void)waitcnt; }

} // namespace gba
