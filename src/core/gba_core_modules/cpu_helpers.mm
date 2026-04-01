#include "../gba_core.h"

namespace gba {

namespace {
inline bool IsUserLikeMode(uint32_t mode) {
  mode &= 0x1Fu;
  return mode == 0x10u || mode == 0x1Fu;
}
}

bool GBACore::GetFlagC() const { return (cpu_.cpsr & (1u << 29)) != 0; }
void GBACore::SetFlagC(bool carry) { cpu_.cpsr = carry ? (cpu_.cpsr | (1u << 29)) : (cpu_.cpsr & ~(1u << 29)); }

void GBACore::SetNZFlags(uint32_t v) {
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 31) | (1u << 30))) | (v & 0x80000000u) | ((v == 0) ? (1u << 30) : 0);
}

void GBACore::SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t r64) {
  SetNZFlags(static_cast<uint32_t>(r64));
  SetFlagC((r64 >> 32) != 0);
  const bool ov = (~(lhs ^ rhs) & (lhs ^ static_cast<uint32_t>(r64)) & 0x80000000u) != 0;
  cpu_.cpsr = ov ? (cpu_.cpsr | (1u << 28)) : (cpu_.cpsr & ~(1u << 28));
}

void GBACore::SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t r64) {
  SetNZFlags(static_cast<uint32_t>(r64));
  SetFlagC(lhs >= rhs);
  const bool ov = ((lhs ^ rhs) & (lhs ^ static_cast<uint32_t>(r64)) & 0x80000000u) != 0;
  cpu_.cpsr = ov ? (cpu_.cpsr | (1u << 28)) : (cpu_.cpsr & ~(1u << 28));
}

uint32_t GBACore::GetCpuMode() const { return cpu_.cpsr & 0x1Fu; }
bool GBACore::IsPrivilegedMode(uint32_t mode) const { return (mode & 0x1Fu) != 0x10; }
bool GBACore::HasSpsr(uint32_t mode) const { mode &= 0x1Fu; return mode == 0x11 || mode == 0x12 || mode == 0x13 || mode == 0x17 || mode == 0x1B; }

void GBACore::SwitchCpuMode(uint32_t new_mode) {
  new_mode = NormalizeSpLrBankMode(new_mode);
  const uint32_t old_mode = NormalizeSpLrBankMode(cpu_.active_mode);

  // R8-R12 have separate FIQ bank. All non-FIQ modes share the same bank.
  if (old_mode == 0x11u) {
    for (size_t i = 0; i < 5; ++i) cpu_.banked_fiq_r8_r12[i] = cpu_.regs[8 + i];
  } else {
    for (size_t i = 0; i < 5; ++i) cpu_.banked_usr_r8_r12[i] = cpu_.regs[8 + i];
  }
  if (!IsUserLikeMode(old_mode)) {
    cpu_.banked_sp[old_mode] = cpu_.regs[13];
    cpu_.banked_lr[old_mode] = cpu_.regs[14];
  }

  if (new_mode == 0x11u) {
    for (size_t i = 0; i < 5; ++i) cpu_.regs[8 + i] = cpu_.banked_fiq_r8_r12[i];
  } else {
    for (size_t i = 0; i < 5; ++i) cpu_.regs[8 + i] = cpu_.banked_usr_r8_r12[i];
  }

  if (!IsUserLikeMode(new_mode)) {
    cpu_.regs[13] = cpu_.banked_sp[new_mode];
    cpu_.regs[14] = cpu_.banked_lr[new_mode];
  }

  cpu_.active_mode = new_mode;
  cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | new_mode;
}

uint32_t GBACore::RotateRight(uint32_t value, unsigned bits) const {
  bits &= 31u;
  return (value >> bits) | (value << ((32u - bits) & 31u));
}

uint32_t GBACore::ApplyShift(uint32_t value, uint32_t type, uint32_t amount, bool* carry_out) const {
  switch (type & 3u) {
    case 0:  // LSL
      if (amount == 0) {
        if (carry_out) *carry_out = GetFlagC();
        return value;
      }
      if (amount < 32) {
        if (carry_out) *carry_out = ((value >> (32 - amount)) & 1u) != 0;
        return value << amount;
      }
      if (carry_out) *carry_out = amount == 32 ? (value & 1u) : false;
      return 0;
    case 1:  // LSR
      if (amount == 0 || amount >= 32) {
        if (carry_out) *carry_out = (amount == 0) ? ((value >> 31) & 1u) : ((amount == 32) ? ((value >> 31) & 1u) : 0);
        return 0;
      }
      if (carry_out) *carry_out = ((value >> (amount - 1)) & 1u) != 0;
      return value >> amount;
    case 2:  // ASR
      if (amount == 0 || amount >= 32) {
        const bool sign = (value >> 31) != 0;
        if (carry_out) *carry_out = sign;
        return sign ? 0xFFFFFFFFu : 0u;
      }
      if (carry_out) *carry_out = ((value >> (amount - 1)) & 1u) != 0;
      return static_cast<uint32_t>(static_cast<int32_t>(value) >> amount);
    default:  // ROR/RRX
      if (amount == 0) {
        const bool old_c = GetFlagC();
        if (carry_out) *carry_out = (value & 1u) != 0;
        return (old_c ? 0x80000000u : 0u) | (value >> 1);
      }
      amount &= 31u;
      if (carry_out) *carry_out = ((value >> ((amount - 1) & 31u)) & 1u) != 0;
      return RotateRight(value, amount);
  }
}

uint32_t GBACore::ExpandArmImmediate(uint32_t imm12) const {
  const uint32_t imm8 = imm12 & 0xFFu;
  const uint32_t rot = ((imm12 >> 8) & 0xFu) * 2u;
  return RotateRight(imm8, rot);
}

bool GBACore::CheckCondition(uint32_t cond) const {
  const bool n = (cpu_.cpsr >> 31) & 1u;
  const bool z = (cpu_.cpsr >> 30) & 1u;
  const bool c = (cpu_.cpsr >> 29) & 1u;
  const bool v = (cpu_.cpsr >> 28) & 1u;
  switch (cond & 0xFu) {
    case 0x0: return z; case 0x1: return !z; case 0x2: return c; case 0x3: return !c;
    case 0x4: return n; case 0x5: return !n; case 0x6: return v; case 0x7: return !v;
    case 0x8: return c && !z; case 0x9: return !c || z; case 0xA: return n == v; case 0xB: return n != v;
    case 0xC: return !z && (n == v); case 0xD: return z || (n != v); case 0xE: return true; default: return false;
  }
}

}  // namespace gba
