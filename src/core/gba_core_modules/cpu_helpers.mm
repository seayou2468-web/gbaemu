#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

uint32_t GBACore::RotateRight(uint32_t value, unsigned bits) const {
  if (bits == 0) return value;
  bits %= 32;
  return (value >> bits) | (value << (32 - bits));
}

uint32_t GBACore::ApplyShift(uint32_t value, uint32_t shift_type, uint32_t shift_amount, bool* carry_out) const {
  switch (shift_type) {
    case 0: // LSL
      if (shift_amount == 0) {
        *carry_out = GetFlagC();
        return value;
      }
      if (shift_amount < 32) {
        *carry_out = (value >> (32 - shift_amount)) & 1;
        return value << shift_amount;
      } else if (shift_amount == 32) {
        *carry_out = value & 1;
        return 0;
      } else {
        *carry_out = 0;
        return 0;
      }
    case 1: // LSR
      if (shift_amount == 0) {
        // Special: LSR #0 means LSR #32
        shift_amount = 32;
      }
      if (shift_amount < 32) {
        *carry_out = (value >> (shift_amount - 1)) & 1;
        return value >> shift_amount;
      } else if (shift_amount == 32) {
        *carry_out = value >> 31;
        return 0;
      } else {
        *carry_out = 0;
        return 0;
      }
    case 2: // ASR
      if (shift_amount == 0) {
        // Special: ASR #0 means ASR #32
        shift_amount = 32;
      }
      if (shift_amount < 32) {
        *carry_out = (value >> (shift_amount - 1)) & 1;
        return static_cast<int32_t>(value) >> shift_amount;
      } else {
        *carry_out = value >> 31;
        return static_cast<int32_t>(value) >> 31;
      }
    case 3: // ROR
      if (shift_amount == 0) {
        // Special: ROR #0 means RRX
        uint32_t res = (value >> 1) | (GetFlagC() ? 0x80000000 : 0);
        *carry_out = value & 1;
        return res;
      }
      shift_amount %= 32;
      if (shift_amount == 0) {
        *carry_out = value >> 31;
        return value;
      }
      *carry_out = (value >> (shift_amount - 1)) & 1;
      return RotateRight(value, shift_amount);
    default:
      return value;
  }
}

bool GBACore::GetFlagC() const {
  return (cpu_.cpsr >> 29) & 1;
}

void GBACore::SetFlagC(bool carry) {
  if (carry) cpu_.cpsr |= 1 << 29;
  else cpu_.cpsr &= ~(1 << 29);
}

void GBACore::SetNZFlags(uint32_t value) {
  cpu_.cpsr &= ~(0xC0000000); // Clear N and Z
  if (value == 0) cpu_.cpsr |= 0x40000000;
  if (value & 0x80000000) cpu_.cpsr |= 0x80000000;
}

void GBACore::SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  cpu_.cpsr &= ~(0xF0000000); // Clear N, Z, C, V
  if (result64 == 0) cpu_.cpsr |= 0x40000000;
  if (result64 & 0x80000000) cpu_.cpsr |= 0x80000000;
  if (result64 >> 32) cpu_.cpsr |= 0x20000000;
  if (~(lhs ^ rhs) & (lhs ^ static_cast<uint32_t>(result64)) & 0x80000000) cpu_.cpsr |= 0x10000000;
}

void GBACore::SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  cpu_.cpsr &= ~(0xF0000000); // Clear N, Z, C, V
  if (static_cast<uint32_t>(result64) == 0) cpu_.cpsr |= 0x40000000;
  if (result64 & 0x80000000) cpu_.cpsr |= 0x80000000;
  if (lhs >= rhs) cpu_.cpsr |= 0x20000000;
  if ((lhs ^ rhs) & (lhs ^ static_cast<uint32_t>(result64)) & 0x80000000) cpu_.cpsr |= 0x10000000;
}

bool GBACore::CheckCondition(uint32_t cond) const {
  bool n = (cpu_.cpsr >> 31) & 1;
  bool z = (cpu_.cpsr >> 30) & 1;
  bool c = (cpu_.cpsr >> 29) & 1;
  bool v = (cpu_.cpsr >> 28) & 1;

  switch (cond) {
    case 0x0: return z; // EQ
    case 0x1: return !z; // NE
    case 0x2: return c; // CS/HS
    case 0x3: return !c; // CC/LO
    case 0x4: return n; // MI
    case 0x5: return !n; // PL
    case 0x6: return v; // VS
    case 0x7: return !v; // VC
    case 0x8: return c && !z; // HI
    case 0x9: return !c || z; // LS
    case 0x10: return n == v; // GE
    case 0xB: return n != v; // LT
    case 0xC: return !z && (n == v); // GT
    case 0xD: return z || (n != v); // LE
    case 0xE: return true; // AL
    default: return true;
  }
}

uint32_t GBACore::ExpandArmImmediate(uint32_t imm12) const {
  uint32_t shift = (imm12 >> 8) * 2;
  uint32_t imm = imm12 & 0xFF;
  return RotateRight(imm, shift);
}

uint32_t GBACore::GetCpuMode() const {
  return cpu_.cpsr & 0x1F;
}

bool GBACore::IsPrivilegedMode(uint32_t mode) const {
  return mode != 0x10; // 0x10 is User mode
}

bool GBACore::HasSpsr(uint32_t mode) const {
  // FIQ, IRQ, SVC, ABT, UND have SPSR
  return mode == 0x11 || mode == 0x12 || mode == 0x13 || mode == 0x17 || mode == 0x1B;
}

void GBACore::SwitchCpuMode(uint32_t new_mode) {
  // Logic to swap banked registers (SP, LR, R8-R12)
  // This is a complex logic that involves checking the current and new mode
  uint32_t current_mode = GetCpuMode();
  if (current_mode == new_mode) return;

  // Simplified: Handle basic SP/LR banking
  // Store current SP/LR to banked array
  cpu_.banked_sp[current_mode] = cpu_.regs[13];
  cpu_.banked_lr[current_mode] = cpu_.regs[14];

  // Restore new SP/LR from banked array
  cpu_.regs[13] = cpu_.banked_sp[new_mode];
  cpu_.regs[14] = cpu_.banked_lr[new_mode];

  // FIQ mode has more banked registers (R8-R12)
  if (current_mode == 0x11) {
    for (int i = 8; i <= 12; ++i) cpu_.banked_fiq_r8_r12[i - 8] = cpu_.regs[i];
  }
  if (new_mode == 0x11) {
    for (int i = 8; i <= 12; ++i) cpu_.regs[i] = cpu_.banked_fiq_r8_r12[i - 8];
  }

  cpu_.cpsr = (cpu_.cpsr & ~0x1F) | (new_mode & 0x1F);
  cpu_.active_mode = new_mode;
}

uint32_t GBACore::RunCpuSlice(uint32_t cycles) {
  if (cpu_.halted) return cycles;

  uint32_t ran = 0;
  while (ran < cycles) {
    uint32_t pc = cpu_.regs[15];
    uint32_t cost = 1;
    if (cpu_.cpsr & (1 << 5)) { // Thumb state
      uint16_t opcode = Read16(pc);
      ExecuteThumbInstruction(opcode);
      cpu_.regs[15] += 2;
      cost = EstimateThumbCycles(opcode);
    } else {
      uint32_t opcode = Read32(pc);
      ExecuteArmInstruction(opcode);
      cpu_.regs[15] += 4;
      cost = EstimateArmCycles(opcode);
    }
    ran += cost;
    if (cpu_.halted) break;
  }
  return ran;
}

} // namespace gba
