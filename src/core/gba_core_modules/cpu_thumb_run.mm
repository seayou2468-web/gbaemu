void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  // Shift by immediate (LSL/LSR/ASR)
  // Thumb format 1 is 000xx (xx=00/01/10). Exclude 00011 (ADD/SUB format 2).
  if ((opcode & 0xE000u) == 0x0000u && (opcode & 0x1800u) != 0x1800u) {
    const uint16_t shift_type = (opcode >> 11) & 0x3u;
    const uint16_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint16_t rs = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    bool carry = GetFlagC();
    const uint32_t result = ApplyShift(cpu_.regs[rs], shift_type, imm5, &carry);
    cpu_.regs[rd] = result;
    SetNZFlags(result);
    SetFlagC(carry);
    cpu_.regs[15] += 2;
    return;
  }

  // Add/sub register or immediate3
  if ((opcode & 0xF800u) == 0x1800u) {
    const bool immediate = (opcode & (1u << 10)) != 0;
    const bool sub = (opcode & (1u << 9)) != 0;
    const uint16_t rn_or_imm3 = (opcode >> 6) & 0x7u;
    const uint16_t rs = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t rhs = immediate ? rn_or_imm3 : cpu_.regs[rn_or_imm3];
    uint64_t r64 = 0;
    if (sub) {
      r64 = static_cast<uint64_t>(cpu_.regs[rs]) - static_cast<uint64_t>(rhs);
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetSubFlags(cpu_.regs[rs], rhs, r64);
    } else {
      r64 = static_cast<uint64_t>(cpu_.regs[rs]) + static_cast<uint64_t>(rhs);
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetAddFlags(cpu_.regs[rs], rhs, r64);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // MOV/CMP/ADD/SUB immediate (001xx)
  if ((opcode & 0xE000u) == 0x2000u) {
    const uint16_t op = (opcode >> 11) & 0x3u;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm8 = opcode & 0xFFu;
    switch (op) {
      case 0:  // MOV
        cpu_.regs[rd] = imm8;
        SetNZFlags(cpu_.regs[rd]);
        break;
      case 1: {  // CMP
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - static_cast<uint64_t>(imm8);
        SetSubFlags(cpu_.regs[rd], imm8, r64);
        break;
      }
      case 2: {  // ADD
        const uint32_t lhs = cpu_.regs[rd];
        const uint64_t r64 = static_cast<uint64_t>(lhs) + static_cast<uint64_t>(imm8);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetAddFlags(lhs, imm8, r64);
        break;
      }
      case 3: {  // SUB
        const uint32_t lhs = cpu_.regs[rd];
        const uint64_t r64 = static_cast<uint64_t>(lhs) - static_cast<uint64_t>(imm8);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetSubFlags(lhs, imm8, r64);
        break;
      }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // ALU operations
  if ((opcode & 0xFC00u) == 0x4000u) {
    const uint16_t alu_op = (opcode >> 6) & 0xFu;
    const uint16_t rs = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    switch (alu_op) {
      case 0x0: { cpu_.regs[rd] &= cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // AND
      case 0x1: { cpu_.regs[rd] ^= cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // EOR
      case 0x2: {  // LSL reg
        bool c = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 0, cpu_.regs[rs] & 0xFFu, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x3: {  // LSR reg
        bool c = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 1, cpu_.regs[rs] & 0xFFu, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x4: {  // ASR reg
        bool c = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 2, cpu_.regs[rs] & 0xFFu, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x5: {  // ADC
        const uint32_t lhs = cpu_.regs[rd];
        const uint32_t rhs = cpu_.regs[rs];
        const uint32_t carry = GetFlagC() ? 1u : 0u;
        const uint64_t r64 = static_cast<uint64_t>(lhs) + static_cast<uint64_t>(rhs) + carry;
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetAddFlags(lhs, rhs + carry, r64);
        break;
      }
      case 0x6: {  // SBC
        const uint32_t lhs = cpu_.regs[rd];
        const uint32_t rhs = cpu_.regs[rs];
        const uint32_t borrow = GetFlagC() ? 0u : 1u;
        const uint64_t r64 = static_cast<uint64_t>(lhs) - static_cast<uint64_t>(rhs) - borrow;
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetSubFlags(lhs, rhs + borrow, r64);
        break;
      }
      case 0x7: {  // ROR
        bool c = GetFlagC();
        const uint32_t amount = cpu_.regs[rs] & 0xFFu;
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 3, amount, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x8: {  // TST
        SetNZFlags(cpu_.regs[rd] & cpu_.regs[rs]);
        break;
      }
      case 0x9: {  // NEG
        const uint32_t rhs = cpu_.regs[rs];
        const uint64_t r64 = static_cast<uint64_t>(0) - static_cast<uint64_t>(rhs);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetSubFlags(0u, rhs, r64);
        break;
      }
      case 0xA: {  // CMP
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - static_cast<uint64_t>(cpu_.regs[rs]);
        SetSubFlags(cpu_.regs[rd], cpu_.regs[rs], r64);
        break;
      }
      case 0xB: {  // CMN
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) + static_cast<uint64_t>(cpu_.regs[rs]);
        SetAddFlags(cpu_.regs[rd], cpu_.regs[rs], r64);
        break;
      }
      case 0xC: { cpu_.regs[rd] |= cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // ORR
      case 0xD: {  // MUL
        cpu_.regs[rd] *= cpu_.regs[rs];
        SetNZFlags(cpu_.regs[rd]);
        break;
      }
      case 0xE: { cpu_.regs[rd] &= ~cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // BIC
      case 0xF: { cpu_.regs[rd] = ~cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }            // MVN
      default:
        break;
    }
    cpu_.regs[15] += 2;
    return;
  }

  // High register operations / BX
  if ((opcode & 0xFC00u) == 0x4400u) {
    const uint16_t op = (opcode >> 8) & 0x3u;
    const uint16_t h1 = (opcode >> 7) & 0x1u;
    const uint16_t h2 = (opcode >> 6) & 0x1u;
    const uint16_t rs = ((h2 << 3) | ((opcode >> 3) & 0x7u)) & 0xFu;
    const uint16_t rd = ((h1 << 3) | (opcode & 0x7u)) & 0xFu;
    if (op == 3) {  // BX
      const uint32_t target = cpu_.regs[rs];
      if (target & 1u) {
        cpu_.cpsr |= (1u << 5);
        cpu_.regs[15] = target & ~1u;
      } else {
        cpu_.cpsr &= ~(1u << 5);
        cpu_.regs[15] = target & ~3u;
      }
      return;
    }
    if (op == 0) {  // ADD
      cpu_.regs[rd] += cpu_.regs[rs];
      if (rd == 15) {
        cpu_.regs[15] &= ~1u;
        return;
      }
    } else if (op == 1) {  // CMP
      const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - static_cast<uint64_t>(cpu_.regs[rs]);
      SetSubFlags(cpu_.regs[rd], cpu_.regs[rs], r64);
    } else if (op == 2) {  // MOV
      cpu_.regs[rd] = cpu_.regs[rs];
      if (rd == 15) {
        cpu_.regs[15] &= ~1u;
        return;
      }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // PC-relative load
  if ((opcode & 0xF800u) == 0x4800u) {
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2u;
    const uint32_t base = (cpu_.regs[15] + 4u) & ~3u;
    cpu_.regs[rd] = Read32(base + imm);
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store with register offset
  if ((opcode & 0xF200u) == 0x5000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const bool byte = (opcode & (1u << 10)) != 0;
    const uint16_t ro = (opcode >> 6) & 0x7u;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + cpu_.regs[ro];
    if (load) {
      if (byte) {
        cpu_.regs[rd] = Read8(addr);
      } else {
        const uint32_t aligned = addr & ~3u;
        const uint32_t raw = Read32(aligned);
        const uint32_t rot = (addr & 3u) * 8u;
        cpu_.regs[rd] = (rot == 0) ? raw : RotateRight(raw, rot);
      }
    } else if (byte) {
      Write8(addr, static_cast<uint8_t>(cpu_.regs[rd] & 0xFFu));
    } else {
      Write32(addr & ~3u, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store sign-extended byte/halfword
  if ((opcode & 0xF200u) == 0x5200u) {
    const uint16_t op = (opcode >> 10) & 0x3u;
    const uint16_t ro = (opcode >> 6) & 0x7u;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + cpu_.regs[ro];
    switch (op) {
      case 0x0: Write16(addr & ~1u, static_cast<uint16_t>(cpu_.regs[rd])); break;  // STRH
      case 0x1: cpu_.regs[rd] = Read16(addr & ~1u); break;                          // LDRH
      case 0x2: cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int8_t>(Read8(addr))); break;  // LDSB
      case 0x3:
        if (addr & 1u) {
          cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int8_t>(Read8(addr)));
        } else {
          cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int16_t>(Read16(addr)));
        }
        break; // LDSH
    }
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store immediate offset
  if ((opcode & 0xE000u) == 0x6000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const bool byte = (opcode & (1u << 12)) != 0;
    const uint16_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t offset = byte ? imm5 : (imm5 << 2u);
    const uint32_t addr = cpu_.regs[rb] + offset;
    if (load) {
      if (byte) {
        cpu_.regs[rd] = Read8(addr);
      } else {
        const uint32_t aligned = addr & ~3u;
        const uint32_t raw = Read32(aligned);
        const uint32_t rot = (addr & 3u) * 8u;
        cpu_.regs[rd] = (rot == 0) ? raw : RotateRight(raw, rot);
      }
    } else if (byte) {
      Write8(addr, static_cast<uint8_t>(cpu_.regs[rd]));
    } else {
      Write32(addr & ~3u, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store halfword immediate
  if ((opcode & 0xF000u) == 0x8000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const uint16_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + (imm5 << 1u);
    if (load) {
      cpu_.regs[rd] = Read16(addr & ~1u);
    } else {
      Write16(addr & ~1u, static_cast<uint16_t>(cpu_.regs[rd] & 0xFFFFu));
    }
    cpu_.regs[15] += 2;
    return;
  }

  // SP-relative load/store
  if ((opcode & 0xF000u) == 0x9000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2u;
    const uint32_t addr = cpu_.regs[13] + imm;
    if (load) {
      cpu_.regs[rd] = Read32(addr & ~3u);
    } else {
      Write32(addr & ~3u, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // ADD to PC/SP
  if ((opcode & 0xF000u) == 0xA000u) {
    const bool use_sp = (opcode & (1u << 11)) != 0;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2u;
    const uint32_t base = use_sp ? cpu_.regs[13] : ((cpu_.regs[15] + 4u) & ~3u);
    cpu_.regs[rd] = base + imm;
    cpu_.regs[15] += 2;
    return;
  }

  // ADD/SUB SP immediate
  if ((opcode & 0xFF00u) == 0xB000u) {
    const bool sub = (opcode & (1u << 7)) != 0;
    const uint32_t imm = (opcode & 0x7Fu) << 2u;
    cpu_.regs[13] = sub ? (cpu_.regs[13] - imm) : (cpu_.regs[13] + imm);
    cpu_.regs[15] += 2;
    return;
  }

  // PUSH/POP
  if ((opcode & 0xF600u) == 0xB400u) {
    const bool load = (opcode & (1u << 11)) != 0;  // POP when set
    const bool r = (opcode & (1u << 8)) != 0;      // LR/PC bit
    const uint16_t reg_list = opcode & 0xFFu;
    if (!load) {  // PUSH
      if (r) {
        cpu_.regs[13] -= 4u;
        Write32(cpu_.regs[13], cpu_.regs[14]);
      }
      for (int i = 7; i >= 0; --i) {
        if (reg_list & (1u << i)) {
          cpu_.regs[13] -= 4u;
          Write32(cpu_.regs[13], cpu_.regs[i]);
        }
      }
    } else {      // POP
      for (int i = 0; i < 8; ++i) {
        if (reg_list & (1u << i)) {
          cpu_.regs[i] = Read32(cpu_.regs[13]);
          cpu_.regs[13] += 4u;
        }
      }
      if (r) {
        const uint32_t target = Read32(cpu_.regs[13]);
        if (target & 1u) {
          cpu_.cpsr |= (1u << 5);   // stay/enter Thumb
          cpu_.regs[15] = target & ~1u;
        } else {
          cpu_.cpsr &= ~(1u << 5);  // switch to ARM
          cpu_.regs[15] = target & ~3u;
        }
        cpu_.regs[13] += 4u;
        return;
      }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // LDMIA/STMIA
  if ((opcode & 0xF000u) == 0xC000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const uint16_t rb = (opcode >> 8) & 0x7u;
    const uint16_t reg_list = opcode & 0xFFu;
    uint32_t addr = cpu_.regs[rb];
    for (int i = 0; i < 8; ++i) {
      if ((reg_list & (1u << i)) == 0) continue;
      if (load) {
        cpu_.regs[i] = Read32(addr);
      } else {
        Write32(addr, cpu_.regs[i]);
      }
      addr += 4u;
    }
    cpu_.regs[rb] = addr;
    cpu_.regs[15] += 2;
    return;
  }

  // Thumb SWI
  if ((opcode & 0xFF00u) == 0xDF00u) {
    if (HandleSoftwareInterrupt(opcode & 0x00FFu, true)) return;
    EnterException(0x00000008u, 0x13u, true, false);  // SVC mode
    return;
  }

  // Conditional branch
  if ((opcode & 0xF000u) == 0xD000u && (opcode & 0x0F00u) != 0x0F00u) {
    const uint32_t cond = (opcode >> 8) & 0xFu;
    int32_t offset = static_cast<int32_t>(opcode & 0xFFu);
    if (offset & 0x80) offset |= ~0xFF;
    offset <<= 1;
    if (CheckCondition(cond)) {
      cpu_.regs[15] = cpu_.regs[15] + 4u + static_cast<uint32_t>(offset);
    } else {
      cpu_.regs[15] += 2;
    }
    return;
  }

  // Long branch with link (Thumb BL pair, minimal handling)
  if ((opcode & 0xF800u) == 0xF000u || (opcode & 0xF800u) == 0xF800u) {
    const bool second = (opcode & 0x0800u) != 0;
    const int32_t off11 = static_cast<int32_t>(opcode & 0x07FFu);
    if (!second) {
      int32_t hi = off11;
      if (hi & 0x400) hi |= ~0x7FF;
      cpu_.regs[14] = cpu_.regs[15] + 4u + static_cast<uint32_t>(hi << 12);
      cpu_.regs[15] += 2;
    } else {
      const uint32_t target = cpu_.regs[14] + static_cast<uint32_t>(off11 << 1);
      cpu_.regs[14] = (cpu_.regs[15] + 2u) | 1u;
      cpu_.regs[15] = target & ~1u;
    }
    return;
  }

  // Unconditional branch (11100)
  if ((opcode & 0xF800u) == 0xE000u) {
    int32_t offset = static_cast<int32_t>(opcode & 0x07FFu);
    if (offset & 0x400) offset |= ~0x7FF;
    offset <<= 1;
    cpu_.regs[15] = cpu_.regs[15] + 4u + static_cast<uint32_t>(offset);
    return;
  }

  // Canonical Thumb NOP (MOV r8, r8)
  if (opcode == 0x46C0u) {
    cpu_.regs[15] += 2;
    return;
  }

  EnterException(0x00000004u, 0x1Bu, true, false);  // Undefined instruction
}

void GBACore::RunCpuSlice(uint32_t cycles) {
  if (cpu_.halted) {
    bool woke_from_intrwait = false;
    if (swi_intrwait_active_) {
      const uint16_t iflags = ReadIO16(0x04000202u);
      const uint16_t matched = static_cast<uint16_t>(iflags & swi_intrwait_mask_);
      if (matched != 0u) {
        WriteIO16(0x04000202u, matched);
        swi_intrwait_active_ = false;
        swi_intrwait_mask_ = 0;
        cpu_.halted = false;
        woke_from_intrwait = true;
      }
    }
    if (!woke_from_intrwait) {
      const uint16_t ie = ReadIO16(0x04000200u);
      const uint16_t iflags = ReadIO16(0x04000202u);
      if ((ie & iflags) == 0) return;
      cpu_.halted = false;
    }
  }
  auto is_exec_addr_valid = [&](uint32_t addr) -> bool {
    if (bios_loaded_ && addr < 0x00004000u) return true;  // BIOS
    if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) return true;  // EWRAM mirror
    if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) return true;  // IWRAM mirror
    if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) return true;  // ROM mirrors
    return false;
  };
  uint32_t consumed = 0;
  while (consumed < cycles) {
    ServiceInterruptIfNeeded();
    const uint32_t pc = cpu_.regs[15];
    if (cpu_.cpsr & (1u << 5)) {
      const uint16_t opcode = Read16(pc);
      consumed += EstimateThumbCycles(opcode);
      ExecuteThumbInstruction(opcode);
    } else {
      const uint32_t opcode = Read32(pc);
      consumed += EstimateArmCycles(opcode);
      ExecuteArmInstruction(opcode);
    }
    // Keep PC sane when branch jumps outside executable mapped ranges.
    // Do not remap valid BIOS/IWRAM/EWRAM/ROM addresses.
    if (!is_exec_addr_valid(cpu_.regs[15])) {
      const uint32_t mask = (cpu_.cpsr & (1u << 5)) ? 0x1FFFFFEu : 0x1FFFFFCu;
      cpu_.regs[15] = 0x08000000u + static_cast<uint32_t>((cpu_.regs[15] & mask) % std::max<size_t>(4, rom_.size()));
    }
  }
}

void GBACore::DebugStepCpuInstructions(uint32_t count) {
  for (uint32_t i = 0; i < count; ++i) {
    if (cpu_.halted) {
      bool woke_from_intrwait = false;
      if (swi_intrwait_active_) {
        const uint16_t iflags = ReadIO16(0x04000202u);
        const uint16_t matched = static_cast<uint16_t>(iflags & swi_intrwait_mask_);
        if (matched != 0u) {
          WriteIO16(0x04000202u, matched);
          swi_intrwait_active_ = false;
          swi_intrwait_mask_ = 0;
          cpu_.halted = false;
          woke_from_intrwait = true;
        }
      }
      if (!woke_from_intrwait) {
        const uint16_t ie = ReadIO16(0x04000200u);
        const uint16_t iflags = ReadIO16(0x04000202u);
        if ((ie & iflags) == 0) return;
        cpu_.halted = false;
      }
    }
    ServiceInterruptIfNeeded();
    if (cpu_.cpsr & (1u << 5)) {
      const uint16_t opcode = Read16(cpu_.regs[15]);
      ExecuteThumbInstruction(opcode);
    } else {
      const uint32_t opcode = Read32(cpu_.regs[15]);
      ExecuteArmInstruction(opcode);
    }
  }
}

}  // namespace gba

// ---- END gba_core_cpu.cpp ----
