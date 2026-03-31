#include "../gba_core.h"
#include <cmath>
#include <cstdlib>
#include <limits>
#include <algorithm>
#include <functional>
#include <array>

namespace gba {
namespace {

// =========================================================================
// 数学ヘルパー
// =========================================================================

// BiosArcTanPoly: GBA BIOS の多項式近似
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

// BiosArcTan2 (GBA BIOS準拠)
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

// BiosSqrt: ニュートン法による整数平方根 (GBA BIOS準拠、無限ループなし)
inline uint32_t BiosSqrtLocal(uint32_t x) {
  if (x == 0) return 0;
  if (x < 4)  return 1;
  // 初期推定: 2^(ceil(log2(x)/2))
  uint32_t guess = 1u;
  while (guess * guess < x && guess < 0x10000u) guess <<= 1;
  // ニュートン法: x_{n+1} = (x_n + val/x_n) / 2
  for (int iter = 0; iter < 32; ++iter) {
    const uint32_t next = (guess + x / guess) >> 1;
    if (next >= guess) break;
    guess = next;
  }
  // 丸め: guess か guess-1 のどちらが正確か
  while (guess > 0 && (uint64_t)guess * guess > x) --guess;
  return guess;
}

// Sin/Cos (GBA BIOS互換, 固定小数点 1.14)
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

inline int16_t GbaSinLocal(uint16_t angle) {
  return GbaSinLutLocal()[angle];
}

inline int16_t GbaCosLocal(uint16_t angle) {
  constexpr uint16_t kQuarterTurn = 0x4000u;
  return GbaSinLutLocal()[static_cast<uint16_t>(angle + kQuarterTurn)];
}

inline bool ShouldHandleSwiInHleFastPath(uint32_t swi_num) {
  switch (swi_num & 0xFFu) {
    case 0x04u:  // IntrWait
    case 0x05u:  // VBlankIntrWait
    case 0x06u:  // Div
    case 0x07u:  // DivArm
    case 0x08u:  // Sqrt
    case 0x09u:  // ArcTan
    case 0x0Au:  // ArcTan2
    case 0x0Bu:  // CpuSet
    case 0x0Cu:  // CpuFastSet
    case 0x0Du:  // GetBiosChecksum
    case 0x0Eu:  // BgAffineSet
    case 0x0Fu:  // ObjAffineSet
    case 0x10u:  // BitUnPack
    case 0x11u:  // LZ77UnCompWRAM
    case 0x12u:  // LZ77UnCompVRAM
    case 0x13u:  // HuffUnComp
    case 0x14u:  // RLUnCompWRAM
    case 0x15u:  // RLUnCompVRAM
    case 0x16u:  // Diff8UnFilterWRAM
    case 0x17u:  // Diff8UnFilterVRAM
    case 0x18u:  // Diff16UnFilter
      return true;
    default:
      return false;
  }
}

// LZ77圧縮展開 (SWI 0x11)
inline void DecompressLZ77(uint32_t src, uint32_t dst, bool byte_mode,
                            std::function<uint8_t(uint32_t)> read8,
                            std::function<void(uint32_t,uint8_t)> write8) {
  const uint32_t header = read8(src) | (read8(src+1)<<8) | (read8(src+2)<<16) | (read8(src+3)<<24);
  const uint32_t decomp_len = header >> 8;
  src += 4;
  uint32_t written = 0;
  while (written < decomp_len) {
    uint8_t flags = read8(src++);
    for (int b = 7; b >= 0 && written < decomp_len; --b) {
      if (!((flags >> b) & 1)) {
        write8(dst + written, read8(src++));
        ++written;
      } else {
        const uint8_t b0 = read8(src++), b1 = read8(src++);
        const int disp  = static_cast<int>(((b0 & 0x0Fu) << 8) | b1) + 1;
        const int count = static_cast<int>((b0 >> 4) & 0xFu) + 3;
        for (int i = 0; i < count && written < decomp_len; ++i, ++written) {
          write8(dst + written, read8(dst + written - disp));
        }
      }
    }
  }
}

// RLE圧縮展開 (SWI 0x14)
inline void DecompressRLE(uint32_t src, uint32_t dst,
                          std::function<uint8_t(uint32_t)> read8,
                          std::function<void(uint32_t,uint8_t)> write8) {
  const uint32_t decomp_len = (read8(src) | (read8(src+1)<<8) | (read8(src+2)<<16) | (read8(src+3)<<24)) >> 8;
  src += 4;
  uint32_t written = 0;
  while (written < decomp_len) {
    uint8_t flags = read8(src++);
    if (flags & 0x80u) {
      const int count = (flags & 0x7Fu) + 3;
      const uint8_t val = read8(src++);
      for (int i = 0; i < count && written < decomp_len; ++i, ++written)
        write8(dst + written, val);
    } else {
      const int count = (flags & 0x7Fu) + 1;
      for (int i = 0; i < count && written < decomp_len; ++i, ++written)
        write8(dst + written, read8(src++));
    }
  }
}

// Huffman展開 (SWI 0x13)
inline void DecompressHuffman(uint32_t src, uint32_t dst,
                               std::function<uint8_t(uint32_t)> read8,
                               std::function<void(uint32_t,uint8_t)> write8,
                               std::function<uint32_t(uint32_t)> read32,
                               std::function<void(uint32_t,uint32_t)> write32) {
  uint32_t source = src & 0xFFFFFFFCu;
  uint32_t dest_addr = dst;
  const uint32_t header = read32(source);
  int remaining = static_cast<int>(header >> 8);
  const unsigned bits = header & 0xFu;
  if (bits == 0u || bits == 1u || (32u % bits) != 0u) {
    return;
  }

  const int tree_size = (static_cast<int>(read8(source + 4u)) << 1) + 1;
  const uint32_t tree_base = source + 5u;
  source += 5u + static_cast<uint32_t>(tree_size);

  uint32_t node_ptr = tree_base;
  uint8_t node = read8(node_ptr);
  uint32_t block = 0;
  int bits_seen = 0;

  while (remaining > 0) {
    uint32_t bitstream = read32(source);
    source += 4u;
    for (int bits_remaining = 32; bits_remaining > 0 && remaining > 0; --bits_remaining, bitstream <<= 1) {
      const uint32_t next = (node_ptr & ~1u) + static_cast<uint32_t>(node & 0x3Fu) * 2u + 2u;
      uint8_t read_bits = 0;
      if ((bitstream & 0x80000000u) != 0u) {
        if ((node & 0x40u) != 0u) {
          read_bits = read8(next + 1u);
        } else {
          node_ptr = next + 1u;
          node = read8(node_ptr);
          continue;
        }
      } else {
        if ((node & 0x80u) != 0u) {
          read_bits = read8(next);
        } else {
          node_ptr = next;
          node = read8(node_ptr);
          continue;
        }
      }

      block |= static_cast<uint32_t>(read_bits & ((1u << bits) - 1u)) << bits_seen;
      bits_seen += static_cast<int>(bits);
      node_ptr = tree_base;
      node = read8(node_ptr);
      if (bits_seen == 32) {
        write32(dest_addr, block);
        dest_addr += 4u;
        remaining -= 4;
        bits_seen = 0;
        block = 0;
      }
    }
  }

  (void)write8;
}

inline void DecompressDiffFilter(uint32_t src, uint32_t dst, int in_width, int out_width,
                                 std::function<uint8_t(uint32_t)> read8,
                                 std::function<uint16_t(uint32_t)> read16,
                                 std::function<void(uint32_t,uint8_t)> write8,
                                 std::function<void(uint32_t,uint16_t)> write16) {
  uint32_t source = src & 0xFFFFFFFCu;
  uint32_t dest_addr = dst;
  const uint32_t header = (static_cast<uint32_t>(read8(source)) |
                           (static_cast<uint32_t>(read8(source + 1u)) << 8) |
                           (static_cast<uint32_t>(read8(source + 2u)) << 16) |
                           (static_cast<uint32_t>(read8(source + 3u)) << 24));
  int remaining = static_cast<int>(header >> 8);
  uint16_t halfword = 0;
  uint16_t old = 0;
  source += 4u;

  while (remaining > 0) {
    uint16_t value = in_width == 1 ? read8(source) : read16(source);
    value = static_cast<uint16_t>(value + old);
    if (out_width > in_width) {
      halfword >>= 8;
      halfword = static_cast<uint16_t>(halfword | static_cast<uint16_t>(value << 8));
      if ((source & 1u) != 0u) {
        write16(dest_addr, halfword);
        dest_addr += static_cast<uint32_t>(out_width);
        remaining -= out_width;
      }
    } else if (out_width == 1) {
      write8(dest_addr, static_cast<uint8_t>(value & 0xFFu));
      ++dest_addr;
      --remaining;
    } else {
      write16(dest_addr, value);
      dest_addr += 2u;
      remaining -= 2;
    }
    old = value;
    source += static_cast<uint32_t>(in_width);
  }
}

}  // namespace

// =========================================================================
// HandleSoftwareInterrupt
// =========================================================================
bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  const uint32_t swi_num = swi_imm & 0xFFu;
  const bool vector_boot = bios_loaded_ && bios_boot_via_vector_;
  // 実BIOSベクタモードでも、頻出/重い処理はHLEで高速処理するハイブリッド運用。
  if (vector_boot && !ShouldHandleSwiInHleFastPath(swi_num)) {
    cpu_.regs[15] += thumb_state ? 2u : 4u;
    EnterException(0x00000008u, 0x13u, true, thumb_state);
    return true;
  }

  const uint32_t next_pc = cpu_.regs[15] + (thumb_state ? 2u : 4u);

  // ラムダ: Read/Write ショートカット
  auto rd8  = [&](uint32_t a) -> uint8_t    { return Read8(a); };
  auto rd16 = [&](uint32_t a) -> uint16_t   { return Read16(a); };
  auto rd32 = [&](uint32_t a) -> uint32_t   { return Read32(a); };
  auto wr8  = [&](uint32_t a, uint8_t v)    { Write8(a, v); };
  auto wr16 = [&](uint32_t a, uint16_t v)   { Write16(a, v); };
  auto wr32 = [&](uint32_t a, uint32_t v)   { Write32(a, v); };

  switch (swi_num) {
    // ----- SWI 00h: SoftReset -----
    case 0x00u:
      Reset();
      return true;

    // ----- SWI 01h: RegisterRamReset -----
    case 0x01u:
      HandleRegisterRamReset(static_cast<uint8_t>(cpu_.regs[0] & 0xFFu));
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 02h: Halt -----
    case 0x02u:
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 03h: Stop/Sleep -----
    case 0x03u:
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 04h: IntrWait -----
    case 0x04u: {
      const bool clear_old = (cpu_.regs[0] != 0u);
      uint16_t request = static_cast<uint16_t>(cpu_.regs[1] & 0x3FFFu);
      if (request == 0) request = 0x0001u;
      if (clear_old) WriteIO16(0x04000202u, 0x3FFFu);
      WriteIO16(0x04000208u, 0x0001u);  // IME=1 like BIOS wait path
      const uint16_t ie = ReadIO16(0x04000200u);
      const uint16_t iflags = ReadIO16(0x04000202u);
      const uint16_t matched = static_cast<uint16_t>(iflags & ie & request);
      if (matched != 0u) {
        WriteIO16(0x04000202u, matched);
        swi_intrwait_active_ = false;
        swi_intrwait_mask_   = 0;
      } else {
        swi_intrwait_active_ = true;
        swi_intrwait_mask_   = request;
        cpu_.halted = true;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 05h: VBlankIntrWait -----
    case 0x05u: {
      // BIOS behavior is effectively IntrWait(clear_old=1, request=VBlank).
      // Always clear stale VBlank IF first, then wait for the *next* VBlank.
      WriteIO16(0x04000202u, 0x0001u);
      WriteIO16(0x04000208u, 0x0001u);  // IME=1 like BIOS wait path
      swi_intrwait_active_ = true;
      swi_intrwait_mask_   = 0x0001u;
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 06h: Div -----
    case 0x06u: {
      const int32_t num = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t den = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>(num);
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(std::abs(static_cast<int64_t>(num)));
      } else if (den == -1 && num == std::numeric_limits<int32_t>::min()) {
        cpu_.regs[0] = static_cast<uint32_t>(num);
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(static_cast<uint64_t>(std::numeric_limits<int32_t>::max()) + 1u);
      } else {
        cpu_.regs[0] = static_cast<uint32_t>(num / den);
        cpu_.regs[1] = static_cast<uint32_t>(num % den);
        cpu_.regs[3] = static_cast<uint32_t>(std::abs(num / den));
      }
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 07h: DivArm -----
    case 0x07u: {
      const int32_t den = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t num = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>(num);
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(std::abs(static_cast<int64_t>(num)));
      } else if (den == -1 && num == std::numeric_limits<int32_t>::min()) {
        cpu_.regs[0] = static_cast<uint32_t>(num);
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(static_cast<uint64_t>(std::numeric_limits<int32_t>::max()) + 1u);
      } else {
        cpu_.regs[0] = static_cast<uint32_t>(num / den);
        cpu_.regs[1] = static_cast<uint32_t>(num % den);
        cpu_.regs[3] = static_cast<uint32_t>(std::abs(num / den));
      }
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 08h: Sqrt -----
    case 0x08u:
      cpu_.regs[0] = BiosSqrtLocal(cpu_.regs[0]);
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 09h: ArcTan -----
    case 0x09u:
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(
          BiosArcTanPolyLocal(static_cast<int32_t>(cpu_.regs[0]))));
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 0Ah: ArcTan2 -----
    case 0x0Au:
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(
          BiosArcTan2Local(static_cast<int32_t>(cpu_.regs[0]),
                           static_cast<int32_t>(cpu_.regs[1]))));
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 0Bh: CpuSet -----
    case 0x0Bu:
      HandleCpuSet(false);
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 0Ch: CpuFastSet -----
    case 0x0Cu:
      HandleCpuSet(true);
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 0Dh: GetBiosChecksum -----
    case 0x0Du:
      cpu_.regs[0] = mgba_compat::kBiosChecksum;
      cpu_.regs[1] = 1;
      cpu_.regs[3] = 0x4000u;
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 0Eh: BgAffineSet -----
    case 0x0Eu: {
      uint32_t src   = cpu_.regs[0];
      uint32_t dst   = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      for (uint32_t i = 0; i < count; ++i) {
        const int32_t ox  = static_cast<int32_t>(rd32(src));
        const int32_t oy  = static_cast<int32_t>(rd32(src + 4u));
        const int16_t dx  = static_cast<int16_t>(rd16(src + 8u));
        const int16_t dy  = static_cast<int16_t>(rd16(src + 10u));
        const int16_t scx = static_cast<int16_t>(rd16(src + 12u));
        const int16_t scy = static_cast<int16_t>(rd16(src + 14u));
        const uint16_t theta = rd16(src + 16u);
        const int16_t s = GbaSinLocal(theta);
        const int16_t c = GbaCosLocal(theta);
        const int16_t pa = static_cast<int16_t>((static_cast<int32_t>(c) * scx) >> 14);
        const int16_t pb = static_cast<int16_t>((static_cast<int32_t>(-s) * scx) >> 14);
        const int16_t pc = static_cast<int16_t>((static_cast<int32_t>(s) * scy) >> 14);
        const int16_t pd = static_cast<int16_t>((static_cast<int32_t>(c) * scy) >> 14);
        wr16(dst,     static_cast<uint16_t>(pa));
        wr16(dst + 2u, static_cast<uint16_t>(pb));
        wr16(dst + 4u, static_cast<uint16_t>(pc));
        wr16(dst + 6u, static_cast<uint16_t>(pd));
        const int32_t rx = ox - static_cast<int32_t>(
            (static_cast<int64_t>(pa) * dx + static_cast<int64_t>(pb) * dy) >> 8);
        const int32_t ry = oy - static_cast<int32_t>(
            (static_cast<int64_t>(pc) * dx + static_cast<int64_t>(pd) * dy) >> 8);
        wr32(dst + 8u,  static_cast<uint32_t>(rx));
        wr32(dst + 12u, static_cast<uint32_t>(ry));
        src += 20u;
        dst += 16u;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 0Fh: ObjAffineSet -----
    case 0x0Fu: {
      uint32_t src   = cpu_.regs[0];
      uint32_t dst   = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      uint32_t step  = cpu_.regs[3];
      if (step == 0) step = 8u;
      for (uint32_t i = 0; i < count; ++i) {
        const int16_t sx    = static_cast<int16_t>(rd16(src));
        const int16_t sy    = static_cast<int16_t>(rd16(src + 2u));
        const uint16_t theta = rd16(src + 4u);
        const int16_t s = GbaSinLocal(theta);
        const int16_t c = GbaCosLocal(theta);
        wr16(dst,            static_cast<uint16_t>((static_cast<int32_t>(c) * sx) >> 14));
        wr16(dst + step,     static_cast<uint16_t>((static_cast<int32_t>(-s) * sx) >> 14));
        wr16(dst + step*2u,  static_cast<uint16_t>((static_cast<int32_t>(s) * sy) >> 14));
        wr16(dst + step*3u,  static_cast<uint16_t>((static_cast<int32_t>(c) * sy) >> 14));
        src += 8u;
        dst += step * 4u;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 10h: BitUnPack -----
    case 0x10u: {
      uint32_t src      = cpu_.regs[0];
      uint32_t dst      = cpu_.regs[1];
      uint32_t info_ptr = cpu_.regs[2];
      const uint16_t len  = rd16(info_ptr);
      const uint8_t  sw   = rd8(info_ptr + 2u);
      const uint8_t  dw   = rd8(info_ptr + 3u);
      const uint32_t bias = rd32(info_ptr + 4u);
      if (sw == 0 || dw == 0 || dw > 32 || sw > dw) { cpu_.regs[15] = next_pc; return true; }
      const uint32_t src_mask = (1u << sw) - 1u;
      uint32_t data = 0; int bits = 0;
      uint32_t dst_buf = 0; int dst_bits = 0;
      for (int i = 0; i < (int)len; ) {
        while (bits < (int)sw) { data |= (uint32_t)rd8(src++) << bits; bits += 8; i++; if(i>(int)len)break; }
        if(i>(int)len && bits<(int)sw) break;
        uint32_t val = data & src_mask;
        data >>= sw; bits -= sw;
        if (val || (bias & 0x80000000u)) val += (bias & 0x7FFFFFFFu);
        val &= (1u << dw) - 1u;
        dst_buf |= val << dst_bits;
        dst_bits += dw;
        if (dst_bits >= 32) {
          wr32(dst, dst_buf);
          dst += 4; dst_buf = 0; dst_bits = 0;
        }
      }
      if (dst_bits > 0) wr32(dst, dst_buf);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 11h: LZ77UnCompWRAM -----
    case 0x11u: {
      const uint32_t src = cpu_.regs[0], dst = cpu_.regs[1];
      DecompressLZ77(src, dst, false,
        [&](uint32_t a){ return rd8(a); },
        [&](uint32_t a, uint8_t v){ wr8(a, v); });
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 12h: LZ77UnCompVRAM -----
    case 0x12u: {
      const uint32_t src = cpu_.regs[0], dst = cpu_.regs[1];
      // VRAM は16bit書き込みのみ (2バイトずつ)
      std::vector<uint8_t> tmp_buf;
      tmp_buf.reserve(0x8000);
      const uint32_t hdr = rd32(src);
      const uint32_t decomp_len = hdr >> 8;
      tmp_buf.resize(decomp_len);
      // まず一時バッファへ展開
      uint32_t s = src + 4; uint32_t written = 0;
      while (written < decomp_len) {
        uint8_t flags = rd8(s++);
        for (int b = 7; b >= 0 && written < decomp_len; --b) {
          if (!((flags >> b) & 1)) {
            if(written < tmp_buf.size()) tmp_buf[written] = rd8(s++);
            ++written;
          } else {
            const uint8_t b0 = rd8(s++), b1 = rd8(s++);
            const int disp  = static_cast<int>(((b0 & 0x0Fu) << 8) | b1) + 1;
            const int count = static_cast<int>((b0 >> 4) & 0xFu) + 3;
            for (int i = 0; i < count && written < decomp_len; ++i, ++written)
              if(written < tmp_buf.size()) tmp_buf[written] = (written >= (uint32_t)disp) ? tmp_buf[written-disp] : 0;
          }
        }
      }
      // VRAM へ16bit書き込み
      for (uint32_t i = 0; i + 1 < decomp_len; i += 2) {
        wr16(dst + i, static_cast<uint16_t>(tmp_buf[i]) | (static_cast<uint16_t>(tmp_buf[i+1]) << 8));
      }
      if (decomp_len & 1) wr8(dst + decomp_len - 1, tmp_buf[decomp_len-1]);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 13h: HuffUnComp -----
    case 0x13u: {
      DecompressHuffman(cpu_.regs[0], cpu_.regs[1],
        [&](uint32_t a){ return rd8(a); },
        [&](uint32_t a, uint8_t v){ wr8(a, v); },
        [&](uint32_t a){ return rd32(a); },
        [&](uint32_t a, uint32_t v){ wr32(a, v); });
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 14h: RLUnCompWRAM -----
    case 0x14u: {
      const uint32_t src = cpu_.regs[0], dst = cpu_.regs[1];
      DecompressRLE(src, dst,
        [&](uint32_t a){ return rd8(a); },
        [&](uint32_t a, uint8_t v){ wr8(a, v); });
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 15h: RLUnCompVRAM -----
    case 0x15u: {
      const uint32_t src = cpu_.regs[0], dst = cpu_.regs[1];
      // VRAM版: 16bit書き込み
      const uint32_t decomp_len = (rd32(src) >> 8);
      uint32_t s = src + 4; uint32_t d = dst; uint32_t written = 0;
      while (written < decomp_len) {
        uint8_t flags = rd8(s++);
        if (flags & 0x80u) {
          const int count = (flags & 0x7Fu) + 3;
          const uint8_t val = rd8(s++);
          for (int i = 0; i < count && written < decomp_len; ++i, ++written, ++d) {
            if (d & 1) wr16(d & ~1u, (rd16(d & ~1u) & 0x00FFu) | (static_cast<uint16_t>(val)<<8));
            else       wr16(d,       (rd16(d) & 0xFF00u) | val);
          }
        } else {
          const int count = (flags & 0x7Fu) + 1;
          for (int i = 0; i < count && written < decomp_len; ++i, ++written, ++d) {
            const uint8_t val = rd8(s++);
            if (d & 1) wr16(d & ~1u, (rd16(d & ~1u) & 0x00FFu) | (static_cast<uint16_t>(val)<<8));
            else       wr16(d,       (rd16(d) & 0xFF00u) | val);
          }
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 16h-18h: Diff Filter -----
    case 0x16u: case 0x17u: case 0x18u: {
      const int in_width = swi_num == 0x18u ? 2 : 1;
      const int out_width = swi_num == 0x17u ? 2 : in_width;
      DecompressDiffFilter(cpu_.regs[0], cpu_.regs[1], in_width, out_width,
        [&](uint32_t a){ return rd8(a); },
        [&](uint32_t a){ return rd16(a); },
        [&](uint32_t a, uint8_t v){ wr8(a, v); },
        [&](uint32_t a, uint16_t v){ wr16(a, v); });
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 19h-1Fh: Sound/その他 (スタブ) -----
    case 0x19u: case 0x1Au: case 0x1Bu: case 0x1Cu:
    case 0x1Du: case 0x1Eu: case 0x1Fu:
      cpu_.regs[15] = next_pc;
      return true;

    // ----- SWI 0Dh別名: GetBiosChecksum -----
    // (mgba_compat::kSwiGetBiosChecksum == 0x0D)

    default:
      if (vector_boot) {
        cpu_.regs[15] = next_pc;
        EnterException(0x00000008u, 0x13u, true, thumb_state);
        return true;
      }
      return false;
  }
}

}  // namespace gba
