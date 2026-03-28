import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    content = f.read()

# Unified raw PPU access with mirroring
ppu_read_raw = """  else if (a >= 0x05000000u && a <= 0x07FFFFFFu) { // PPU
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    bool allowed = true;

    // OAM: accessible only during VBlank or HBlank (if not using OAM) - mostly VBlank
    if (a >= 0x07000000u) { if (!vblank) allowed = false; }
    // Palette: accessible only during VBlank or HBlank
    else if (a >= 0x05000000u && a <= 0x05FFFFFFu) { if (!vblank && !hblank) allowed = false; }

    if (allowed) {
      if (a >= 0x05000000u && a <= 0x05FFFFFFu) {
        val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
        mapped = true;
      }
      else if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
        uint32_t off = MirrorOffset(a, 0x06000000u, 0x1FFFFu);
        if (off >= 0x18000u) off -= 0x8000u; // VRAM 64KB->96KB logic
        val = Read32Wrap(vram_.data(), off, 0x1FFFFu);
        mapped = true;
      }
      else if (a >= 0x07000000u) {
        val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
        mapped = true;
      }
    } else {
      // Disallowed: return open bus latch but DO NOT update it.
      return open_bus_latch_;
    }
  }"""

# Inject into ReadBus32
content = re.sub(r"else if \(a >= 0x05000000u && a <= 0x07FFFFFFu\) \{.*?\}", ppu_read_raw, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
