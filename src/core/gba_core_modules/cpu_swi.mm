#include "../gba_core.h"
#include <cmath>
#include <cstdlib>
#include <limits>
#include <algorithm>
#include <functional>
#include <array>
#include <vector>

namespace gba {
namespace {

// =========================================================================
// Bios Math Helpers
// =========================================================================

inline int16_t BiosArcTanPolyLocal(int32_t i) {
  const int32_t a = -((i * i) >> 14);
  int32_t b = ((0xA9 * a) >> 14) + 0x390;
  b = ((b * a) >> 14) + 0x91C;
  b = ((b * a) >> 14) + 0xFB6;
  b = ((b * a) >> 14) + 0x16AA;
  b = ((b * a) >> 14) + 0x2081;
  b = ((b * a) >> 14) + 0x3651;
  b = ((b * a) >> 14) + 0xA2F9;
  return static_cast<int16_t>((i * b) >> 16);
}

inline int16_t BiosArcTan2Local(int32_t x, int32_t y) {
  if (y == 0) return static_cast<int16_t>(x >= 0 ? 0 : 0x8000);
  if (x == 0) return static_cast<int16_t>(y >= 0 ? 0x4000 : 0xC000);
  if (y >= 0) {
    if (x >= 0) {
      if (x >= y) return BiosArcTanPolyLocal((y << 14) / x);
      return static_cast<int16_t>(0x4000 - BiosArcTanPolyLocal((x << 14) / y));
    } else {
      if (-x >= y) return static_cast<int16_t>(BiosArcTanPolyLocal((y << 14) / x) + 0x8000);
      return static_cast<int16_t>(0x4000 - BiosArcTanPolyLocal((x << 14) / y));
    }
  } else {
    if (x <= 0) {
      if (-x > -y) return static_cast<int16_t>(BiosArcTanPolyLocal((y << 14) / x) + 0x8000);
      return static_cast<int16_t>(0xC000 - BiosArcTanPolyLocal((x << 14) / y));
    } else {
      if (x >= -y) return static_cast<int16_t>(BiosArcTanPolyLocal((y << 14) / x) + 0x10000);
      return static_cast<int16_t>(0xC000 - BiosArcTanPolyLocal((x << 14) / y));
    }
  }
}

inline uint32_t BiosSqrtLocal(uint32_t x) {
    if (x == 0) return 0;
    uint32_t res = 0;
    uint32_t add = 0x8000;
    for (int i = 0; i < 16; ++i) {
        uint32_t temp = res | add;
        if ((uint64_t)temp * temp <= x) res = temp;
        add >>= 1;
    }
    return res;
}

const std::array<int16_t, 65536>& GbaSinLutLocal() {
  static const std::array<int16_t, 65536> table = [] {
    std::array<int16_t, 65536> lut{};
    for (uint32_t i = 0; i < lut.size(); ++i) {
      const double rad = static_cast<double>(i) * 2.0 * M_PI / 65536.0;
      const int32_t v = static_cast<int32_t>(std::round(std::sin(rad) * 16384.0));
      lut[i] = static_cast<int16_t>(std::clamp(v, -16384, 16383));
    }
    return lut;
  }();
  return table;
}

inline int16_t GbaSinLocal(uint16_t angle) { return GbaSinLutLocal()[angle]; }
inline int16_t GbaCosLocal(uint16_t angle) { return GbaSinLutLocal()[static_cast<uint16_t>(angle + 0x4000u)]; }

// =========================================================================
// Decompression Helpers
// =========================================================================

void DecompressLZ77(uint32_t src, uint32_t dst, bool vram,
                    std::function<uint8_t(uint32_t)> rd8,
                    std::function<uint16_t(uint32_t)> rd16,
                    std::function<void(uint32_t, uint8_t)> wr8,
                    std::function<void(uint32_t, uint16_t)> wr16) {
    uint32_t header = rd8(src) | (rd8(src+1)<<8) | (rd8(src+2)<<16) | (rd8(src+3)<<24);
    uint32_t len = header >> 8;
    src += 4;
    while (len > 0) {
        uint8_t flags = rd8(src++);
        for (int b = 7; b >= 0 && len > 0; --b) {
            if (flags & (1 << b)) {
                uint8_t b1 = rd8(src++);
                uint8_t b2 = rd8(src++);
                int count = (b1 >> 4) + 3;
                int disp = (((b1 & 0x0F) << 8) | b2) + 1;
                for (int j = 0; j < count && len > 0; ++j) {
                    uint8_t val = rd8(dst - disp);
                    if (vram) {
                         if (dst & 1) wr16(dst & ~1u, (rd16(dst & ~1u) & 0x00FFu) | (static_cast<uint16_t>(val) << 8));
                         else wr16(dst, (rd16(dst) & 0xFF00u) | val);
                    } else wr8(dst, val);
                    dst++; len--;
                }
            } else {
                uint8_t val = rd8(src++);
                if (vram) {
                    if (dst & 1) wr16(dst & ~1u, (rd16(dst & ~1u) & 0x00FFu) | (static_cast<uint16_t>(val) << 8));
                    else wr16(dst, (rd16(dst) & 0xFF00u) | val);
                } else wr8(dst, val);
                dst++; len--;
            }
        }
    }
}

void DecompressHuffman(uint32_t src, uint32_t dst,
                       std::function<uint8_t(uint32_t)> rd8,
                       std::function<uint32_t(uint32_t)> rd32,
                       std::function<void(uint32_t, uint32_t)> wr32) {
    uint32_t header = rd32(src);
    int bit_size = header & 0xF;
    uint32_t len = header >> 8;
    src += 4;
    uint32_t tree_start = src;
    uint8_t tree_size = rd8(src++);
    src = tree_start + (tree_size + 1) * 2;
    // Implementation would be more complex, keeping it minimal for now.
}

void DecompressRLE(uint32_t src, uint32_t dst, bool vram,
                   std::function<uint8_t(uint32_t)> rd8,
                   std::function<uint16_t(uint32_t)> rd16,
                   std::function<void(uint32_t, uint8_t)> wr8,
                   std::function<void(uint32_t, uint16_t)> wr16) {
    uint32_t header = rd8(src) | (rd8(src+1)<<8) | (rd8(src+2)<<16) | (rd8(src+3)<<24);
    uint32_t len = header >> 8;
    src += 4;
    while (len > 0) {
        uint8_t flags = rd8(src++);
        int count = (flags & 0x7F);
        if (flags & 0x80) {
            count += 3;
            uint8_t val = rd8(src++);
            for (int i = 0; i < count && len > 0; ++i) {
                if (vram) {
                    if (dst & 1) wr16(dst & ~1u, (rd16(dst & ~1u) & 0x00FFu) | (static_cast<uint16_t>(val) << 8));
                    else wr16(dst, (rd16(dst) & 0xFF00u) | val);
                } else wr8(dst, val);
                dst++; len--;
            }
        } else {
            count += 1;
            for (int i = 0; i < count && len > 0; ++i) {
                uint8_t val = rd8(src++);
                if (vram) {
                    if (dst & 1) wr16(dst & ~1u, (rd16(dst & ~1u) & 0x00FFu) | (static_cast<uint16_t>(val) << 8));
                    else wr16(dst, (rd16(dst) & 0xFF00u) | val);
                } else wr8(dst, val);
                dst++; len--;
            }
        }
    }
}

} // namespace

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  const uint32_t swi_num = swi_imm & 0xFFu;
  const uint32_t next_pc = cpu_.regs[15];
  bool use_hle = !bios_loaded_ || bios_is_builtin_;
  if (!use_hle) {
      switch (swi_num) {
          case 0x06: case 0x07: case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C:
          case 0x0D: case 0x0E: case 0x0F: case 0x10: case 0x11: case 0x12: case 0x14: case 0x15:
              use_hle = true; break;
          default: break;
      }
  }
  if (!use_hle) { EnterException(0x00000008u, 0x13u, true, thumb_state); return true; }

  auto rd8 = [&](uint32_t a) { return Read8(a); };
  auto rd16 = [&](uint32_t a) { return Read16(a); };
  auto rd32 = [&](uint32_t a) { return Read32(a); };
  auto wr8 = [&](uint32_t a, uint8_t v) { Write8(a, v); };
  auto wr16 = [&](uint32_t a, uint16_t v) { Write16(a, v); };
  auto wr32 = [&](uint32_t a, uint32_t v) { Write32(a, v); };

  switch (swi_num) {
    case 0x00u: Reset(); return true;
    case 0x01u: HandleRegisterRamReset(static_cast<uint8_t>(cpu_.regs[0])); cpu_.regs[15] = next_pc; return true;
    case 0x02u: cpu_.halted = true; cpu_.regs[15] = next_pc; return true;
    case 0x03u: cpu_.halted = true; cpu_.regs[15] = next_pc; return true;
    case 0x04u: swi_intrwait_active_ = true; swi_intrwait_mask_ = (uint16_t)cpu_.regs[1]; if (cpu_.regs[0] != 0 && (ReadIO16(0x04000202u) & swi_intrwait_mask_)) swi_intrwait_active_ = false; cpu_.halted = swi_intrwait_active_; cpu_.regs[15] = next_pc; return true;
    case 0x05u: swi_intrwait_active_ = true; swi_intrwait_mask_ = 0x0001u; cpu_.halted = true; cpu_.regs[15] = next_pc; return true;
    case 0x06u: case 0x07u: { int32_t n = (int32_t)cpu_.regs[0], d = (int32_t)cpu_.regs[1]; if (d != 0) { cpu_.regs[0] = (uint32_t)(n / d); cpu_.regs[1] = (uint32_t)(n % d); cpu_.regs[3] = (uint32_t)std::abs(n / d); } cpu_.regs[15] = next_pc; return true; }
    case 0x08u: cpu_.regs[0] = BiosSqrtLocal(cpu_.regs[0]); cpu_.regs[15] = next_pc; return true;
    case 0x09u: cpu_.regs[0] = (uint32_t)(uint16_t)BiosArcTanPolyLocal((int32_t)cpu_.regs[0]); cpu_.regs[15] = next_pc; return true;
    case 0x0Au: cpu_.regs[0] = (uint32_t)(uint16_t)BiosArcTan2Local((int32_t)cpu_.regs[0], (int32_t)cpu_.regs[1]); cpu_.regs[15] = next_pc; return true;
    case 0x0Bu: HandleCpuSet(false); cpu_.regs[15] = next_pc; return true;
    case 0x0Cu: HandleCpuSet(true); cpu_.regs[15] = next_pc; return true;
    case 0x0Du: cpu_.regs[0] = mgba_compat::kBiosChecksum; cpu_.regs[15] = next_pc; return true;
    case 0x0Eu: { uint32_t s = cpu_.regs[0], d = cpu_.regs[1], c = cpu_.regs[2]; for (uint32_t i = 0; i < c; ++i) { int32_t ox = (int32_t)rd32(s), oy = (int32_t)rd32(s + 4); int16_t dx = (int16_t)rd16(s + 8), dy = (int16_t)rd16(s + 10), sx = (int16_t)rd16(s + 12), sy = (int16_t)rd16(s + 14); uint16_t th = rd16(s + 16); int16_t sn = GbaSinLocal(th), cs = GbaCosLocal(th); int16_t pa = (int16_t)((cs * sx) >> 14), pb = (int16_t)((-sn * sx) >> 14), pc = (int16_t)((sn * sy) >> 14), pd = (int16_t)((cs * sy) >> 14); wr16(d, pa); wr16(d+2, pb); wr16(d+4, pc); wr16(d+6, pd); wr32(d+8, ox - ((pa * dx + pb * dy) >> 8)); wr32(d+12, oy - ((pc * dx + pd * dy) >> 8)); s += 20; d += 16; } cpu_.regs[15] = next_pc; return true; }
    case 0x0Fu: { uint32_t s = cpu_.regs[0], d = cpu_.regs[1], c = cpu_.regs[2], st = cpu_.regs[3]; if (st == 0) st = 8; for (uint32_t i = 0; i < c; ++i) { int16_t sx = (int16_t)rd16(s), sy = (int16_t)rd16(s + 2); uint16_t th = rd16(s + 4); int16_t sn = GbaSinLocal(th), cs = GbaCosLocal(th); wr16(d, (int16_t)((cs * sx) >> 14)); wr16(d + st, (int16_t)((-sn * sx) >> 14)); wr16(d + st*2, (int16_t)((sn * sy) >> 14)); wr16(d + st*3, (int16_t)((cs * sy) >> 14)); s += 8; d += st * 4; } cpu_.regs[15] = next_pc; return true; }
    case 0x10u: { // BitUnPack: Fixed to not truncate last bytes
        uint32_t s = cpu_.regs[0], d = cpu_.regs[1], i_ptr = cpu_.regs[2];
        uint16_t len = rd16(i_ptr); uint8_t sw = rd8(i_ptr + 2), dw = rd8(i_ptr + 3); uint32_t bias = rd32(i_ptr + 4);
        if (sw == 0 || dw == 0) { cpu_.regs[15] = next_pc; return true; }
        uint32_t s_mask = (1u << sw) - 1, d_mask = (1u << dw) - 1;
        uint32_t s_acc = 0; int s_bits = 0; uint32_t d_acc = 0; int d_bits = 0;
        for (int i = 0; i < len; ++i) {
            s_acc |= (uint32_t)rd8(s++) << s_bits; s_bits += 8;
            while (s_bits >= sw) {
                uint32_t val = s_acc & s_mask; s_acc >>= sw; s_bits -= sw;
                if (val || (bias & 0x80000000u)) val += (bias & 0x7FFFFFFFu);
                d_acc |= (val & d_mask) << d_bits; d_bits += dw;
                while (d_bits >= 8) { wr8(d++, d_acc & 0xFF); d_acc >>= 8; d_bits -= 8; }
            }
        }
        if (d_bits > 0) wr8(d++, d_acc & 0xFF);
        cpu_.regs[15] = next_pc; return true;
    }
    case 0x11u: DecompressLZ77(cpu_.regs[0], cpu_.regs[1], false, rd8, rd16, wr8, wr16); cpu_.regs[15] = next_pc; return true;
    case 0x12u: DecompressLZ77(cpu_.regs[0], cpu_.regs[1], true, rd8, rd16, wr8, wr16); cpu_.regs[15] = next_pc; return true;
    case 0x14u: DecompressRLE(cpu_.regs[0], cpu_.regs[1], false, rd8, rd16, wr8, wr16); cpu_.regs[15] = next_pc; return true;
    case 0x15u: DecompressRLE(cpu_.regs[0], cpu_.regs[1], true, rd8, rd16, wr8, wr16); cpu_.regs[15] = next_pc; return true;
    default: cpu_.regs[15] = next_pc; return true;
  }
}
} // namespace gba
