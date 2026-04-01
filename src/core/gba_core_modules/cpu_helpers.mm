#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

uint32_t GBACore::RotateRight(uint32_t value, unsigned bits) const {
  if (bits == 0) return value;
  bits &= 31;
  return (value >> bits) | (value << (32 - bits));
}

uint32_t GBACore::ApplyShift(uint32_t value, uint32_t shift_type, uint32_t shift_amount, bool* carry_out) const {
  switch (shift_type) {
    case 0: // LSL
      if (shift_amount == 0) { *carry_out = GetFlagC(); return value; }
      if (shift_amount < 32) { *carry_out = (value >> (32 - shift_amount)) & 1; return value << shift_amount; }
      else if (shift_amount == 32) { *carry_out = value & 1; return 0; }
      else { *carry_out = 0; return 0; }
    case 1: // LSR
      if (shift_amount == 0) shift_amount = 32;
      if (shift_amount < 32) { *carry_out = (value >> (shift_amount - 1)) & 1; return value >> shift_amount; }
      else if (shift_amount == 32) { *carry_out = value >> 31; return 0; }
      else { *carry_out = 0; return 0; }
    case 2: // ASR
      if (shift_amount == 0) shift_amount = 32;
      if (shift_amount < 32) { *carry_out = (value >> (shift_amount - 1)) & 1; return static_cast<int32_t>(value) >> shift_amount; }
      else { *carry_out = value >> 31; return static_cast<int32_t>(value) >> 31; }
    case 3: // ROR
      if (shift_amount == 0) { uint32_t res = (value >> 1) | (GetFlagC() ? 0x80000000 : 0); *carry_out = value & 1; return res; }
      shift_amount &= 31;
      if (shift_amount == 0) { *carry_out = value >> 31; return value; }
      *carry_out = (value >> (shift_amount - 1)) & 1;
      return RotateRight(value, shift_amount);
    default: return value;
  }
}

bool GBACore::CheckCondition(uint32_t cond) const {
  bool n = (cpu_.cpsr >> 31) & 1; bool z = (cpu_.cpsr >> 30) & 1; bool c = (cpu_.cpsr >> 29) & 1; bool v = (cpu_.cpsr >> 28) & 1;
  switch (cond) {
    case 0x0: return z; case 0x1: return !z; case 0x2: return c; case 0x3: return !c; case 0x4: return n; case 0x5: return !n;
    case 0x6: return v; case 0x7: return !v; case 0x8: return c && !z; case 0x9: return !c || z; case 0xA: return n == v;
    case 0xB: return n != v; case 0xC: return !z && (n == v); case 0xD: return z || (n != v); case 0xE: return true;
    default: return true;
  }
}

void GBACore::SetNZFlags(uint32_t value) {
  cpu_.cpsr &= 0x3FFFFFFF; if (value == 0) cpu_.cpsr |= 0x40000000; if (value & 0x80000000) cpu_.cpsr |= 0x80000000;
}

void GBACore::SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  cpu_.cpsr &= 0x0FFFFFFF; uint32_t res = static_cast<uint32_t>(result64);
  if (res == 0) cpu_.cpsr |= 0x40000000; if (res & 0x80000000) cpu_.cpsr |= 0x80000000;
  if (result64 >> 32) cpu_.cpsr |= 0x20000000; if (~(lhs ^ rhs) & (lhs ^ res) & 0x80000000) cpu_.cpsr |= 0x10000000;
}

void GBACore::SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  cpu_.cpsr &= 0x0FFFFFFF; uint32_t res = static_cast<uint32_t>(result64);
  if (res == 0) cpu_.cpsr |= 0x40000000; if (res & 0x80000000) cpu_.cpsr |= 0x80000000;
  if (lhs >= rhs) cpu_.cpsr |= 0x20000000; if ((lhs ^ rhs) & (lhs ^ res) & 0x80000000) cpu_.cpsr |= 0x10000000;
}

uint32_t GBACore::ExpandArmImmediate(uint32_t imm12) const {
  uint32_t shift = (imm12 >> 8) * 2; uint32_t imm = imm12 & 0xFF; return RotateRight(imm, shift);
}

void GBACore::SwitchCpuMode(uint32_t new_mode) {
  uint32_t current_mode = GetCpuMode(); if (current_mode == new_mode) return;
  cpu_.banked_sp[NormalizeSpLrBankMode(current_mode)] = cpu_.regs[13];
  cpu_.banked_lr[NormalizeSpLrBankMode(current_mode)] = cpu_.regs[14];
  cpu_.regs[13] = cpu_.banked_sp[NormalizeSpLrBankMode(new_mode)];
  cpu_.regs[14] = cpu_.banked_lr[NormalizeSpLrBankMode(new_mode)];
  if (current_mode == 0x11) { for (int i = 0; i < 5; ++i) cpu_.banked_fiq_r8_r12[i] = cpu_.regs[i + 8]; }
  if (new_mode == 0x11) { for (int i = 0; i < 5; ++i) cpu_.regs[i + 8] = cpu_.banked_fiq_r8_r12[i]; }
  cpu_.cpsr = (cpu_.cpsr & ~0x1F) | (new_mode & 0x1F); cpu_.active_mode = new_mode;
}

uint32_t GBACore::NormalizeSpLrBankMode(uint32_t mode) {
    switch (mode) { case 0x11: return 1; case 0x12: return 2; case 0x13: return 3; case 0x17: return 4; case 0x1B: return 5; default: return 0; }
}

uint32_t GBACore::GetCpuMode() const { return cpu_.cpsr & 0x1F; }

uint32_t GBACore::RunCpuSlice(uint32_t cycles) {
  if (cpu_.halted) return cycles;
  uint32_t ran = 0;
  while (ran < cycles) {
    uint32_t pc = cpu_.regs[15]; uint32_t cost = 1;
    if (cpu_.cpsr & (1 << 5)) {
      uint16_t opcode = Read16(pc); ExecuteThumbInstruction(opcode);
      if (cpu_.regs[15] == pc) cpu_.regs[15] += 2; cost = EstimateThumbCycles(opcode);
    } else {
      uint32_t opcode = Read32(pc); ExecuteArmInstruction(opcode);
      if (cpu_.regs[15] == pc) cpu_.regs[15] += 4; cost = EstimateArmCycles(opcode);
    }
    ran += cost; if (cpu_.halted) break;
  }
  return ran;
}


bool GBACore::GetFlagC() const { return (cpu_.cpsr >> 29) & 1; }
void GBACore::SetFlagC(bool carry) { if (carry) cpu_.cpsr |= (1 << 29); else cpu_.cpsr &= ~(1 << 29); }

} // namespace gba
