#include "../gba_core.h"
#include <cmath>
#include <cstdlib>
#include <limits>
#include <algorithm>
#include <functional>
#include <array>
#include <vector>
#include <cstdio>

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
  uint32_t guess = 1u;
  while (guess * guess < x && guess < 0x10000u) guess <<= 1;
  for (int iter = 0; iter < 32; ++iter) {
    const uint32_t next = (guess + x / guess) >> 1;
    if (next >= guess) break;
    guess = next;
  }
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

inline bool SwiTraceEnabled() {
  static const bool enabled = (std::getenv("GBA_SWI_TRACE") != nullptr);
  return enabled;
}

inline void LogSwiTrace(const char* phase, uint32_t swi_num, uint32_t r0, uint32_t r1,
                        uint32_t r2, uint32_t r3, uint32_t pc) {
  if (!SwiTraceEnabled()) return;
  std::fprintf(stderr,
               "[SWI][%s] #%02X pc=%08X r0=%08X r1=%08X r2=%08X r3=%08X\n",
               phase, swi_num & 0xFFu, pc, r0, r1, r2, r3);
}

// =========================================================================
// 展開ヘルパー: LZ77 (バイトバッファへ)
// WRAM/VRAM 共用。バックリファレンスはバッファから読むため VRAM 未書込み問題なし。
// =========================================================================
struct DecompressResult {
  std::vector<uint8_t> data;
  uint32_t source_end = 0u;
};

inline DecompressResult DecompressLZ77Buffer(
    uint32_t src,
    std::function<uint8_t(uint32_t)> read8) {
  const uint32_t hdr = static_cast<uint32_t>(read8(src))
      | (static_cast<uint32_t>(read8(src + 1u)) << 8)
      | (static_cast<uint32_t>(read8(src + 2u)) << 16)
      | (static_cast<uint32_t>(read8(src + 3u)) << 24);
  const uint32_t decomp_len = hdr >> 8;
  if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) return {};
  std::vector<uint8_t> out(decomp_len, 0u);
  uint32_t s = src + 4u;
  uint32_t written = 0u;
  while (written < decomp_len) {
    const uint8_t flags = read8(s++);
    for (int b = 7; b >= 0 && written < decomp_len; --b) {
      if (!((flags >> b) & 1)) {
        out[written++] = read8(s++);
      } else {
        const uint8_t b0 = read8(s++);
        const uint8_t b1 = read8(s++);
        // GBATek: disp = (b0[3:0]<<8)|b1 + 1, count = b0[7:4] + 3
        const uint32_t disp  = (static_cast<uint32_t>(b0 & 0x0Fu) << 8) | static_cast<uint32_t>(b1);
        const uint32_t count = static_cast<uint32_t>((b0 >> 4) & 0x0Fu) + 3u;
        const uint32_t back  = disp + 1u;
        for (uint32_t i = 0u; i < count && written < decomp_len; ++i, ++written) {
          out[written] = (written >= back) ? out[written - back] : 0u;
        }
      }
    }
  }
  return {std::move(out), s};
}

inline void WriteBufferToVram16(
    uint32_t dst,
    const std::vector<uint8_t>& buf,
    const std::function<void(uint32_t, uint16_t)>& write16) {
  const uint32_t len = static_cast<uint32_t>(buf.size());
  for (uint32_t i = 0u; i + 1u < len; i += 2u) {
    write16(dst + i,
            static_cast<uint16_t>(buf[i]) |
            (static_cast<uint16_t>(buf[i + 1u]) << 8));
  }
}

struct WordMsbBitReader {
  uint32_t next_addr;
  uint32_t shifter;
  int bits_remaining;
  std::function<uint32_t(uint32_t)> read32;

  explicit WordMsbBitReader(uint32_t addr, std::function<uint32_t(uint32_t)> rd32)
      : next_addr(addr), shifter(0u), bits_remaining(0), read32(std::move(rd32)) {}

  inline bool ReadBit() {
    if (bits_remaining == 0) {
      shifter = read32(next_addr);
      next_addr += 4u;
      bits_remaining = 32;
    }
    const bool bit = (shifter & 0x80000000u) != 0u;
    shifter <<= 1;
    --bits_remaining;
    return bit;
  }
};

}  // namespace

// =========================================================================
// HandleSoftwareInterrupt
// =========================================================================
bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  const uint32_t swi_num = swi_imm & 0xFFu;
  const bool vector_boot = bios_loaded_ && bios_boot_via_vector_;
  // 実BIOSベクタモードは正確性優先で常に実BIOS SWIへ委譲する。
  if (vector_boot) {
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

    // =========================================================================
    // ----- SWI 10h: BitUnPack -----
    // FIXED: src_len はソースデータのバイト数。要素数 = (src_len*8)/sw。
    //        旧実装は src_len を要素数として扱っていたため大半のタイルが欠落していた。
    // =========================================================================
    case 0x10u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src_ptr  = cpu_.regs[0];
      const uint32_t dst_ptr  = cpu_.regs[1];
      const uint32_t info_ptr = cpu_.regs[2];

      // GBATek: info構造体
      //   +0  uint16  Source Length (バイト数)
      //   +2  uint8   Source Width  (ビット幅: 1/2/4/8)
      //   +3  uint8   Dest Width    (ビット幅: 1/2/4/8/16/32)
      //   +4  uint32  Data Offset   (bit31=ゼロ値にもオフセット加算, bit0-30=加算値)
      const uint16_t src_len_bytes = rd16(info_ptr);
      const uint8_t  sw            = rd8(info_ptr + 2u);
      const uint8_t  dw            = rd8(info_ptr + 3u);
      const uint32_t data_offset   = rd32(info_ptr + 4u);
      const bool     offset_zero   = (data_offset & 0x80000000u) != 0u;
      const uint32_t offset_val    = data_offset & 0x7FFFFFFFu;

      if (sw == 0u || dw == 0u || sw > 8u || dw > 32u) {
        cpu_.regs[15] = next_pc;
        return true;
      }

      const uint32_t src_mask = (sw < 32u) ? ((1u << sw) - 1u) : 0xFFFFFFFFu;
      const uint32_t dst_mask = (dw < 32u) ? ((1u << dw) - 1u) : 0xFFFFFFFFu;

      // 総要素数 = ソースビット総数 / ソース幅
      const uint32_t total_elements = (static_cast<uint32_t>(src_len_bytes) * 8u) / sw;

      uint32_t src_byte_addr  = src_ptr;
      uint32_t src_bits_buf   = 0u;
      int      src_bits_rem   = 0;

      uint32_t dst_word       = 0u;
      int      dst_bits_used  = 0;
      uint32_t dst_word_addr  = dst_ptr;

      for (uint32_t i = 0u; i < total_elements; ++i) {
        // 必要なビット数をバッファへ補充
        while (src_bits_rem < static_cast<int>(sw)) {
          src_bits_buf |= static_cast<uint32_t>(rd8(src_byte_addr++)) << src_bits_rem;
          src_bits_rem += 8;
        }

        // sw ビット取り出し
        uint32_t val  = src_bits_buf & src_mask;
        src_bits_buf >>= sw;
        src_bits_rem  -= static_cast<int>(sw);

        // オフセット加算 (ゼロ値フラグ考慮)
        if (val != 0u || offset_zero) val += offset_val;
        val &= dst_mask;

        // 出力ワードへパック
        dst_word     |= val << dst_bits_used;
        dst_bits_used += static_cast<int>(dw);

        // 32ビット揃ったら書き出し
        if (dst_bits_used >= 32) {
          wr32(dst_word_addr, dst_word);
          dst_word_addr += 4u;
          dst_word      = 0u;
          dst_bits_used = 0;
        }
      }
      // BIOS互換: 不完全な最終32bitワードは書き込まない。
      cpu_.regs[0] = src_byte_addr;
      cpu_.regs[1] = dst_word_addr;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);

      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 11h: LZ77UnCompWRAM -----
    // WRAM はバイト書き込み可能なのでインライン展開で問題なし。
    // =========================================================================
    case 0x11u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t hdr = rd32(src);
      const uint32_t decomp_len = hdr >> 8;
      if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      uint32_t s = src + 4u;
      uint32_t written = 0u;
      while (written < decomp_len) {
        const uint8_t flags = rd8(s++);
        for (int b = 7; b >= 0 && written < decomp_len; --b) {
          if (!((flags >> b) & 1)) {
            wr8(dst + written++, rd8(s++));
          } else {
            const uint8_t b0 = rd8(s++);
            const uint8_t b1 = rd8(s++);
            const uint32_t disp  = (static_cast<uint32_t>(b0 & 0x0Fu) << 8) | b1;
            const uint32_t count = static_cast<uint32_t>((b0 >> 4) & 0x0Fu) + 3u;
            const uint32_t back  = disp + 1u;
            for (uint32_t i = 0u; i < count && written < decomp_len; ++i, ++written) {
              wr8(dst + written, rd8(dst + written - back));
            }
          }
        }
      }
      cpu_.regs[0] = s;
      cpu_.regs[1] = dst + written;
      cpu_.regs[3] = 0u;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 12h: LZ77UnCompVRAM -----
    // FIXED: VRAM は 16bit 書き込み必須。
    //        バックリファレンスが未書込みバイトを参照するバグを修正。
    //        一旦バイトバッファへ展開後、16bit ペアで VRAM へ書き込む。
    // =========================================================================
    case 0x12u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const DecompressResult dec =
          DecompressLZ77Buffer(src, [&](uint32_t a) { return rd8(a); });
      WriteBufferToVram16(dst, dec.data, [&](uint32_t a, uint16_t v) { wr16(a, v); });
      cpu_.regs[0] = dec.source_end;
      cpu_.regs[1] = dst + static_cast<uint32_t>(dec.data.size());
      cpu_.regs[3] = 0u;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      // 奇数バイトは実機でも書かれない (GBATek準拠)
      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 13h: HuffUnComp -----
    // FIXED: 以下を修正
    //   1. ビットストリーム開始アドレスの 4バイトアライメント欠如
    //   2. シンボル数ベースのループ管理 (バイト数ベースは無限ループの可能性)
    //   3. ツリーサイズバイトの正確な解釈
    //
    // GBATek ツリーノード構造:
    //   Bit7   Node0 (左子) がデータリーフ
    //   Bit6   Node1 (右子) がデータリーフ
    //   Bit5-0 次の子ノードペアへのオフセット
    //   子ペアアドレス = (CurrentAddr & ~1) + Offset*2 + 2
    //
    // ビットストリームは MSB first で処理。
    // =========================================================================
    case 0x13u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      // r0 は 4バイトアライメントされていること (GBATek)
      const uint32_t src_base = cpu_.regs[0] & ~3u;
      const uint32_t dst_base = cpu_.regs[1];

      const uint32_t header    = rd32(src_base);
      const uint32_t sym_bits_raw  = header & 0xFu;        // 通常 4 または 8
      const uint32_t sym_bits = (sym_bits_raw == 0u) ? 8u : sym_bits_raw;
      const uint32_t decomp_len = header >> 8;

      if (sym_bits > 8u || decomp_len == 0u ||
          decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      if ((32u % sym_bits) != 0u || sym_bits == 1u) {
        cpu_.regs[15] = next_pc;
        return true;
      }

      // 参照実装準拠: treesize = (tree_size_byte << 1) + 1
      const uint8_t  tree_size_byte = rd8(src_base + 4u);
      const uint32_t tree_base      = src_base + 5u;
      const uint32_t tree_byte_size = (static_cast<uint32_t>(tree_size_byte) << 1) + 1u;
      const uint32_t bs_start = tree_base + tree_byte_size;

      const uint32_t sym_mask   = (sym_bits < 32u) ? ((1u << sym_bits) - 1u) : 0xFFFFFFFFu;
      WordMsbBitReader bit_reader(bs_start, [&](uint32_t a) { return rd32(a); });

      uint32_t node_ptr    = tree_base;   // カレントノードアドレス (ルートから開始)
      uint32_t out_block   = 0u;
      int      out_bits    = 0;
      uint32_t dst         = dst_base;
      uint32_t remaining   = decomp_len;

      while (remaining > 0u) {
        const bool go_right = bit_reader.ReadBit();

        // ノード読み取りと子アドレス計算
        const uint8_t  node_val   = rd8(node_ptr);
        const uint32_t child_pair = (node_ptr & ~1u)
            + (static_cast<uint32_t>(node_val & 0x3Fu) + 1u) * 2u;

        bool     is_leaf;
        uint32_t child_addr;
        if (go_right) {
          // Node1 (右子): Bit6 がリーフフラグ
          child_addr = child_pair + 1u;
          is_leaf    = (node_val & 0x40u) != 0u;
        } else {
          // Node0 (左子): Bit7 がリーフフラグ
          child_addr = child_pair;
          is_leaf    = (node_val & 0x80u) != 0u;
        }

        if (is_leaf) {
          // シンボル取得 → 出力ブロックへパック
          const uint32_t sym = static_cast<uint32_t>(rd8(child_addr)) & sym_mask;
          out_block |= sym << out_bits;
          out_bits  += static_cast<int>(sym_bits);

          // 32ビット揃ったら書き出し (GBA は常に 32bit 単位出力)
          if (out_bits == 32) {
            wr32(dst, out_block);
            dst      += 4u;
            out_block = 0u;
            out_bits  = 0;
            remaining = (remaining >= 4u) ? (remaining - 4u) : 0u;
          }

          // ルートへ戻る
          node_ptr = tree_base;
        } else {
          // 内部ノード: 子ノードへ進む
          node_ptr = child_addr;
        }
      }

      cpu_.regs[0] = bit_reader.next_addr;
      cpu_.regs[1] = dst;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);

      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 14h: RLUnCompWRAM -----
    // WRAM はバイト書き込み可能なのでインライン展開。
    // =========================================================================
    case 0x14u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t decomp_len = rd32(src) >> 8;
      if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      uint32_t s = src + 4u;
      uint32_t d = dst;
      uint32_t written = 0u;
      const uint32_t padding = (4u - (decomp_len & 3u)) & 3u;
      while (written < decomp_len) {
        const uint8_t flags = rd8(s++);
        if (flags & 0x80u) {
          const uint32_t count = static_cast<uint32_t>(flags & 0x7Fu) + 3u;
          const uint8_t  val   = rd8(s++);
          for (uint32_t i = 0u; i < count && written < decomp_len; ++i, ++written)
            wr8(d++, val);
        } else {
          const uint32_t count = static_cast<uint32_t>(flags & 0x7Fu) + 1u;
          for (uint32_t i = 0u; i < count && written < decomp_len; ++i, ++written)
            wr8(d++, rd8(s++));
        }
      }
      for (uint32_t i = 0; i < padding; ++i) wr8(d++, 0u);
      cpu_.regs[0] = s;
      cpu_.regs[1] = d;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 15h: RLUnCompVRAM -----
    // FIXED: VRAM は 16bit 書き込み必須。
    //        バイトバッファへ展開後、16bit ペアで VRAM へ書き込む。
    // =========================================================================
    case 0x15u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t decomp_len = rd32(src & ~3u) >> 8;
      if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      uint32_t s = src + 4u;
      uint32_t d = dst;
      uint32_t written = 0u;
      uint16_t half = 0u;
      uint32_t padding = (4u - (decomp_len & 3u)) & 3u;
      auto emit_byte = [&](uint8_t v) {
        if ((d & 1u) != 0u) {
          half = static_cast<uint16_t>(half | (static_cast<uint16_t>(v) << 8));
          wr16((d ^ 1u), half);
        } else {
          half = v;
        }
        ++d;
      };
      while (written < decomp_len) {
        const uint8_t flags = rd8(s++);
        if (flags & 0x80u) {
          uint32_t count = static_cast<uint32_t>(flags & 0x7Fu) + 3u;
          const uint8_t val = rd8(s++);
          while (count-- && written < decomp_len) {
            emit_byte(val);
            ++written;
          }
        } else {
          uint32_t count = static_cast<uint32_t>(flags & 0x7Fu) + 1u;
          while (count-- && written < decomp_len) {
            emit_byte(rd8(s++));
            ++written;
          }
        }
      }
      if (d & 1u) {
        if (padding > 0u) --padding;
        ++d;
      }
      for (; padding > 0u; padding -= 2u) {
        wr16(d, 0u);
        d += 2u;
      }
      cpu_.regs[0] = s;
      cpu_.regs[1] = d;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 16h: Diff8bitUnFilterWrite8bit (WRAM) -----
    // FIXED: GBATek 準拠の差分展開。
    //        prev[i] = prev[i-1] + encoded[i] (mod 256)
    //        8bit 書き込みなので WRAM/WRAM2 向け。
    // =========================================================================
    case 0x16u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src_addr  = cpu_.regs[0] & ~3u;
      const uint32_t dst_addr  = cpu_.regs[1];
      const uint32_t decomp_len = rd32(src_addr) >> 8;
      if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      uint32_t s    = src_addr + 4u;
      uint32_t d    = dst_addr;
      uint8_t  prev = 0u;
      for (uint32_t i = 0u; i < decomp_len; ++i) {
        prev = static_cast<uint8_t>(prev + rd8(s++));
        wr8(d++, prev);
      }
      cpu_.regs[0] = s;
      cpu_.regs[1] = d;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 17h: Diff8bitUnFilterWrite16bit (VRAM) -----
    // FIXED: 8bit 差分展開、16bit ペアで VRAM へ書き込む。
    //        VRAM は 16bit 書き込みのみ有効なため、2バイトずつペアにして書く。
    // =========================================================================
    case 0x17u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src_addr  = cpu_.regs[0] & ~3u;
      const uint32_t dst_addr  = cpu_.regs[1];
      const uint32_t decomp_len = rd32(src_addr) >> 8;
      if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      uint32_t s    = src_addr + 4u;
      uint32_t d    = dst_addr;
      uint8_t  prev = 0u;
      // 2バイトずつ処理して 16bit 書き込み
      for (uint32_t i = 0u; i + 1u <= decomp_len; i += 2u) {
        prev += rd8(s++);
        const uint8_t lo = prev;
        prev += rd8(s++);
        const uint8_t hi = prev;
        wr16(d, static_cast<uint16_t>(lo) | (static_cast<uint16_t>(hi) << 8));
        d += 2u;
      }
      cpu_.regs[0] = s;
      cpu_.regs[1] = d;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      // 奇数バイトは実機でも VRAM に書かれない
      cpu_.regs[15] = next_pc;
      return true;
    }

    // =========================================================================
    // ----- SWI 18h: Diff16bitUnFilter -----
    // FIXED: 16bit 差分展開。
    //        prev[i] = prev[i-1] + encoded[i] (mod 65536)
    // =========================================================================
    case 0x18u: {
      LogSwiTrace("begin", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      const uint32_t src_addr  = cpu_.regs[0] & ~3u;
      const uint32_t dst_addr  = cpu_.regs[1];
      const uint32_t decomp_len = rd32(src_addr) >> 8;
      if (decomp_len == 0u || decomp_len > 4u * 1024u * 1024u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      uint32_t  s    = src_addr + 4u;
      uint32_t  d    = dst_addr;
      uint16_t  prev = 0u;
      for (uint32_t i = 0u; i + 1u <= decomp_len; i += 2u) {
        prev = static_cast<uint16_t>(prev + rd16(s));
        s += 2u;
        wr16(d, prev);
        d += 2u;
      }
      cpu_.regs[0] = s;
      cpu_.regs[1] = d;
      LogSwiTrace("end", swi_num, cpu_.regs[0], cpu_.regs[1], cpu_.regs[2], cpu_.regs[3], cpu_.regs[15]);
      cpu_.regs[15] = next_pc;
      return true;
    }

    // ----- SWI 19h-1Fh: Sound/その他 (スタブ) -----
    case 0x19u: case 0x1Au: case 0x1Bu: case 0x1Cu:
    case 0x1Du: case 0x1Eu: case 0x1Fu:
      cpu_.regs[15] = next_pc;
      return true;

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
