#if __INCLUDE_LEVEL__ == 0
// Intentionally empty when compiled directly.
// This module is aggregated via src/core/gba_core.mm.
#else
#include "../gba_core.h"

#include <cmath>
#include <cstdlib>
#include <limits>

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
  uint32_t upper = x;
  uint32_t bound = 1;
  while (bound < upper) {
    upper >>= 1;
    bound <<= 1;
  }
  while (true) {
    upper = x;
    uint32_t accum = 0;
    uint32_t lower = bound;
    while (true) {
      const uint32_t old_lower = lower;
      if (lower <= upper >> 1) lower <<= 1;
      if (old_lower >= upper >> 1) break;
    }
    while (true) {
      accum <<= 1;
      if (upper >= lower) {
        ++accum;
        upper -= lower;
      }
      if (lower == bound) break;
      lower >>= 1;
    }
    const uint32_t old_bound = bound;
    bound += accum;
    bound >>= 1;
    if (bound >= old_bound) return old_bound;
  }
}
}  // namespace


bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  // When any BIOS image is mapped (external or built-in mGBA HLE BIOS),
  // dispatch SWI via SVC exception and let BIOS code execute the service.
  if (bios_loaded_) return false;

  const uint32_t next_pc = cpu_.regs[15] + (thumb_state ? 2u : 4u);
  switch (swi_imm & 0xFFu) {
    case 0x00u:  // SoftReset
      Reset();
      return true;
    case 0x01u:  // RegisterRamReset
      HandleRegisterRamReset(static_cast<uint8_t>(cpu_.regs[0] & 0xFFu));
      cpu_.regs[15] = next_pc;
      return true;
    case 0x04u:  // IntrWait
    case 0x05u: {  // VBlankIntrWait
      uint16_t request = 0;
      if ((swi_imm & 0xFFu) == 0x05u) {
        request = 0x0001u;  // VBlank
      } else {
        request = static_cast<uint16_t>(cpu_.regs[1] & 0x3FFFu);
        if (request == 0) request = 0x0001u;
      }
      // R0==0: discard already-raised requested IRQ flags before waiting.
      if ((cpu_.regs[0] & 0x1u) == 0u) {
        WriteIO16(0x04000202u, request);
      }
      const uint16_t ie = ReadIO16(0x04000200u);
      WriteIO16(0x04000200u, static_cast<uint16_t>(ie | request));
      WriteIO16(0x04000208u, 0x0001u);  // IME on
      swi_intrwait_active_ = true;
      swi_intrwait_mask_ = request;
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x02u:  // Halt
    case 0x03u:  // Stop (approximated as Halt)
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    case mgba_compat::kSwiDiv: {  // Div
      const int32_t num = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t den = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>((num < 0) ? -1 : 1);
        cpu_.regs[1] = static_cast<uint32_t>(num);
        cpu_.regs[3] = 1;
      } else if (den == -1 && num == std::numeric_limits<int32_t>::min()) {
        cpu_.regs[0] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
      } else {
        const std::div_t qr = std::div(num, den);
        const int32_t q = qr.quot;
        const int32_t r = qr.rem;
        cpu_.regs[0] = static_cast<uint32_t>(q);
        cpu_.regs[1] = static_cast<uint32_t>(r);
        cpu_.regs[3] = static_cast<uint32_t>(q < 0 ? -q : q);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiDivArm: {  // DivArm (R0=denom, R1=numer)
      const int32_t den = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t num = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>((num < 0) ? -1 : 1);
        cpu_.regs[1] = static_cast<uint32_t>(num);
        cpu_.regs[3] = 1;
      } else if (den == -1 && num == std::numeric_limits<int32_t>::min()) {
        cpu_.regs[0] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
      } else {
        const std::div_t qr = std::div(num, den);
        const int32_t q = qr.quot;
        const int32_t r = qr.rem;
        cpu_.regs[0] = static_cast<uint32_t>(q);
        cpu_.regs[1] = static_cast<uint32_t>(r);
        cpu_.regs[3] = static_cast<uint32_t>(q < 0 ? -q : q);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiSqrt: {  // Sqrt
      const uint32_t x = cpu_.regs[0];
      cpu_.regs[0] = BiosSqrtLocal(x);
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiArcTan: {  // ArcTan
      const int32_t tan_q14 = static_cast<int32_t>(cpu_.regs[0]);
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(BiosArcTanPolyLocal(tan_q14)));
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiArcTan2: {  // ArcTan2
      const int32_t x = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t y = static_cast<int32_t>(cpu_.regs[1]);
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(BiosArcTan2Local(x, y)));
      cpu_.regs[3] = 0x170u;  // BIOS side-effect observed by many titles.
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Eu: {  // BgAffineSet
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      while (count--) {
        const double ox = static_cast<double>(static_cast<int32_t>(Read32(src + 0u))) / 256.0;
        const double oy = static_cast<double>(static_cast<int32_t>(Read32(src + 4u))) / 256.0;
        const double cx = static_cast<double>(static_cast<int16_t>(Read16(src + 8u)));
        const double cy = static_cast<double>(static_cast<int16_t>(Read16(src + 10u)));
        const double sx = static_cast<double>(static_cast<int16_t>(Read16(src + 12u))) / 256.0;
        const double sy = static_cast<double>(static_cast<int16_t>(Read16(src + 14u))) / 256.0;
        const double theta =
            static_cast<double>((Read16(src + 16u) >> 8) & 0xFFu) / 128.0 * 3.14159265358979323846;
        src += 20u;

        const double cos_t = std::cos(theta);
        const double sin_t = std::sin(theta);
        const double a = cos_t * sx;
        const double b = -sin_t * sx;
        const double c = sin_t * sy;
        const double d = cos_t * sy;
        const double rx = ox - (a * cx + b * cy);
        const double ry = oy - (c * cx + d * cy);

        Write16(dst + 0u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(a * 256.0))));
        Write16(dst + 2u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(b * 256.0))));
        Write16(dst + 4u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(c * 256.0))));
        Write16(dst + 6u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(d * 256.0))));
        Write32(dst + 8u, static_cast<uint32_t>(static_cast<int32_t>(std::lround(rx * 256.0))));
        Write32(dst + 12u, static_cast<uint32_t>(static_cast<int32_t>(std::lround(ry * 256.0))));
        dst += 16u;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Fu: {  // ObjAffineSet
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      const uint32_t diff = cpu_.regs[3];
      while (count--) {
        const double sx = static_cast<double>(static_cast<int16_t>(Read16(src + 0u))) / 256.0;
        const double sy = static_cast<double>(static_cast<int16_t>(Read16(src + 2u))) / 256.0;
        const double theta =
            static_cast<double>((Read16(src + 4u) >> 8) & 0xFFu) / 128.0 * 3.14159265358979323846;
        src += 8u;
        const double cos_t = std::cos(theta);
        const double sin_t = std::sin(theta);
        const double a = cos_t * sx;
        const double b = -sin_t * sx;
        const double c = sin_t * sy;
        const double d = cos_t * sy;
        Write16(dst + 0u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(a * 256.0))));
        Write16(dst + diff, static_cast<uint16_t>(static_cast<int16_t>(std::lround(b * 256.0))));
        Write16(dst + diff * 2u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(c * 256.0))));
        Write16(dst + diff * 3u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(d * 256.0))));
        dst += diff * 4u;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x10u: {  // BitUnPack
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      const uint32_t info = cpu_.regs[2];
      uint32_t source_len = Read16(info + 0u);
      const uint32_t source_width = Read8(info + 2u);
      const uint32_t dest_width = Read8(info + 3u);
      if ((source_width != 1u && source_width != 2u && source_width != 4u && source_width != 8u) ||
          (dest_width != 1u && dest_width != 2u && dest_width != 4u && dest_width != 8u &&
           dest_width != 16u && dest_width != 32u)) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t bias = Read32(info + 4u);
      uint8_t in = 0;
      uint32_t out = 0;
      int bits_remaining = 0;
      int bits_eaten = 0;
      while (source_len > 0 || bits_remaining > 0) {
        if (bits_remaining == 0) {
          in = Read8(src++);
          bits_remaining = 8;
          --source_len;
        }
        uint32_t scaled = static_cast<uint32_t>(in) & ((1u << source_width) - 1u);
        in = static_cast<uint8_t>(in >> source_width);
        if (scaled != 0u || (bias & 0x80000000u) != 0u) {
          scaled += (bias & 0x7FFFFFFFu);
        }
        bits_remaining -= static_cast<int>(source_width);
        out |= (scaled << bits_eaten);
        bits_eaten += static_cast<int>(dest_width);
        if (bits_eaten == 32) {
          Write32(dst, out);
          dst += 4u;
          out = 0;
          bits_eaten = 0;
        }
      }
      cpu_.regs[0] = src;
      cpu_.regs[1] = dst;
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x11u:  // LZ77UnCompWram
    case 0x12u: {  // LZ77UnCompVram
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x10u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      std::vector<uint8_t> out;
      out.reserve(out_size);
      while (out.size() < out_size) {
        uint8_t flags = Read8(src++);
        for (int i = 0; i < 8 && out.size() < out_size; ++i) {
          if ((flags & 0x80u) != 0) {
            const uint8_t b1 = Read8(src++);
            const uint8_t b2 = Read8(src++);
            const uint32_t len = static_cast<uint32_t>((b1 >> 4) + 3u);
            const uint32_t disp = static_cast<uint32_t>(((b1 & 0x0Fu) << 8) | b2);
            if (disp + 1u > out.size()) break;
            size_t copy_from = out.size() - (disp + 1u);
            for (uint32_t j = 0; j < len && out.size() < out_size; ++j) {
              out.push_back(out[copy_from + j]);
            }
          } else {
            out.push_back(Read8(src++));
          }
          flags <<= 1;
        }
      }
      const bool to_vram = ((swi_imm & 0xFFu) == 0x12u);
      if (to_vram) {
        uint32_t i = 0;
        while (i < out.size()) {
          const uint16_t lo = out[i];
          const uint16_t hi = (i + 1 < out.size()) ? static_cast<uint16_t>(out[i + 1]) : 0u;
          Write16(dst + i, static_cast<uint16_t>(lo | (hi << 8)));
          i += 2;
        }
      } else {
        for (uint32_t i = 0; i < out.size(); ++i) {
          Write8(dst + i, out[i]);
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x13u: {  // HuffUnComp (4-bit/8-bit)
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x20u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      const uint8_t data_bits = Read8(src++);
      if (data_bits != 4u && data_bits != 8u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint8_t tree_size_field = Read8(src++);
      const uint32_t tree_bytes = static_cast<uint32_t>(tree_size_field + 1u) * 2u;
      const uint32_t tree_base = src;
      uint32_t stream = src + tree_bytes;

      auto read_stream_bit = [&](uint32_t* ptr, uint32_t* bitbuf, int* bits_left) -> uint32_t {
        if (*bits_left == 0) {
          *bitbuf = Read32(*ptr);
          *ptr += 4u;
          *bits_left = 32;
        }
        const uint32_t bit = (*bitbuf >> 31) & 1u;
        *bitbuf <<= 1;
        --(*bits_left);
        return bit;
      };

      auto decode_symbol = [&](uint32_t* ptr, uint32_t* bitbuf, int* bits_left) -> uint8_t {
        uint32_t node_off = 0u;
        while (true) {
          const uint8_t node = Read8(tree_base + node_off);
          const uint32_t dir = read_stream_bit(ptr, bitbuf, bits_left);
          const uint32_t child_off = node_off + (static_cast<uint32_t>(node & 0x3Fu) + 1u) * 2u;
          const uint32_t entry_off = child_off + dir;
          const bool terminal = (node & (dir ? 0x80u : 0x40u)) != 0;
          if (terminal) {
            return Read8(tree_base + entry_off);
          }
          node_off = entry_off;
          if (node_off >= tree_bytes) return 0;
        }
      };

      std::vector<uint8_t> out;
      out.reserve(out_size);
      uint32_t bitbuf = 0;
      int bits_left = 0;
      if (data_bits == 8u) {
        while (out.size() < out_size) {
          out.push_back(decode_symbol(&stream, &bitbuf, &bits_left));
        }
      } else {  // 4-bit
        while (out.size() < out_size) {
          const uint8_t lo = static_cast<uint8_t>(decode_symbol(&stream, &bitbuf, &bits_left) & 0x0Fu);
          uint8_t byte = lo;
          if (out.size() + 1u < out_size) {
            const uint8_t hi = static_cast<uint8_t>(decode_symbol(&stream, &bitbuf, &bits_left) & 0x0Fu);
            byte = static_cast<uint8_t>(lo | (hi << 4));
          }
          out.push_back(byte);
        }
      }
      for (uint32_t i = 0; i < out.size(); ++i) {
        Write8(dst + i, out[i]);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x14u:  // RLUnCompWram
    case 0x15u: {  // RLUnCompVram
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x30u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      std::vector<uint8_t> out;
      out.reserve(out_size);
      while (out.size() < out_size) {
        const uint8_t ctrl = Read8(src++);
        if ((ctrl & 0x80u) != 0) {
          const uint32_t len = static_cast<uint32_t>((ctrl & 0x7Fu) + 3u);
          const uint8_t value = Read8(src++);
          for (uint32_t i = 0; i < len && out.size() < out_size; ++i) out.push_back(value);
        } else {
          const uint32_t len = static_cast<uint32_t>((ctrl & 0x7Fu) + 1u);
          for (uint32_t i = 0; i < len && out.size() < out_size; ++i) out.push_back(Read8(src++));
        }
      }
      const bool to_vram = ((swi_imm & 0xFFu) == 0x15u);
      if (to_vram) {
        uint32_t i = 0;
        while (i < out.size()) {
          const uint16_t lo = out[i];
          const uint16_t hi = (i + 1 < out.size()) ? static_cast<uint16_t>(out[i + 1]) : 0u;
          Write16(dst + i, static_cast<uint16_t>(lo | (hi << 8)));
          i += 2;
        }
      } else {
        for (uint32_t i = 0; i < out.size(); ++i) {
          Write8(dst + i, out[i]);
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x16u:  // Diff8bitUnFilterWram
    case 0x17u: {  // Diff8bitUnFilterVram
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x80u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      std::vector<uint8_t> out;
      out.reserve(out_size);
      uint8_t acc = 0;
      for (uint32_t i = 0; i < out_size; ++i) {
        const uint8_t delta = Read8(src++);
        if (i == 0) {
          acc = delta;
        } else {
          acc = static_cast<uint8_t>(acc + delta);
        }
        out.push_back(acc);
      }
      const bool to_vram = ((swi_imm & 0xFFu) == 0x17u);
      if (to_vram) {
        uint32_t i = 0;
        while (i < out.size()) {
          const uint16_t lo = out[i];
          const uint16_t hi = (i + 1 < out.size()) ? static_cast<uint16_t>(out[i + 1]) : 0u;
          Write16(dst + i, static_cast<uint16_t>(lo | (hi << 8)));
          i += 2;
        }
      } else {
        for (uint32_t i = 0; i < out.size(); ++i) {
          Write8(dst + i, out[i]);
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x18u: {  // Diff16bitUnFilter
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x80u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      uint16_t acc = 0;
      for (uint32_t i = 0; i + 1 < out_size; i += 2) {
        const uint16_t delta = Read16(src);
        src += 2u;
        if (i == 0) {
          acc = delta;
        } else {
          acc = static_cast<uint16_t>(acc + delta);
        }
        Write16(dst + i, acc);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Bu:  // CpuSet
      HandleCpuSet(false);
      cpu_.regs[15] = next_pc;
      return true;
    case 0x0Cu:  // CpuFastSet
      HandleCpuSet(true);
      cpu_.regs[15] = next_pc;
      return true;
    case mgba_compat::kSwiGetBiosChecksum:  // GetBiosChecksum
      cpu_.regs[0] = mgba_compat::kBiosChecksum;
      cpu_.regs[1] = 1u;
      cpu_.regs[3] = 0x4000u;
      cpu_.regs[15] = next_pc;
      return true;
    default:
      return false;
  }
}

}  // namespace gba
#endif
