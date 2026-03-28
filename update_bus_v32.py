import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    if re.search(pattern, c, flags=re.DOTALL | re.MULTILINE):
        return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)
    return c

# 1. Safer Wrap helpers to avoid out-of-bounds
helpers = """inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}

inline uint16_t Read16Wrap(const uint8_t* buf, uint32_t off, uint32_t mask, size_t size) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  return static_cast<uint16_t>(buf[o0 % size]) |
         static_cast<uint16_t>(buf[o1 % size] << 8);
}

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, uint32_t mask, size_t size) {
  return static_cast<uint32_t>(buf[off % size]) |
         (static_cast<uint32_t>(buf[(off + 1) % size]) << 8) |
         (static_cast<uint32_t>(buf[(off + 2) % size]) << 16) |
         (static_cast<uint32_t>(buf[(off + 3) % size]) << 24);
}

inline void Write16Wrap(uint8_t* buf, uint32_t off, uint32_t mask, size_t size, uint16_t value) {
  buf[off % size] = static_cast<uint8_t>(value & 0xFFu);
  buf[(off + 1) % size] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}

inline void Write32Wrap(uint8_t* buf, uint32_t off, uint32_t mask, size_t size, uint32_t value) {
  buf[off % size] = static_cast<uint8_t>(value & 0xFFu);
  buf[(off + 1) % size] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  buf[(off + 2) % size] = static_cast<uint8_t>((value >> 16) & 0xFFu);
  buf[(off + 3) % size] = static_cast<uint8_t>((value >> 24) & 0xFFu);
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x1FFFFu);
  if (off32 >= 0x18000u) off32 -= 0x8000u;
  return off32;
}"""

# 2. ReadBus32: Correct protection and latching
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;

  // BIOS Region
  if (a < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      if (bios_loaded_ && a < bios_.size()) {
        const size_t off = static_cast<size_t>(a);
        const uint32_t val = static_cast<uint32_t>(bios_[off]) |
                             (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                             (static_cast<uint32_t>(bios_[off + 2]) << 16) |
                             (static_cast<uint32_t>(bios_[off + 3]) << 24);
        if (a == (cpu_.regs[15] & ~3u)) bios_fetch_latch_ = val;
        else bios_data_latch_ = val;
        return val;
      }
    }
    return open_bus_latch_;
  }

  uint32_t val = open_bus_latch_;
  bool mapped = false;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu, ewram_.size());
    mapped = true;
  }
  else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu, iwram_.size());
    mapped = true;
  }
  else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    mapped = true;
  }
  else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (a >= 0x07000000u) {
      if (vblank) {
        val = Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());
        mapped = true;
      }
    } else {
      if (vblank || hblank) {
        if (a >= 0x06000000u) val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());
        else val = Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());
        mapped = true;
      }
    }
  }
  else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) {
        return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF);
      };
      val = rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
    mapped = true;
  }
  else if (a >= 0x0E000000u) {
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
    mapped = true;
  }

  if (mapped) open_bus_latch_ = val;
  return val;
}"""

# 3. Read wrappers: Correct Latch Update
read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr >= 0x02000000u) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
      open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    } else {
      const uint32_t mask = 0xFFFFu << shift;
      open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
    }
  }
  return res;
}"""

read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>(val >> shift);
  if (addr >= 0x02000000u) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
      open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    } else {
      const uint32_t mask = 0xFFu << shift;
      open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
    }
  }
  return res;
}"""

# 4. Write wrappers: fix mirroring and bounds
write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  if (addr >= 0x04000000u && addr <= 0x040003FEu) { WriteIO16(addr, value); return; }
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    if (addr & 1u) return;
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (addr >= 0x07000000u) {
      if (vblank) Write16Wrap(oam_.data(), addr & 0x3FFu, 0x3FFu, oam_.size(), value);
    } else if (vblank || hblank) {
      if (addr >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(addr), 0x1FFFFu, vram_.size(), value);
      else Write16Wrap(palette_ram_.data(), addr & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    }
    return;
  }
  Write8(addr, static_cast<uint8_t>(value));
  Write8(addr + 1u, static_cast<uint8_t>(value >> 8));
}"""

write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t a = addr & ~1u;
    const uint16_t v = value | (static_cast<uint16_t>(value) << 8);
    Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), v);
    return;
  }
  if (addr >= 0x06000000u && addr <= 0x07FFFFFFu) return;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  }
  else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}"""

# Update helpers
content = re.sub(r"namespace \{\s*.*?\s*\}  // namespace", "namespace {\n" + helpers + "\n}  // namespace", full_content, flags=re.DOTALL | re.MULTILINE)

content = replace_func(content, "ReadBus32", readbus32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)
content = replace_func(content, "Write16", write16_body)
content = replace_func(content, "Write8", write8_body)

with open(path, "w") as f:
    f.write(content)

# Fix ApplyShift
helpers_path = "src/core/gba_core_modules/cpu_helpers.mm"
with open(helpers_path, "r") as f:
    c_helpers = f.read()

new_apply_shift = """uint32_t GBACore::ApplyShift(uint32_t value,
                             uint32_t shift_type,
                             uint32_t shift_amount,
                             bool* carry_out) const {
  if (!carry_out) return value;
  if (shift_amount == 0) {
    *carry_out = GetFlagC();
    return value;
  }
  switch (shift_type & 0x3u) {
    case 0: { // LSL
      if (shift_amount < 32) {
        *carry_out = ((value >> (32u - shift_amount)) & 1u) != 0;
        return value << shift_amount;
      }
      if (shift_amount == 32) {
        *carry_out = (value & 1u) != 0;
        return 0;
      }
      *carry_out = false;
      return 0;
    }
    case 1: { // LSR
      if (shift_amount < 32) {
        *carry_out = ((value >> (shift_amount - 1u)) & 1u) != 0;
        return value >> shift_amount;
      }
      if (shift_amount == 32) {
        *carry_out = (value >> 31) != 0;
        return 0;
      }
      *carry_out = false;
      return 0;
    }
    case 2: { // ASR
      if (shift_amount < 32) {
        *carry_out = ((value >> (shift_amount - 1u)) & 1u) != 0;
        return static_cast<uint32_t>(static_cast<int32_t>(value) >> shift_amount);
      }
      *carry_out = (value >> 31) != 0;
      return (value & 0x80000000u) ? 0xFFFFFFFFu : 0u;
    }
    case 3: { // ROR
      uint32_t rot = shift_amount & 31u;
      if (rot == 0) {
        *carry_out = (value >> 31) != 0;
        return value;
      }
      uint32_t result = RotateRight(value, rot);
      *carry_out = (result >> 31) != 0;
      return result;
    }
    default:
      return value;
  }
}"""

c_helpers = re.sub(r"uint32_t GBACore::ApplyShift\(.*?\)\s*const\s*\{.*?^\}", new_apply_shift, c_helpers, flags=re.DOTALL | re.MULTILINE)
with open(helpers_path, "w") as f:
    f.write(c_helpers)
