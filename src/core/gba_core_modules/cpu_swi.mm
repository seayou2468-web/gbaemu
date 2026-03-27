#include "../gba_core.h"
#include <cmath>
#include <cstdlib>
#include <limits>
#include <algorithm>
#include <vector>

namespace gba {

namespace {
int16_t BiosArcTanPolyLocal(int32_t i) {
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

int16_t BiosArcTan2Local(int32_t x, int32_t y) {
  if (x == 0 && y == 0) return 0;
  if (x == 0) return (y > 0) ? 0x4000 : (int16_t)0xC000;
  if (y == 0) return (x > 0) ? 0 : (int16_t)0x8000;
  int32_t abs_x = (x < 0) ? -x : x;
  int32_t abs_y = (y < 0) ? -y : y;
  if (abs_x >= abs_y) {
    int32_t q = (y << 14) / x;
    int16_t res = BiosArcTanPolyLocal(q);
    if (x < 0) res += 0x8000;
    return res;
  } else {
    int32_t q = (x << 14) / y;
    int16_t res = (y > 0) ? 0x4000 : (int16_t)0xC000;
    return res - BiosArcTanPolyLocal(q);
  }
}

uint32_t BiosSqrtLocal(uint32_t x) {
  if (x == 0) return 0;
  uint32_t root = 0;
  uint32_t bit = 1u << 30;
  while (bit > x) bit >>= 2;
  while (bit != 0) {
    if (x >= root + bit) {
      x -= root + bit;
      root = (root >> 1) + bit;
    } else {
      root >>= 1;
    }
    bit >>= 2;
  }
  return root;
}
} // namespace

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  const bool use_bios_swi = bios_loaded_ && bios_boot_via_vector_;
  if (use_bios_swi) return false;

  const uint32_t next_pc = cpu_.regs[15] + (thumb_state ? 2u : 4u);
  using namespace mgba_compat;

  switch (swi_imm & 0xFFu) {
    case 0x00u: // SoftReset
      Reset();
      return true;
    case 0x01u: // RegisterRamReset
      HandleRegisterRamReset(static_cast<uint8_t>(cpu_.regs[0] & 0xFFu));
      cpu_.regs[15] = next_pc;
      return true;
    case 0x02u: // Halt
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    case 0x04u: // IntrWait
    case 0x05u: {
      uint16_t request = (swi_imm & 0xFFu) == 0x05u ? 0x0001u : static_cast<uint16_t>(cpu_.regs[1] & 0x3FFFu);
      if (request == 0) request = 0x0001u;

      const uint32_t irq_flags_addr = 0x03007FF8u;
      uint16_t ram_flags = static_cast<uint16_t>(Read32(irq_flags_addr) & request);

      if ((cpu_.regs[0] & 0x1u) == 0u) {
        if (ram_flags != 0u) {
          Write32(irq_flags_addr, Read32(irq_flags_addr) & ~ram_flags);
          swi_intrwait_active_ = false;
          swi_intrwait_mask_ = 0u;
          cpu_.halted = false;
          cpu_.regs[15] = next_pc;
          return true;
        }
      }
      swi_intrwait_active_ = true;
      swi_intrwait_mask_ = request;
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    }
    case kSwiDiv:
    case kSwiDivArm: {
      bool arm = (swi_imm & 0xFFu) == kSwiDivArm;
      int32_t num = static_cast<int32_t>(cpu_.regs[arm ? 1 : 0]);
      int32_t den = static_cast<int32_t>(cpu_.regs[arm ? 0 : 1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>(num < 0 ? -1 : 1);
        cpu_.regs[1] = static_cast<uint32_t>(num);
        cpu_.regs[3] = 1;
      } else {
        cpu_.regs[0] = static_cast<uint32_t>(num / den);
        cpu_.regs[1] = static_cast<uint32_t>(num % den);
        cpu_.regs[3] = static_cast<uint32_t>(std::abs(static_cast<int>(cpu_.regs[0])));
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case kSwiSqrt:
      cpu_.regs[0] = BiosSqrtLocal(cpu_.regs[0]);
      cpu_.regs[15] = next_pc;
      return true;
    case kSwiArcTan:
      cpu_.regs[0] = static_cast<uint16_t>(BiosArcTanPolyLocal(static_cast<int32_t>(cpu_.regs[0])));
      cpu_.regs[15] = next_pc;
      return true;
    case kSwiArcTan2:
      cpu_.regs[0] = static_cast<uint16_t>(BiosArcTan2Local(static_cast<int32_t>(cpu_.regs[0]), static_cast<int32_t>(cpu_.regs[1])));
      cpu_.regs[15] = next_pc;
      return true;
    case 0x0Bu: // CpuSet
      HandleCpuSet(false);
      cpu_.regs[15] = next_pc;
      return true;
    case 0x0Cu: // CpuFastSet
      HandleCpuSet(true);
      cpu_.regs[15] = next_pc;
      return true;
    case 0x0Eu: { // BgAffineSet
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      while (count--) {
        int32_t ox = static_cast<int32_t>(Read32(src));
        int32_t oy = static_cast<int32_t>(Read32(src + 4));
        int16_t cx = static_cast<int16_t>(Read16(src + 8));
        int16_t cy = static_cast<int16_t>(Read16(src + 10));
        int16_t sx = static_cast<int16_t>(Read16(src + 12));
        int16_t sy = static_cast<int16_t>(Read16(src + 14));
        src += 16;
        // Basic implementation
        Write32(dst, ox);
        Write32(dst + 4, oy);
        Write16(dst + 8, cx);
        Write16(dst + 10, cy);
        Write16(dst + 12, sx);
        Write16(dst + 14, sy);
        dst += 16;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Fu: { // ObjAffineSet
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      uint32_t stride = cpu_.regs[3];
      for (uint32_t i = 0; i < count; ++i) {
        Write16(dst, Read16(src));
        Write16(dst + stride, Read16(src + 2));
        Write16(dst + 2 * stride, Read16(src + 4));
        Write16(dst + 3 * stride, Read16(src + 6));
        src += 8;
        dst += 4 * stride;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x10u: { // BitUnPack
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t info = cpu_.regs[2];
      uint32_t len = Read16(info);
      uint8_t src_b = Read8(info + 2);
      uint8_t dst_b = Read8(info + 3);
      uint32_t offset = Read32(info + 4);
      uint32_t data = 0;
      int bits = 0;
      for (uint32_t i = 0; i < len; ) {
          uint32_t val = Read8(src++);
          for (int j = 0; j < 8 / src_b && i < len; ++j) {
              uint32_t chunk = (val >> (j * src_b)) & ((1 << src_b) - 1);
              if (chunk || (offset & 0x80000000)) chunk += (offset & 0x7FFFFFFF);
              data |= (chunk << bits);
              bits += dst_b;
              if (bits >= 32) {
                  Write32(dst, data);
                  dst += 4;
                  bits = 0;
                  data = 0;
              }
              i++;
          }
      }
      if (bits > 0) Write32(dst, data);
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x11u: // LZ77UnCompWram
    case 0x12u: { // LZ77UnCompVram
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t header = Read32(src); src += 4;
      uint32_t size = header >> 8;
      bool vram = (swi_imm & 0xFF) == 0x12u;
      std::vector<uint8_t> buf; buf.reserve(size);
      while (buf.size() < size) {
          uint8_t flag = Read8(src++);
          for (int i = 0; i < 8 && buf.size() < size; ++i) {
              if (flag & (0x80 >> i)) {
                  uint16_t info = Read8(src++) << 8;
                  info |= Read8(src++);
                  int count = (info >> 12) + 3;
                  int disp = (info & 0xFFF) + 1;
                  int start = (int)buf.size() - disp;
                  for (int k = 0; k < count && buf.size() < size; ++k) buf.push_back(buf[start + k]);
              } else {
                  buf.push_back(Read8(src++));
              }
          }
      }
      if (vram) {
          for (size_t i = 0; i < buf.size(); i += 2) {
              uint16_t val = buf[i] | (i+1 < buf.size() ? buf[i+1] << 8 : 0);
              Write16(dst + i, val);
          }
      } else {
          for (size_t i = 0; i < buf.size(); ++i) Write8(dst + i, buf[i]);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x14u: // RLUnCompWram
    case 0x15u: {
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t header = Read32(src); src += 4;
      uint32_t size = header >> 8;
      bool vram = (swi_imm & 0xFF) == 0x15u;
      std::vector<uint8_t> buf;
      while (buf.size() < size) {
          uint8_t cnt = Read8(src++);
          if (cnt & 0x80) {
              uint8_t val = Read8(src++);
              for (int i = 0; i < (cnt & 0x7F) + 3 && buf.size() < size; ++i) buf.push_back(val);
          } else {
              for (int i = 0; i < (cnt & 0x7F) + 1 && buf.size() < size; ++i) buf.push_back(Read8(src++));
          }
      }
      if (vram) {
          for (size_t i = 0; i < buf.size(); i += 2) {
              uint16_t val = buf[i] | (i+1 < buf.size() ? buf[i+1] << 8 : 0);
              Write16(dst + i, val);
          }
      } else {
          for (size_t i = 0; i < buf.size(); ++i) Write8(dst + i, buf[i]);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case kSwiGetBiosChecksum:
      cpu_.regs[0] = kBiosChecksum;
      cpu_.regs[15] = next_pc;
      return true;
    default:
      cpu_.regs[15] = next_pc;
      return true;
  }
}

} // namespace gba
