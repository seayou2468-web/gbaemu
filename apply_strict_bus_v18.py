import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    c = f.read()

# 1. Identify all GBACore member functions
functions = re.findall(r"(?:uint\d+_t|void) GBACore::[A-Za-z0-9_]+\(.*?\)(?: const)?\s*\{.*?^\}", c, flags=re.DOTALL | re.MULTILINE)

# 2. Identify top level namespace and helper functions
# These are the MirrorOffset, Read32Wrap etc.
helpers = re.findall(r"namespace \{\s*(.*?)\s*\}  // namespace", c, flags=re.DOTALL | re.MULTILINE)[0]

# 3. Reconstruct the file: Header -> Namespace Open -> Helpers -> GBACore methods -> Namespace Close
header = """// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {

namespace {
""" + helpers + """
}  // namespace

"""

# Add ReadBus32 specifically if it exists in our previous logic
readbus32 = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  if (a < 0x00004000u) {
    if (bios_loaded_ && a < bios_.size()) {
      const size_t off = static_cast<size_t>(a);
      return static_cast<uint32_t>(bios_[off]) |
             (static_cast<uint32_t>(bios_[off + 1]) << 8) |
             (static_cast<uint32_t>(bios_[off + 2]) << 16) |
             (static_cast<uint32_t>(bios_[off + 3]) << 24);
    }
    return bios_fetch_latch_;
  }

  uint32_t val = open_bus_latch_;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    if (val == 0) val = open_bus_latch_;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    bool allowed = true;
    if (a >= 0x07000000u) { if (!vblank) allowed = false; }
    else if (a >= 0x05000000u && a <= 0x05FFFFFFu) { if (!vblank && !hblank) allowed = false; }

    if (allowed) {
      if (a >= 0x05000000u && a <= 0x05FFFFFFu)
        val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
      else if (a >= 0x06000000u && a <= 0x06FFFFFFu)
        val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
      else if (a >= 0x07000000u)
        val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      val = static_cast<uint32_t>(rom_[base % rom_.size()]) |
            (static_cast<uint32_t>(rom_[(base+1) % rom_.size()]) << 8) |
            (static_cast<uint32_t>(rom_[(base+2) % rom_.size()]) << 16) |
            (static_cast<uint32_t>(rom_[(base+3) % rom_.size()]) << 24);
    }
  } else if (a >= 0x0E000000u) {
    if (backup_type_ == BackupType::kSRAM) {
      val = static_cast<uint32_t>(ReadBackup8(a)) |
            (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
            (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
            (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
    }
  }
  return val;
}
"""

new_content = header + readbus32 + "\n\n"
for f in functions:
    if "ReadBus32" not in f:
        new_content += f + "\n\n"

new_content += "}  // namespace gba\n"

with open(path, "w") as f:
    f.write(new_content)
