// cpu_arm_execute.mm
//
// GBA ARM7TDMI CPU – ARM命令実行エンジン (完全実装版)
//
// ARM7TDMI パイプラインモデル:
//   cpu_.regs[15] = 現在実行中命令のアドレス (execute_addr)
//   命令がオペランドとして r15 を読む場合: execute_addr + 8 を返す (ARM)
//   命令がレジスタシフトで r15 を読む場合: execute_addr + 12 を返す
//   分岐後: cpu_.regs[15] = 分岐先アドレス (FlushPipeline で追加サイクル)
//   通常終了: cpu_.regs[15] += 4
//
// 参考: arm.c / isa-arm.c (C実装からの完全移植)

#include "../gba_core.h"

namespace gba {

namespace {

// ─── ヘルパー ────────────────────────────────────────────────────────────────

__attribute__((always_inline)) static inline uint32_t ArmReg(uint32_t op, uint32_t shift) {
    return (op >> shift) & 0xFu;
}

// r15 を execute_addr + 8 として返す (即値シフト用)
__attribute__((always_inline)) static inline uint32_t ArmReadReg(const std::array<uint32_t, 16>& r, uint32_t idx) {
    return (idx == 15u) ? (r[15] + 8u) : r[idx];
}

// r15 を execute_addr + 12 として返す (レジスタシフト用: extra Iサイクル分 +4)
__attribute__((always_inline)) static inline uint32_t ArmReadRegRS(const std::array<uint32_t, 16>& r, uint32_t idx) {
    return (idx == 15u) ? (r[15] + 12u) : r[idx];
}

// レジスタシフト量でシフト (Rsの低8ビットを使用)
__attribute__((always_inline)) static inline uint32_t ArmRegShift(uint32_t value, uint32_t type,
                                   uint32_t amount, bool carry_in,
                                   bool* carry_out) {
    const uint32_t amt = amount & 0xFFu;
    if (amt == 0u) {
        if (carry_out) *carry_out = carry_in;
        return value;
    }
    switch (type & 3u) {
        case 0u: // LSL
            if (amt < 32u) {
                if (carry_out) *carry_out = ((value >> (32u - amt)) & 1u) != 0u;
                return value << amt;
            }
            if (carry_out) *carry_out = (amt == 32u) ? ((value & 1u) != 0u) : false;
            return 0u;
        case 1u: // LSR
            if (amt < 32u) {
                if (carry_out) *carry_out = ((value >> (amt - 1u)) & 1u) != 0u;
                return value >> amt;
            }
            if (carry_out) *carry_out = (amt == 32u) ? ((value >> 31u) & 1u) != 0u : false;
            return 0u;
        case 2u: // ASR
            if (amt < 32u) {
                if (carry_out) *carry_out = ((value >> (amt - 1u)) & 1u) != 0u;
                return static_cast<uint32_t>(static_cast<int32_t>(value) >> amt);
            }
            if (carry_out) *carry_out = ((value >> 31u) & 1u) != 0u;
            return (value & 0x80000000u) ? 0xFFFFFFFFu : 0u;
        default: { // ROR
            const uint32_t rot = amt & 31u;
            if (rot == 0u) {
                if (carry_out) *carry_out = ((value >> 31u) & 1u) != 0u;
                return value;
            }
            if (carry_out) *carry_out = ((value >> (rot - 1u)) & 1u) != 0u;
            return (value >> rot) | (value << (32u - rot));
        }
    }
}

// MSR フィールドマスク (ARMv4T: c=bit16, f=bit19 のみ有効)
__attribute__((always_inline)) static inline uint32_t ArmMsrMask(uint32_t opcode) {
    uint32_t mask = 0u;
    if (opcode & (1u << 16u)) mask |= 0x000000FFu; // c
    if (opcode & (1u << 19u)) mask |= 0xFF000000u; // f
    return mask;
}

// 乗算内部サイクル (値依存 1..4)
__attribute__((always_inline)) static inline uint32_t MulInternalCycles(uint32_t rs_val) {
    if ((rs_val & 0xFFFFFF00u) == 0u || (rs_val & 0xFFFFFF00u) == 0xFFFFFF00u) return 1u;
    if ((rs_val & 0xFFFF0000u) == 0u || (rs_val & 0xFFFF0000u) == 0xFFFF0000u) return 2u;
    if ((rs_val & 0xFF000000u) == 0u || (rs_val & 0xFF000000u) == 0xFF000000u) return 3u;
    return 4u;
}

} // namespace

// ─── サイクル見積もり ─────────────────────────────────────────────────────────

uint32_t GBACore::EstimateArmCycles(uint32_t opcode) const {
    // SWI
    if ((opcode & 0x0F000000u) == 0x0F000000u) return 3u;
    // BX
    if ((opcode & 0x0FFFFFF0u) == 0x012FFF10u) return 3u;
    // B / BL
    if ((opcode & 0x0E000000u) == 0x0A000000u) return 3u;
    // LDM / STM
    if ((opcode & 0x0E000000u) == 0x08000000u) {
        const uint32_t n = static_cast<uint32_t>(__builtin_popcount(opcode & 0xFFFFu));
        return 1u + (n ? n : 1u);
    }
    // LDR / STR / LDRH 等
    if ((opcode & 0x0C000000u) == 0x04000000u) return 3u;
    if ((opcode & 0x0E000090u) == 0x00000090u) return 3u;
    // MUL / MLA
    if ((opcode & 0x0FC000F0u) == 0x00000090u)
        return (opcode & (1u << 21u)) ? 3u : 2u;
    // MULL / MLAL
    if ((opcode & 0x0F8000F0u) == 0x00800090u) return 4u;
    // SWP / SWPB
    if ((opcode & 0x0FB00FF0u) == 0x01000090u) return 4u;
    // データ処理 (レジスタシフト: +1I)
    if ((opcode & 0x0C000000u) == 0x00000000u &&
        (opcode & (1u << 4u)) && !(opcode & (1u << 25u))) return 2u;
    return 1u;
}

// ─── ARM命令実行 ──────────────────────────────────────────────────────────────

void GBACore::ExecuteArmInstruction(uint32_t opcode) {
    // 条件コードチェック
    const uint32_t cond = opcode >> 28u;
    if (cond == 0xFu) {
        HandleUndefinedInstruction(false);
        return;
    }
    if (!CheckCondition(cond)) {
        cpu_.regs[15] += 4u;
        return;
    }

    // ── SWI ──────────────────────────────────────────────────────────────────
    if ((opcode & 0x0F000000u) == 0x0F000000u) {
        HandleSoftwareInterrupt(opcode & 0xFFFFFFu, false);
        return;
    }

    // ── B / BL ───────────────────────────────────────────────────────────────
    // ARM7TDMI: target = (PC + 8) + (sign_extend_24bit << 2)
    //           PC during execute = execute_addr + 8
    if ((opcode & 0x0E000000u) == 0x0A000000u) {
        // imm24 → sign-extend → << 2
        const int32_t off = static_cast<int32_t>((opcode & 0x00FFFFFFu) << 8u) >> 6;
        if (opcode & (1u << 24u)) {
            // BL: LR = execute_addr + 4 (次命令アドレス)
            cpu_.regs[14] = cpu_.regs[15] + 4u;
        }
        // target = execute_addr + 8 + off
        cpu_.regs[15] = cpu_.regs[15] + 8u + static_cast<uint32_t>(off);
        return;
    }

    // ── BX ───────────────────────────────────────────────────────────────────
    if ((opcode & 0x0FFFFFF0u) == 0x012FFF10u) {
        const uint32_t rm  = opcode & 0xFu;
        const uint32_t tgt = (rm == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rm];
        if (tgt & 1u) {
            cpu_.cpsr |=  (1u << 5u); // Thumbへ
            cpu_.regs[15] = tgt & ~1u;
        } else {
            cpu_.cpsr &= ~(1u << 5u); // ARMへ
            cpu_.regs[15] = tgt & ~3u;
        }
        return;
    }

    // ── MUL / MLA ────────────────────────────────────────────────────────────
    if ((opcode & 0x0FC000F0u) == 0x00000090u) {
        const bool acc       = (opcode & (1u << 21u)) != 0u;
        const bool setflags  = (opcode & (1u << 20u)) != 0u;
        const uint32_t rd = ArmReg(opcode, 16u);
        const uint32_t rn = ArmReg(opcode, 12u);
        const uint32_t rs = ArmReg(opcode, 8u);
        const uint32_t rm = ArmReg(opcode, 0u);
        if (rd != 15u) {
            uint32_t res = cpu_.regs[rm] * cpu_.regs[rs];
            if (acc) res += cpu_.regs[rn];
            cpu_.regs[rd] = res;
            if (setflags) SetNZFlags(res);
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── MULL / MLAL (UMULL/UMLAL/SMULL/SMLAL) ───────────────────────────────
    if ((opcode & 0x0F8000F0u) == 0x00800090u) {
        const bool is_signed = (opcode & (1u << 22u)) != 0u;
        const bool acc       = (opcode & (1u << 21u)) != 0u;
        const bool setflags  = (opcode & (1u << 20u)) != 0u;
        const uint32_t rdhi = ArmReg(opcode, 16u);
        const uint32_t rdlo = ArmReg(opcode, 12u);
        const uint32_t rs   = ArmReg(opcode, 8u);
        const uint32_t rm   = ArmReg(opcode, 0u);
        if (rdhi != 15u && rdlo != 15u) {
            uint64_t prod;
            if (is_signed) {
                prod = static_cast<uint64_t>(
                    static_cast<int64_t>(static_cast<int32_t>(cpu_.regs[rm])) *
                    static_cast<int64_t>(static_cast<int32_t>(cpu_.regs[rs])));
            } else {
                prod = static_cast<uint64_t>(cpu_.regs[rm]) *
                       static_cast<uint64_t>(cpu_.regs[rs]);
            }
            if (acc) {
                prod += (static_cast<uint64_t>(cpu_.regs[rdhi]) << 32u) |
                        static_cast<uint64_t>(cpu_.regs[rdlo]);
            }
            cpu_.regs[rdlo] = static_cast<uint32_t>(prod);
            cpu_.regs[rdhi] = static_cast<uint32_t>(prod >> 32u);
            if (setflags) {
                const uint32_t hi = cpu_.regs[rdhi];
                const uint32_t lo = cpu_.regs[rdlo];
                cpu_.cpsr = (cpu_.cpsr & ~((1u << 31u) | (1u << 30u)))
                          | (hi & 0x80000000u)
                          | (((hi | lo) == 0u) ? (1u << 30u) : 0u);
            }
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── SWP / SWPB ───────────────────────────────────────────────────────────
    if ((opcode & 0x0FB00FF0u) == 0x01000090u) {
        const bool byte_mode = (opcode & (1u << 22u)) != 0u;
        const uint32_t rn = ArmReg(opcode, 16u);
        const uint32_t rd = ArmReg(opcode, 12u);
        const uint32_t rm = ArmReg(opcode, 0u);
        const uint32_t addr  = (rn == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
        const uint32_t store = (rm == 15u) ? (cpu_.regs[15] + 12u) : cpu_.regs[rm];
        if (byte_mode) {
            const uint8_t old = Read8(addr);
            Write8(addr, static_cast<uint8_t>(store));
            if (rd != 15u) cpu_.regs[rd] = old;
        } else {
            const uint32_t old = Read32(addr);
            Write32(addr, store);
            if (rd != 15u) cpu_.regs[rd] = old;
        }
        if (rd == 15u) { cpu_.regs[15] &= ~3u; return; }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── MRS ──────────────────────────────────────────────────────────────────
    // MRS Rd, CPSR/SPSR
    if ((opcode & 0x0FBF0FFFu) == 0x010F0000u) {
        const bool spsr = (opcode & (1u << 22u)) != 0u;
        const uint32_t rd = ArmReg(opcode, 12u);
        if (rd == 15u) { cpu_.regs[15] += 4u; return; } // UNPREDICTABLE
        if (spsr) {
            if (!HasSpsr(GetCpuMode())) { HandleUndefinedInstruction(false); return; }
            cpu_.regs[rd] = cpu_.spsr[GetCpuMode() & 0x1Fu];
        } else {
            cpu_.regs[rd] = cpu_.cpsr;
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── MSR (レジスタ) ────────────────────────────────────────────────────────
    // MSR CPSR/SPSR, Rm
    if ((opcode & 0x0DB0F000u) == 0x0120F000u) {
        const bool spsr = (opcode & (1u << 22u)) != 0u;
        if (spsr && !HasSpsr(GetCpuMode())) { HandleUndefinedInstruction(false); return; }
        const uint32_t rm    = opcode & 0xFu;
        const uint32_t rmval = ArmReadReg(cpu_.regs, rm);
        uint32_t mask = ArmMsrMask(opcode);
        if (!IsPrivilegedMode(GetCpuMode())) mask &= 0xF0000000u;
        if (spsr) {
            auto& psr = cpu_.spsr[GetCpuMode() & 0x1Fu];
            psr = (psr & ~mask) | (rmval & mask);
        } else {
            const uint32_t old_mode = GetCpuMode();
            cpu_.cpsr = (cpu_.cpsr & ~mask) | (rmval & mask);
            if ((mask & 0x1Fu) && GetCpuMode() != old_mode)
                SwitchCpuMode(GetCpuMode());
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── MSR (即値) ────────────────────────────────────────────────────────────
    // MSR CPSR/SPSR, #imm
    if ((opcode & 0x0DB0F000u) == 0x0320F000u) {
        const bool spsr = (opcode & (1u << 22u)) != 0u;
        if (spsr && !HasSpsr(GetCpuMode())) { HandleUndefinedInstruction(false); return; }
        const uint32_t imm  = ExpandArmImmediate(opcode & 0xFFFu);
        uint32_t mask = ArmMsrMask(opcode);
        if (!IsPrivilegedMode(GetCpuMode())) mask &= 0xF0000000u;
        if (spsr) {
            auto& psr = cpu_.spsr[GetCpuMode() & 0x1Fu];
            psr = (psr & ~mask) | (imm & mask);
        } else {
            const uint32_t old_mode = GetCpuMode();
            cpu_.cpsr = (cpu_.cpsr & ~mask) | (imm & mask);
            if ((mask & 0x1Fu) && GetCpuMode() != old_mode)
                SwitchCpuMode(GetCpuMode());
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── LDRH / STRH / LDRSB / LDRSH (アドレッシングモード3) ─────────────────
    // bit25=0, bit7=1, bit4=1, not coprocessor
    if ((opcode & 0x0E000090u) == 0x00000090u) {
        const bool pre      = (opcode & (1u << 24u)) != 0u;
        const bool up       = (opcode & (1u << 23u)) != 0u;
        const bool imm_off  = (opcode & (1u << 22u)) != 0u;
        const bool wb       = (opcode & (1u << 21u)) != 0u;
        const bool load     = (opcode & (1u << 20u)) != 0u;
        const uint32_t rn   = ArmReg(opcode, 16u);
        const uint32_t rd   = ArmReg(opcode, 12u);
        const uint32_t hops = (opcode >> 5u) & 0x3u; // 1=H,2=SB,3=SH

        uint32_t off;
        if (imm_off) {
            off = ((opcode >> 4u) & 0xF0u) | (opcode & 0xFu);
        } else {
            const uint32_t rm = opcode & 0xFu;
            off = (rm == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rm];
        }

        uint32_t addr = (rn == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
        if (pre) addr = up ? (addr + off) : (addr - off);

        if (load) {
            uint32_t val;
            switch (hops) {
                case 1u: val = Read16(addr); break;
                case 2u: val = static_cast<uint32_t>(static_cast<int32_t>(
                                   static_cast<int8_t>(Read8(addr)))); break;
                default: // LDRSH
                    val = (addr & 1u) ? static_cast<uint32_t>(static_cast<int32_t>(
                                            static_cast<int8_t>(Read8(addr))))
                                      : static_cast<uint32_t>(static_cast<int32_t>(
                                            static_cast<int16_t>(Read16(addr))));
                    break;
            }
            cpu_.regs[rd] = val;
        } else if (hops == 1u) {
            const uint32_t sv = (rd == 15u) ? (cpu_.regs[15] + 12u) : cpu_.regs[rd];
            Write16(addr, static_cast<uint16_t>(sv));
        }

        if (!pre) addr = up ? (addr + off) : (addr - off);
        // ライトバック: LDM+Rn==Rd の場合は抑制
        if (rn != 15u && (wb || !pre)) {
            if (!(load && rd == rn)) cpu_.regs[rn] = addr;
        }
        if (load && rd == 15u) { cpu_.regs[15] &= ~3u; return; }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── LDR / STR (アドレッシングモード2) ────────────────────────────────────
    if ((opcode & 0x0C000000u) == 0x04000000u) {
        const bool imm_off = (opcode & (1u << 25u)) == 0u;
        const bool pre     = (opcode & (1u << 24u)) != 0u;
        const bool up      = (opcode & (1u << 23u)) != 0u;
        const bool byte    = (opcode & (1u << 22u)) != 0u;
        const bool wb      = (opcode & (1u << 21u)) != 0u;
        const bool load    = (opcode & (1u << 20u)) != 0u;
        const uint32_t rn  = ArmReg(opcode, 16u);
        const uint32_t rd  = ArmReg(opcode, 12u);

        uint32_t off;
        if (imm_off) {
            off = opcode & 0xFFFu;
        } else {
            const uint32_t rm   = opcode & 0xFu;
            const uint32_t stype = (opcode >> 5u) & 0x3u;
            const bool     sbyR  = (opcode & (1u << 4u)) != 0u;
            uint32_t samt;
            if (sbyR) {
                const uint32_t rs = (opcode >> 8u) & 0xFu;
                samt = ((rs == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rs]) & 0xFFu;
                const uint32_t rmv = ArmReadRegRS(cpu_.regs, rm);
                off = ArmRegShift(rmv, stype, samt, GetFlagC(), nullptr);
            } else {
                samt = (opcode >> 7u) & 0x1Fu;
                const uint32_t rmv = ArmReadReg(cpu_.regs, rm);
                off = ApplyShift(rmv, stype, samt, nullptr);
            }
        }

        uint32_t addr = (rn == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
        if (pre) addr = up ? (addr + off) : (addr - off);

        if (load) {
            uint32_t v;
            if (byte) {
                v = Read8(addr);
            } else {
                const uint32_t aln = addr & ~3u;
                v = Read32(aln);
                if (addr & 3u) v = RotateRight(v, (addr & 3u) * 8u);
            }
            cpu_.regs[rd] = v;
        } else {
            const uint32_t sv = (rd == 15u) ? (cpu_.regs[15] + 12u) : cpu_.regs[rd];
            if (byte) Write8(addr, static_cast<uint8_t>(sv));
            else      Write32(addr, sv);
        }

        if (!pre) addr = up ? (addr + off) : (addr - off);
        if (rn != 15u && (wb || !pre)) {
            if (!(load && rd == rn)) cpu_.regs[rn] = addr;
        }
        if (rd == 15u && load) { cpu_.regs[15] &= ~3u; return; }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── LDM / STM ────────────────────────────────────────────────────────────
    if ((opcode & 0x0E000000u) == 0x08000000u) {
        const bool pre      = (opcode & (1u << 24u)) != 0u;
        const bool up       = (opcode & (1u << 23u)) != 0u;
        const bool s        = (opcode & (1u << 22u)) != 0u; // ユーザーバンク / SPSR復元
        const bool wb       = (opcode & (1u << 21u)) != 0u;
        const bool load     = (opcode & (1u << 20u)) != 0u;
        const uint32_t rn   = ArmReg(opcode, 16u);
        const uint32_t rlist = opcode & 0xFFFFu;

        uint32_t addr = (rn == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
        const uint32_t base_addr = addr;
        const uint32_t n_regs = rlist ? static_cast<uint32_t>(__builtin_popcount(rlist)) : 1u;
        const uint32_t wb_addr = up ? (base_addr + n_regs * 4u) : (base_addr - n_regs * 4u);

        // S ビット: PC含まないリストでユーザーバンクアクセス
        const bool usr_bank = s && ((rlist & (1u << 15u)) == 0u);
        const bool fiq_mode = (GetCpuMode() == 0x11u);

        // 空リスト: ARM7TDMI quirk
        if (rlist == 0u) {
            if (load) {
                cpu_.regs[15] = Read32(addr) & ~3u;
                if (rn != 15u && wb)
                    cpu_.regs[rn] = up ? (cpu_.regs[rn] + 0x40u) : (cpu_.regs[rn] - 0x40u);
                return;
            }
            Write32(addr, cpu_.regs[15] + 12u);
            if (rn != 15u && wb)
                cpu_.regs[rn] = up ? (cpu_.regs[rn] + 0x40u) : (cpu_.regs[rn] - 0x40u);
            cpu_.regs[15] += 4u;
            return;
        }

        // ユーザーバンクアクセス用ヘルパー
        auto read_usr = [&](uint32_t r) -> uint32_t {
            if (!usr_bank) return cpu_.regs[r];
            if (r >= 8u && r <= 12u)
                return fiq_mode ? cpu_.banked_usr_r8_r12[r - 8u] : cpu_.regs[r];
            if (r == 13u) return cpu_.banked_sp[0x1Fu];
            if (r == 14u) return cpu_.banked_lr[0x1Fu];
            return cpu_.regs[r];
        };
        auto write_usr = [&](uint32_t r, uint32_t v) {
            if (!usr_bank) { cpu_.regs[r] = v; return; }
            if (r >= 8u && r <= 12u) {
                if (fiq_mode) cpu_.banked_usr_r8_r12[r - 8u] = v;
                else          cpu_.regs[r] = v;
                return;
            }
            if      (r == 13u) cpu_.banked_sp[0x1Fu] = v;
            else if (r == 14u) cpu_.banked_lr[0x1Fu] = v;
            else               cpu_.regs[r] = v;
        };

        for (uint32_t r = 0u; r < 16u; ++r) {
            if ((rlist & (1u << r)) == 0u) continue;
            if (pre) addr = up ? (addr + 4u) : (addr - 4u);
            if (load) {
                write_usr(r, Read32(addr));
            } else {
                uint32_t sv = read_usr(r);
                // STM: Rn が最初以外のレジスタの場合、ライトバック済みアドレスを格納
                if (wb && r == rn && rn != 15u) {
                    const bool first = (rlist & ((1u << r) - 1u)) == 0u;
                    if (!first) sv = wb_addr;
                }
                if (r == 15u) sv = cpu_.regs[15] + 12u;
                Write32(addr, sv);
            }
            if (!pre) addr = up ? (addr + 4u) : (addr - 4u);
        }

        // ライトバック: LDM+Rn in rlist の場合は抑制
        if (rn != 15u && wb) {
            if (!load || ((rlist & (1u << rn)) == 0u))
                cpu_.regs[rn] = addr;
        }

        // PC がロードされた場合
        if (load && (rlist & (1u << 15u))) {
            cpu_.regs[15] &= ~3u;
            if (s && HasSpsr(GetCpuMode())) {
                const uint32_t old_mode = GetCpuMode();
                cpu_.cpsr = cpu_.spsr[old_mode & 0x1Fu];
                const uint32_t new_mode = GetCpuMode();
                if (new_mode != old_mode) SwitchCpuMode(new_mode);
            }
            return;
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // ── データ処理 (ALU) ──────────────────────────────────────────────────────
    if ((opcode & 0x0C000000u) == 0x00000000u) {
        const bool imm_mode = (opcode & (1u << 25u)) != 0u;
        const uint32_t alu_op   = (opcode >> 21u) & 0xFu;
        const bool setflags     = (opcode & (1u << 20u)) != 0u;
        const uint32_t rn       = ArmReg(opcode, 16u);
        const uint32_t rd       = ArmReg(opcode, 12u);
        const bool reg_shift    = !imm_mode && ((opcode & (1u << 4u)) != 0u);

        // rn == PC: レジスタシフトなら +12、即値/即値シフトなら +8
        const uint32_t lhs = (rn == 15u) ? (cpu_.regs[15] + (reg_shift ? 12u : 8u))
                                          : cpu_.regs[rn];

        bool carry = GetFlagC();
        uint32_t rhs;
        if (imm_mode) {
            rhs = ExpandArmImmediate(opcode & 0xFFFu);
            const uint32_t rot = ((opcode >> 8u) & 0xFu) * 2u;
            if (rot) carry = (rhs >> 31u) & 1u;
        } else {
            const uint32_t rm    = opcode & 0xFu;
            const uint32_t stype = (opcode >> 5u) & 0x3u;
            if (reg_shift) {
                // Rs の低8ビットがシフト量
                const uint32_t rs   = (opcode >> 8u) & 0xFu;
                const uint32_t samt = ((rs == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rs]) & 0xFFu;
                const uint32_t rmv  = ArmReadRegRS(cpu_.regs, rm);
                rhs = ArmRegShift(rmv, stype, samt, carry, &carry);
            } else {
                const uint32_t samt = (opcode >> 7u) & 0x1Fu;
                const uint32_t rmv  = ArmReadReg(cpu_.regs, rm);
                rhs = ApplyShift(rmv, stype, samt, &carry);
            }
        }

        uint64_t r64  = 0ull;
        uint32_t res  = 0u;
        const bool c  = GetFlagC();
        switch (alu_op) {
            case 0x0u: // AND
                res = lhs & rhs;
                if (setflags) { SetNZFlags(res); SetFlagC(carry); } break;
            case 0x1u: // EOR
                res = lhs ^ rhs;
                if (setflags) { SetNZFlags(res); SetFlagC(carry); } break;
            case 0x2u: // SUB
                r64 = static_cast<uint64_t>(lhs) - rhs;
                res = static_cast<uint32_t>(r64);
                if (setflags) SetSubFlags(lhs, rhs, r64); break;
            case 0x3u: // RSB
                r64 = static_cast<uint64_t>(rhs) - lhs;
                res = static_cast<uint32_t>(r64);
                if (setflags) SetSubFlags(rhs, lhs, r64); break;
            case 0x4u: // ADD
                r64 = static_cast<uint64_t>(lhs) + rhs;
                res = static_cast<uint32_t>(r64);
                if (setflags) SetAddFlags(lhs, rhs, r64); break;
            case 0x5u: { // ADC
                const uint32_t cv = c ? 1u : 0u;
                r64 = static_cast<uint64_t>(lhs) + rhs + cv;
                res = static_cast<uint32_t>(r64);
                if (setflags) SetAddFlags(lhs, rhs + cv, r64); break;
            }
            case 0x6u: { // SBC
                const uint32_t borrow = c ? 0u : 1u;
                r64 = static_cast<uint64_t>(lhs) - rhs - borrow;
                res = static_cast<uint32_t>(r64);
                if (setflags) SetSubFlags(lhs, rhs + borrow, r64); break;
            }
            case 0x7u: { // RSC
                const uint32_t borrow = c ? 0u : 1u;
                r64 = static_cast<uint64_t>(rhs) - lhs - borrow;
                res = static_cast<uint32_t>(r64);
                if (setflags) SetSubFlags(rhs, lhs + borrow, r64); break;
            }
            case 0x8u: // TST
                r64 = lhs & rhs;
                if (setflags) { SetNZFlags(static_cast<uint32_t>(r64)); SetFlagC(carry); } break;
            case 0x9u: // TEQ
                r64 = lhs ^ rhs;
                if (setflags) { SetNZFlags(static_cast<uint32_t>(r64)); SetFlagC(carry); } break;
            case 0xAu: // CMP
                r64 = static_cast<uint64_t>(lhs) - rhs;
                if (setflags) SetSubFlags(lhs, rhs, r64); break;
            case 0xBu: // CMN
                r64 = static_cast<uint64_t>(lhs) + rhs;
                if (setflags) SetAddFlags(lhs, rhs, r64); break;
            case 0xCu: // ORR
                res = lhs | rhs;
                if (setflags) { SetNZFlags(res); SetFlagC(carry); } break;
            case 0xDu: // MOV
                res = rhs;
                if (setflags) { SetNZFlags(res); SetFlagC(carry); } break;
            case 0xEu: // BIC
                res = lhs & ~rhs;
                if (setflags) { SetNZFlags(res); SetFlagC(carry); } break;
            case 0xFu: // MVN
                res = ~rhs;
                if (setflags) { SetNZFlags(res); SetFlagC(carry); } break;
            default:
                cpu_.regs[15] += 4u;
                return;
        }

        // TST/TEQ/CMP/CMN は rd に書き込まない
        if (alu_op >= 0x8u && alu_op <= 0xBu) {
            cpu_.regs[15] += 4u;
            return;
        }

        cpu_.regs[rd] = res;
        if (rd == 15u) {
            cpu_.regs[15] &= ~3u;
            if (setflags && HasSpsr(GetCpuMode())) {
                const uint32_t old_mode = GetCpuMode();
                cpu_.cpsr = cpu_.spsr[old_mode & 0x1Fu];
                const uint32_t new_mode = GetCpuMode();
                if (new_mode != old_mode) SwitchCpuMode(new_mode);
            }
            return;
        }
        cpu_.regs[15] += 4u;
        return;
    }

    // コプロセッサ / 未定義
    HandleUndefinedInstruction(false);
}

// ─── CPU スライス実行 ─────────────────────────────────────────────────────────

uint32_t GBACore::RunCpuSlice(uint32_t cycles) {
    while (cycles > 0u) {
        ServiceInterruptIfNeeded();
        if (cpu_.halted) break;

        const bool thumb = (cpu_.cpsr & (1u << 5u)) != 0u;
        const uint32_t pc_exec = cpu_.regs[15]; // 実行アドレス

        // BIOSフェッチラッチ更新
        if (pc_exec < 0x4000u) {
            const uint32_t a = pc_exec & ~3u;
            bios_fetch_latch_ =
                static_cast<uint32_t>(bios_[a & 0x3FFFu]) |
                (static_cast<uint32_t>(bios_[(a + 1u) & 0x3FFFu]) << 8u) |
                (static_cast<uint32_t>(bios_[(a + 2u) & 0x3FFFu]) << 16u) |
                (static_cast<uint32_t>(bios_[(a + 3u) & 0x3FFFu]) << 24u);
        }

        const uint64_t ws_before      = waitstates_accum_;
        const uint32_t pending_refill = pipeline_refill_pending_;
        pipeline_refill_pending_      = 0u;

        if (thumb) {
            // ── Thumb フェッチ & 実行 ────────────────────────────────────
            const uint16_t op = Read16(pc_exec);
            ExecuteThumbInstruction(op);
            if (cpu_.regs[15] != pc_exec + 2u) FlushPipeline(1u);

            const uint32_t base_spent = EstimateThumbCycles(op);
            const uint32_t ws_delta   = static_cast<uint32_t>(waitstates_accum_ - ws_before);
            const uint32_t spent      = base_spent + ws_delta + pending_refill +
                                         pipeline_refill_pending_;
            pipeline_refill_pending_ = 0u;
            cycles = (spent >= cycles) ? 0u : (cycles - spent);
            executed_cycles_ += spent;
        } else {
            // ── ARM フェッチ & 実行 ──────────────────────────────────────
            const uint32_t op = Read32(pc_exec);

            // 乗算命令の内部サイクルをプリ計算
            uint32_t mul_override = 0u;
            if ((op & 0x0FC000F0u) == 0x00000090u) {
                const uint32_t rs    = ArmReg(op, 8u);
                const uint32_t rsval = (rs == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rs];
                const uint32_t ic    = MulInternalCycles(rsval);
                mul_override = 1u + ic + ((op & (1u << 21u)) ? 1u : 0u);
            } else if ((op & 0x0F8000F0u) == 0x00800090u) {
                const uint32_t rs    = ArmReg(op, 8u);
                const uint32_t rsval = (rs == 15u) ? (cpu_.regs[15] + 8u) : cpu_.regs[rs];
                const uint32_t ic    = MulInternalCycles(rsval);
                mul_override = 2u + ic + ((op & (1u << 21u)) ? 1u : 0u);
            }

            ExecuteArmInstruction(op);
            if (cpu_.regs[15] != pc_exec + 4u) FlushPipeline(2u);

            const uint32_t base_spent = mul_override ? mul_override : EstimateArmCycles(op);
            const uint32_t ws_delta   = static_cast<uint32_t>(waitstates_accum_ - ws_before);
            const uint32_t spent      = base_spent + ws_delta + pending_refill +
                                         pipeline_refill_pending_;
            pipeline_refill_pending_ = 0u;
            cycles = (spent >= cycles) ? 0u : (cycles - spent);
            executed_cycles_ += spent;
        }
    }
    return cycles;
}

} // namespace gba
