import sys
import re

path = "src/core/gba_core_modules/cpu_swi.mm"

swi_content = """#include "../gba_core.h"
#include <cmath>
#include <cstdlib>
#include <limits>

namespace gba {
namespace {

int16_t GbaSinLocal(uint16_t angle) {
  double rad = (double)(angle & 0xFFFF) * 2.0 * M_PI / 65536.0;
  return static_cast<int16_t>(round(sin(rad) * 16384.0));
}

int16_t GbaCosLocal(uint16_t angle) {
  double rad = (double)(angle & 0xFFFF) * 2.0 * M_PI / 65536.0;
  return static_cast<int16_t>(round(cos(rad) * 16384.0));
}

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
  if (y == 0) return static_cast<int16_t>(x >= 0 ? 0 : 0x8000);
  if (x == 0) return static_cast<int16_t>(y >= 0 ? 0x4000 : 0xC000);
  if (y >= 0) {
    if (x >= 0) {
      if (x >= y) return BiosArcTanPolyLocal((y << 14) / x);
    } else if (-x >= y) {
      return static_cast<int16_t>(BiosArcTanPolyLocal((y << 14) / x) + 0x8000);
    }
    return static_cast<int16_t>(0x4000 - BiosArcTanPolyLocal((x << 14) / y));
  }
  if (x <= 0) {
    if (-x > -y) return static_cast<int16_t>(BiosArcTanPolyLocal((y << 14) / x) + 0x8000);
  } else if (x >= -y) {
    return static_cast<int16_t>(BiosArcTanPolyLocal((y << 14) / x) + 0x10000);
  }
  return static_cast<int16_t>(0xC000 - BiosArcTanPolyLocal((x << 14) / y));
}

uint32_t BiosSqrtLocal(uint32_t x) {
  if (x == 0) return 0;
  uint32_t upper = x, bound = 1;
  while (bound < upper) { upper >>= 1; bound <<= 1; }
  while (true) {
    upper = x; uint32_t accum = 0, lower = bound;
    while (true) { uint32_t old = lower; if (lower <= upper >> 1) lower <<= 1; if (old >= upper >> 1) break; }
    while (true) { accum <<= 1; if (upper >= lower) { ++accum; upper -= lower; } if (lower == bound) break; lower >>= 1; }
    uint32_t old_b = bound; bound += accum; bound >>= 1; if (bound >= old_b) return old_b;
  }
}

} // namespace

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  if (bios_loaded_ && bios_boot_via_vector_) {
    const bool thumb = (cpu_.cpsr & (1u << 5)) != 0;
    cpu_.regs[15] += thumb ? 2 : 4;
    EnterException(0x00000008u, 0x13u, true, thumb);
    return true;
  }

  const uint32_t next_pc = cpu_.regs[15] + (thumb_state ? 2u : 4u);
  switch (swi_imm & 0xFFu) {
    case 0x00u: Reset(); return true;
    case 0x01u: HandleRegisterRamReset(static_cast<uint8_t>(cpu_.regs[0] & 0xFFu)); cpu_.regs[15] = next_pc; return true;
    case 0x02u: cpu_.halted = true; cpu_.regs[15] = next_pc; return true;
    case 0x03u: cpu_.halted = true; cpu_.regs[15] = next_pc; return true;
    case 0x04u:
    case 0x05u: {
      uint16_t request = (swi_imm & 0xFFu) == 0x05u ? 0x0001u : static_cast<uint16_t>(cpu_.regs[1] & 0x3FFFu);
      if (request == 0) request = 0x0001u;
      if (ReadIO16(0x04000202u) & request) {
        WriteIO16(0x04000202u, ReadIO16(0x04000202u) & request);
        cpu_.regs[15] = next_pc;
      } else {
        swi_intrwait_active_ = true; swi_intrwait_mask_ = request; cpu_.halted = true; cpu_.regs[15] = next_pc;
      }
      return true;
    }
    case 0x06u: {
      int32_t num = (int32_t)cpu_.regs[0], den = (int32_t)cpu_.regs[1];
      if (den == 0) { cpu_.regs[0] = (uint32_t)num; cpu_.regs[1] = 0; cpu_.regs[3] = (uint32_t)std::abs(num); }
      else if (den == -1 && num == std::numeric_limits<int32_t>::min()) { cpu_.regs[0] = (uint32_t)num; cpu_.regs[1] = 0; cpu_.regs[3] = (uint32_t)std::abs((int64_t)num); }
      else { cpu_.regs[0] = (uint32_t)(num / den); cpu_.regs[1] = (uint32_t)(num % den); cpu_.regs[3] = (uint32_t)std::abs(num / den); }
      cpu_.regs[15] = next_pc; return true;
    }
    case 0x07u: {
      int32_t den = (int32_t)cpu_.regs[0], num = (int32_t)cpu_.regs[1];
      if (den == 0) { cpu_.regs[0] = (uint32_t)num; cpu_.regs[1] = 0; cpu_.regs[3] = (uint32_t)num; }
      else if (den == -1 && num == std::numeric_limits<int32_t>::min()) { cpu_.regs[0] = (uint32_t)num; cpu_.regs[1] = 0; cpu_.regs[3] = (uint32_t)std::abs((int64_t)num); }
      else { cpu_.regs[0] = (uint32_t)(num / den); cpu_.regs[1] = (uint32_t)(num % den); cpu_.regs[3] = (uint32_t)std::abs(num / den); }
      cpu_.regs[15] = next_pc; return true;
    }
    case 0x08u: cpu_.regs[0] = BiosSqrtLocal(cpu_.regs[0]); cpu_.regs[15] = next_pc; return true;
    case 0x09u: cpu_.regs[0] = (uint32_t)(uint16_t)BiosArcTanPolyLocal((int32_t)cpu_.regs[0]); cpu_.regs[15] = next_pc; return true;
    case 0x0Au: cpu_.regs[0] = (uint32_t)(uint16_t)BiosArcTan2Local((int32_t)cpu_.regs[0], (int32_t)cpu_.regs[1]); cpu_.regs[15] = next_pc; return true;
    case 0x0Bu: HandleCpuSet(false); cpu_.regs[15] = next_pc; return true;
    case 0x0Cu: HandleCpuSet(true); cpu_.regs[15] = next_pc; return true;
    case 0x0Eu: { // BgAffineSet
       uint32_t src = cpu_.regs[0], dst = cpu_.regs[1], count = cpu_.regs[2];
       for (uint32_t i=0; i<count; ++i) {
         int32_t sx = (int32_t)Read32(src), sy = (int32_t)Read32(src+4);
         int16_t dx = (int16_t)Read16(src+8), dy = (int16_t)Read16(src+10);
         int16_t scx = (int16_t)Read16(src+12), scy = (int16_t)Read16(src+14);
         uint16_t theta = Read16(src+16);
         int16_t s = GbaSinLocal(theta), c = GbaCosLocal(theta);
         int16_t pa = (int16_t)((static_cast<int32_t>(c) * scx) >> 14);
         int16_t pb = (int16_t)((static_cast<int32_t>(-s) * scx) >> 14);
         int16_t pc = (int16_t)((static_cast<int32_t>(s) * scy) >> 14);
         int16_t pd = (int16_t)((static_cast<int32_t>(c) * scy) >> 14);
         Write16(dst, pa); Write16(dst+2, pb); Write16(dst+4, pc); Write16(dst+6, pd);
         int32_t rx = sx - (int32_t)((static_cast<int64_t>(pa) * dx + static_cast<int64_t>(pb) * dy) << 8);
         int32_t ry = sy - (int32_t)((static_cast<int64_t>(pc) * dx + static_cast<int64_t>(pd) * dy) << 8);
         Write32(dst+8, (uint32_t)rx); Write32(dst+12, (uint32_t)ry);
         src += 20; dst += 16;
       }
       cpu_.regs[15] = next_pc; return true;
    }
    case 0x0Fu: { // ObjAffineSet
       uint32_t src = cpu_.regs[0], dst = cpu_.regs[1], count = cpu_.regs[2], step = cpu_.regs[3];
       if (step == 0) step = 8;
       for (uint32_t i=0; i<count; ++i) {
         int16_t sx = (int16_t)Read16(src), sy = (int16_t)Read16(src+2);
         uint16_t theta = Read16(src+4);
         int16_t s = GbaSinLocal(theta), c = GbaCosLocal(theta);
         Write16(dst, (int16_t)((static_cast<int32_t>(c) * sx) >> 14));
         Write16(dst+step, (int16_t)((static_cast<int32_t>(-s) * sx) >> 14));
         Write16(dst+step*2, (int16_t)((static_cast<int32_t>(s) * sy) >> 14));
         Write16(dst+step*3, (int16_t)((static_cast<int32_t>(c) * sy) >> 14));
         src += 8; dst += step*4;
       }
       cpu_.regs[15] = next_pc; return true;
    }
    case 0x10u: { // BitUnPack
      uint32_t src = cpu_.regs[0], dst = cpu_.regs[1];
      uint32_t info_ptr = cpu_.regs[2];
      uint16_t len = Read16(info_ptr);
      uint8_t src_w = Read8(info_ptr+2), dst_w = Read8(info_ptr+3);
      uint32_t bias = Read32(info_ptr+4);
      uint32_t data = 0; int bits = 0;
      for (int i=0; i<len; ++i) {
        while (bits < src_w) { data |= (uint32_t)Read8(src++) << bits; bits += 8; }
        uint32_t val = data & ((1 << src_w) - 1);
        data >>= src_w; bits -= src_w;
        if (val || (bias & 0x80000000)) val += (bias & 0x7FFFFFFF);
        if (dst_w == 1) { uint8_t d = Read8(dst + i/8); d = (d & ~(1 << (i%8))) | ((val & 1) << (i%8)); Write8(dst + i/8, d); }
        else if (dst_w == 2) { uint8_t d = Read8(dst + i/4); d = (d & ~(3 << ((i%4)*2))) | ((val & 3) << ((i%4)*2)); Write8(dst + i/4, d); }
        else if (dst_w == 4) { uint8_t d = Read8(dst + i/2); d = (d & ~(0xF << ((i%2)*4))) | ((val & 0xF) << ((i%2)*4)); Write8(dst + i/2, d); }
        else if (dst_w == 8) { Write8(dst + i, (uint8_t)val); }
        else if (dst_w == 16) { Write16(dst + i*2, (uint16_t)val); }
        else if (dst_w == 32) { Write32(dst + i*4, val); }
      }
      cpu_.regs[15] = next_pc; return true;
    }
    case 0x11u:
    case 0x12u:
    case 0x13u:
    case 0x14u:
    case 0x15u:
    case 0x16u:
    case 0x17u:
    case 0x18u: cpu_.regs[15] = next_pc; return true;
    case mgba_compat::kSwiGetBiosChecksum: cpu_.regs[0]=mgba_compat::kBiosChecksum; cpu_.regs[1]=1; cpu_.regs[3]=0x4000; cpu_.regs[15]=next_pc; return true;
    default: return false;
  }
}

} // namespace gba
"""

with open(path, "w") as f:
    f.write(swi_content)
