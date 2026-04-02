// cpu_thumb_run.mm
//
// GBA ARM7TDMI CPU – Thumb命令実行エンジン (完全実装版)
//
// ARM7TDMI Thumb パイプラインモデル:
//   cpu_.regs[15] = 現在実行中命令のアドレス (execute_addr)
//   命令がオペランドとして r15 を読む場合: execute_addr + 4 を返す (Thumb)
//   分岐後: cpu_.regs[15] = 分岐先アドレス
//   通常終了: cpu_.regs[15] += 2
//
// 参考: isa-thumb.c (C実装からの完全移植)

#include "../gba_core.h"

namespace gba {

namespace {

// ── Thumbレジスタシフト (Rsの低8ビットを使用) ─────────────────────────────────
__attribute__((always_inline)) static inline uint32_t ThumbRegShift(uint32_t value, uint32_t type,
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

} // namespace

// ─── Thumbサイクル見積もり ────────────────────────────────────────────────────

uint32_t GBACore::EstimateThumbCycles(uint16_t opcode) const {
    // SWI
    if ((opcode & 0xFF00u) == 0xDF00u) return 3u;
    // B<cond> / B
    if ((opcode & 0xF000u) == 0xD000u || (opcode & 0xF800u) == 0xE000u) return 3u;
    // BL prefix/suffix
    if ((opcode & 0xE000u) == 0xF000u) return 3u;
    // BX / high-reg ADD / MOV
    if ((opcode & 0xFF00u) == 0x4700u) return 3u;
    // MUL
    if ((opcode & 0xFFC0u) == 0x4340u) return 3u;
    // PUSH/POP
    if ((opcode & 0xF600u) == 0xB400u) {
        uint32_t n = static_cast<uint32_t>(__builtin_popcount(opcode & 0xFFu));
        if (opcode & 0x0100u) ++n;
        return 1u + n;
    }
    // STMIA/LDMIA
    if ((opcode & 0xF000u) == 0xC000u) {
        const uint32_t n = static_cast<uint32_t>(__builtin_popcount(opcode & 0xFFu));
        return 1u + (n ? n : 1u);
    }
    // メモリアクセス系
    if ((opcode & 0xF000u) == 0x5000u || (opcode & 0xE000u) == 0x6000u ||
        (opcode & 0xF000u) == 0x8000u || (opcode & 0xF800u) == 0x4800u ||
        (opcode & 0xF000u) == 0x9000u) return 2u;
    return 1u;
}

// ─── Thumb命令実行 ────────────────────────────────────────────────────────────

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {

    // ── SWI (0xDF__) ─────────────────────────────────────────────────────────
    if ((opcode & 0xFF00u) == 0xDF00u) {
        HandleSoftwareInterrupt(opcode & 0xFFu, true);
        return;
    }

    // ── BKPT (0xBE__) → 未定義として処理 ────────────────────────────────────
    if ((opcode & 0xFF00u) == 0xBE00u) {
        HandleUndefinedInstruction(true);
        return;
    }

    // ── BL suffix (0xF800..0xFFFF) ───────────────────────────────────────────
    // BL2: PC = LR + (imm11 << 1), LR = (execute_addr + 4) | 1
    // ARM7TDMI: LR の bit0 = 1 (Thumbリターン先を示す)
    if ((opcode & 0xF800u) == 0xF800u) {
        const uint32_t off    = (opcode & 0x07FFu) << 1u;
        const uint32_t target = cpu_.regs[14] + off;
        // LR = execute_addr + 4 - 1 = execute_addr + 3
        // (ARM7TDMIはリターンアドレス | 1 でThumb継続を示す)
        cpu_.regs[14] = (cpu_.regs[15] + 4u) - 1u;
        cpu_.regs[15] = target & ~1u;
        return;
    }

    // ── BL prefix (0xF000..0xF7FF) ───────────────────────────────────────────
    // BL1: LR = (execute_addr + 4) + (sign_extend_11bit << 12)
    if ((opcode & 0xF800u) == 0xF000u) {
        const int32_t off = static_cast<int32_t>(
            static_cast<int16_t>((opcode & 0x07FFu) << 5u)) << 7;
        cpu_.regs[14] = (cpu_.regs[15] + 4u) + static_cast<uint32_t>(off);
        cpu_.regs[15] += 2u;
        return;
    }

    // ── 無条件B (0xE000..0xE7FF) ─────────────────────────────────────────────
    // target = execute_addr + 4 + (sign_extend_11bit << 1)
    if ((opcode & 0xF800u) == 0xE000u) {
        const int32_t off = static_cast<int32_t>(
            static_cast<int16_t>((opcode & 0x07FFu) << 5u)) >> 4;
        cpu_.regs[15] = cpu_.regs[15] + 4u + static_cast<uint32_t>(off);
        return;
    }

    // ── 条件分岐 B<cond> (0xD000..0xDEFF) ────────────────────────────────────
    // 0xDF = SWI (上で処理済み), 0xDE = 未定義
    if ((opcode & 0xF000u) == 0xD000u) {
        const uint32_t cond = (opcode >> 8u) & 0xFu;
        if (cond == 0xFu) { HandleUndefinedInstruction(true); return; }
        const int32_t off = static_cast<int32_t>(static_cast<int8_t>(opcode & 0xFFu)) << 1;
        if (CheckCondition(cond)) {
            cpu_.regs[15] = cpu_.regs[15] + 4u + static_cast<uint32_t>(off);
        } else {
            cpu_.regs[15] += 2u;
        }
        return;
    }

    // ── High-reg ops / BX (0x4400..0x47FF) ──────────────────────────────────
    if ((opcode & 0xFC00u) == 0x4400u) {
        const uint32_t op2 = (opcode >> 8u) & 0x3u;
        const uint32_t h1  = (opcode >> 7u) & 1u;
        const uint32_t h2  = (opcode >> 6u) & 1u;
        const uint32_t rd  = (opcode & 0x7u) | (h1 << 3u);
        const uint32_t rm  = ((opcode >> 3u) & 0x7u) | (h2 << 3u);
        // rm==15 のとき: execute_addr + 4
        const uint32_t rmv = (rm == 15u) ? (cpu_.regs[15] + 4u) : cpu_.regs[rm];

        if (op2 == 3u) {
            // BX Rm
            if (rmv & 1u) {
                cpu_.cpsr |=  (1u << 5u);
                cpu_.regs[15] = rmv & ~1u;
            } else {
                cpu_.cpsr &= ~(1u << 5u);
                cpu_.regs[15] = rmv & ~3u;
            }
            return;
        }

        const uint32_t rdv = (rd == 15u) ? (cpu_.regs[15] + 4u) : cpu_.regs[rd];
        if (op2 == 0u) { // ADD Rd, Rm
            cpu_.regs[rd] = rdv + rmv;
            if (rd == 15u) { cpu_.regs[15] &= ~1u; return; }
        } else if (op2 == 1u) { // CMP Rd, Rm
            const uint64_t r64 = static_cast<uint64_t>(rdv) - rmv;
            SetSubFlags(rdv, rmv, r64);
        } else { // MOV Rd, Rm
            cpu_.regs[rd] = rmv;
            if (rd == 15u) { cpu_.regs[15] &= ~1u; return; }
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── ADD/SUB format 2 (0x1800..0x1FFF) ───────────────────────────────────
    // ADD/SUB Rd, Rn, Rm/imm3
    if ((opcode & 0xF800u) == 0x1800u) {
        const bool is_sub = (opcode & 0x0200u) != 0u;
        const bool is_imm = (opcode & 0x0400u) != 0u;
        const uint32_t rn  = (opcode >> 3u) & 0x7u;
        const uint32_t rd  = opcode & 0x7u;
        const uint32_t op2 = is_imm ? ((opcode >> 6u) & 0x7u) : cpu_.regs[(opcode >> 6u) & 0x7u];
        const uint32_t lhs = cpu_.regs[rn];
        uint64_t r64;
        if (is_sub) {
            r64 = static_cast<uint64_t>(lhs) - op2;
            cpu_.regs[rd] = static_cast<uint32_t>(r64);
            SetSubFlags(lhs, op2, r64);
        } else {
            r64 = static_cast<uint64_t>(lhs) + op2;
            cpu_.regs[rd] = static_cast<uint32_t>(r64);
            SetAddFlags(lhs, op2, r64);
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── シフト即値 format 1 (0x0000..0x17FF) ─────────────────────────────────
    // LSL/LSR/ASR Rd, Rs, #imm5
    if ((opcode & 0xE000u) == 0x0000u) {
        const uint32_t stype = (opcode >> 11u) & 0x3u;
        uint32_t imm5 = (opcode >> 6u) & 0x1Fu;
        const uint32_t rs = (opcode >> 3u) & 0x7u;
        const uint32_t rd = opcode & 0x7u;
        // imm5==0 の LSR/ASR は #32 を意味する
        if (imm5 == 0u && stype != 0u) imm5 = 32u;
        bool carry = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rs], stype, imm5, &carry);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(carry);
        cpu_.regs[15] += 2u;
        return;
    }

    // ── ALU imm8 format 3 (0x2000..0x3FFF) ──────────────────────────────────
    // MOV/CMP/ADD/SUB Rd, #imm8
    if ((opcode & 0xE000u) == 0x2000u) {
        const uint32_t op2 = (opcode >> 11u) & 0x3u;
        const uint32_t rd  = (opcode >> 8u) & 0x7u;
        const uint32_t imm = opcode & 0xFFu;
        if (op2 == 0u) { // MOV
            cpu_.regs[rd] = imm;
            SetNZFlags(imm);
        } else if (op2 == 1u) { // CMP
            const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - imm;
            SetSubFlags(cpu_.regs[rd], imm, r64);
        } else if (op2 == 2u) { // ADD
            const uint32_t lhs = cpu_.regs[rd];
            const uint64_t r64 = static_cast<uint64_t>(lhs) + imm;
            cpu_.regs[rd] = static_cast<uint32_t>(r64);
            SetAddFlags(lhs, imm, r64);
        } else { // SUB
            const uint32_t lhs = cpu_.regs[rd];
            const uint64_t r64 = static_cast<uint64_t>(lhs) - imm;
            cpu_.regs[rd] = static_cast<uint32_t>(r64);
            SetSubFlags(lhs, imm, r64);
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── ALU レジスタ (0x4000..0x43FF) ────────────────────────────────────────
    if ((opcode & 0xFC00u) == 0x4000u) {
        const uint32_t op2 = (opcode >> 6u) & 0xFu;
        const uint32_t rs  = (opcode >> 3u) & 0x7u;
        const uint32_t rd  = opcode & 0x7u;
        const uint32_t s   = cpu_.regs[rs];
        const uint32_t d   = cpu_.regs[rd];
        uint64_t r64 = 0ull;
        bool carry = GetFlagC();

        switch (op2) {
            case 0x0u: // AND
                cpu_.regs[rd] = d & s; SetNZFlags(cpu_.regs[rd]); break;
            case 0x1u: // EOR
                cpu_.regs[rd] = d ^ s; SetNZFlags(cpu_.regs[rd]); break;
            case 0x2u: { // LSL Rd, Rs
                bool c = carry;
                cpu_.regs[rd] = ThumbRegShift(d, 0u, s, c, &c);
                SetNZFlags(cpu_.regs[rd]); SetFlagC(c);
                ++executed_cycles_; // Iサイクル
                break;
            }
            case 0x3u: { // LSR Rd, Rs
                bool c = carry;
                cpu_.regs[rd] = ThumbRegShift(d, 1u, s, c, &c);
                SetNZFlags(cpu_.regs[rd]); SetFlagC(c);
                ++executed_cycles_;
                break;
            }
            case 0x4u: { // ASR Rd, Rs
                bool c = carry;
                cpu_.regs[rd] = ThumbRegShift(d, 2u, s, c, &c);
                SetNZFlags(cpu_.regs[rd]); SetFlagC(c);
                ++executed_cycles_;
                break;
            }
            case 0x5u: { // ADC
                const uint32_t cv = carry ? 1u : 0u;
                r64 = static_cast<uint64_t>(d) + s + cv;
                cpu_.regs[rd] = static_cast<uint32_t>(r64);
                SetAddFlags(d, s + cv, r64); break;
            }
            case 0x6u: { // SBC
                const uint32_t borrow = carry ? 0u : 1u;
                r64 = static_cast<uint64_t>(d) - s - borrow;
                cpu_.regs[rd] = static_cast<uint32_t>(r64);
                SetSubFlags(d, s + borrow, r64); break;
            }
            case 0x7u: { // ROR Rd, Rs
                bool c = carry;
                cpu_.regs[rd] = ThumbRegShift(d, 3u, s, c, &c);
                SetNZFlags(cpu_.regs[rd]); SetFlagC(c);
                ++executed_cycles_;
                break;
            }
            case 0x8u: // TST
                SetNZFlags(d & s); break;
            case 0x9u: // NEG (RSB #0)
                r64 = static_cast<uint64_t>(0u) - s;
                cpu_.regs[rd] = static_cast<uint32_t>(r64);
                SetSubFlags(0u, s, r64); break;
            case 0xAu: // CMP
                r64 = static_cast<uint64_t>(d) - s;
                SetSubFlags(d, s, r64); break;
            case 0xBu: // CMN
                r64 = static_cast<uint64_t>(d) + s;
                SetAddFlags(d, s, r64); break;
            case 0xCu: // ORR
                cpu_.regs[rd] = d | s; SetNZFlags(cpu_.regs[rd]); break;
            case 0xDu: // MUL
                cpu_.regs[rd] = d * s; SetNZFlags(cpu_.regs[rd]); break;
            case 0xEu: // BIC
                cpu_.regs[rd] = d & ~s; SetNZFlags(cpu_.regs[rd]); break;
            case 0xFu: // MVN
                cpu_.regs[rd] = ~s; SetNZFlags(cpu_.regs[rd]); break;
            default: break;
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── LDR literal (0x4800..0x4FFF) ─────────────────────────────────────────
    // LDR Rd, [PC, #imm8*4]  (execute_addr+4 & ~3 + imm8*4)
    if ((opcode & 0xF800u) == 0x4800u) {
        const uint32_t rd  = (opcode >> 8u) & 0x7u;
        const uint32_t imm = (opcode & 0xFFu) << 2u;
        const uint32_t base = (cpu_.regs[15] + 4u) & ~3u;
        cpu_.regs[rd] = Read32(base + imm);
        cpu_.regs[15] += 2u;
        return;
    }

    // ── レジスタオフセット LDR/STR (0x5000..0x5FFF) ──────────────────────────
    if ((opcode & 0xF200u) == 0x5000u) {
        const uint32_t op2 = (opcode >> 9u) & 0x7u;
        const uint32_t rm  = (opcode >> 6u) & 0x7u;
        const uint32_t rn  = (opcode >> 3u) & 0x7u;
        const uint32_t rd  = opcode & 0x7u;
        const uint32_t addr = cpu_.regs[rn] + cpu_.regs[rm];
        switch (op2) {
            case 0u: Write32(addr, cpu_.regs[rd]); break;                    // STR
            case 1u: Write16(addr, static_cast<uint16_t>(cpu_.regs[rd])); break; // STRH
            case 2u: Write8(addr, static_cast<uint8_t>(cpu_.regs[rd])); break;   // STRB
            case 3u: // LDRSB
                cpu_.regs[rd] = static_cast<uint32_t>(
                    static_cast<int32_t>(static_cast<int8_t>(Read8(addr))));
                break;
            case 4u: { // LDR (misaligned: rotate)
                const uint32_t raw = Read32(addr & ~3u);
                cpu_.regs[rd] = (addr & 3u) ? RotateRight(raw, (addr & 3u) * 8u) : raw;
                break;
            }
            case 5u: cpu_.regs[rd] = Read16(addr); break; // LDRH
            case 6u: cpu_.regs[rd] = Read8(addr); break;  // LDRB
            case 7u: // LDRSH: 奇数アドレスは signed byte
                cpu_.regs[rd] = (addr & 1u)
                    ? static_cast<uint32_t>(static_cast<int32_t>(static_cast<int8_t>(Read8(addr))))
                    : static_cast<uint32_t>(static_cast<int32_t>(static_cast<int16_t>(Read16(addr))));
                break;
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── 即値オフセット STR/LDR word (0x6000..0x6FFF) ─────────────────────────
    if ((opcode & 0xF000u) == 0x6000u) {
        const bool load = (opcode & 0x0800u) != 0u;
        const uint32_t imm5 = (opcode >> 6u) & 0x1Fu;
        const uint32_t rn   = (opcode >> 3u) & 0x7u;
        const uint32_t rd   = opcode & 0x7u;
        const uint32_t addr = cpu_.regs[rn] + (imm5 << 2u);
        if (load) {
            const uint32_t raw = Read32(addr & ~3u);
            cpu_.regs[rd] = (addr & 3u) ? RotateRight(raw, (addr & 3u) * 8u) : raw;
        } else {
            Write32(addr, cpu_.regs[rd]);
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── 即値オフセット STRB/LDRB (0x7000..0x7FFF) ────────────────────────────
    if ((opcode & 0xF000u) == 0x7000u) {
        const bool load = (opcode & 0x0800u) != 0u;
        const uint32_t imm5 = (opcode >> 6u) & 0x1Fu;
        const uint32_t rn   = (opcode >> 3u) & 0x7u;
        const uint32_t rd   = opcode & 0x7u;
        const uint32_t addr = cpu_.regs[rn] + imm5;
        if (load) cpu_.regs[rd] = Read8(addr);
        else      Write8(addr, static_cast<uint8_t>(cpu_.regs[rd]));
        cpu_.regs[15] += 2u;
        return;
    }

    // ── 即値オフセット STRH/LDRH (0x8000..0x8FFF) ────────────────────────────
    if ((opcode & 0xF000u) == 0x8000u) {
        const bool load = (opcode & 0x0800u) != 0u;
        const uint32_t imm5 = (opcode >> 6u) & 0x1Fu;
        const uint32_t rn   = (opcode >> 3u) & 0x7u;
        const uint32_t rd   = opcode & 0x7u;
        const uint32_t addr = cpu_.regs[rn] + (imm5 << 1u);
        if (load) cpu_.regs[rd] = Read16(addr);
        else      Write16(addr, static_cast<uint16_t>(cpu_.regs[rd]));
        cpu_.regs[15] += 2u;
        return;
    }

    // ── SP相対 STR/LDR (0x9000..0x9FFF) ──────────────────────────────────────
    if ((opcode & 0xF000u) == 0x9000u) {
        const bool load = (opcode & 0x0800u) != 0u;
        const uint32_t rd  = (opcode >> 8u) & 0x7u;
        const uint32_t imm = (opcode & 0xFFu) << 2u;
        const uint32_t addr = cpu_.regs[13] + imm;
        if (load) {
            const uint32_t raw = Read32(addr & ~3u);
            cpu_.regs[rd] = (addr & 3u) ? RotateRight(raw, (addr & 3u) * 8u) : raw;
        } else {
            Write32(addr, cpu_.regs[rd]);
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── ADD Rd, PC/SP, #imm8*4 (0xA000..0xAFFF) ──────────────────────────────
    if ((opcode & 0xF000u) == 0xA000u) {
        const bool use_sp = (opcode & 0x0800u) != 0u;
        const uint32_t rd  = (opcode >> 8u) & 0x7u;
        const uint32_t imm = (opcode & 0xFFu) << 2u;
        // PC相対: (execute_addr + 4) & ~3
        const uint32_t base = use_sp ? cpu_.regs[13] : ((cpu_.regs[15] + 4u) & ~3u);
        cpu_.regs[rd] = base + imm;
        cpu_.regs[15] += 2u;
        return;
    }

    // ── ADD/SUB SP, #imm7*4 (0xB000..0xB0FF) ─────────────────────────────────
    if ((opcode & 0xFF00u) == 0xB000u) {
        const uint32_t imm = (opcode & 0x7Fu) << 2u;
        if (opcode & 0x80u) cpu_.regs[13] -= imm;
        else                cpu_.regs[13] += imm;
        cpu_.regs[15] += 2u;
        return;
    }

    // ── PUSH (0xB400..0xB5FF) ────────────────────────────────────────────────
    if ((opcode & 0xFE00u) == 0xB400u) {
        uint32_t rlist = opcode & 0xFFu;
        if (opcode & 0x0100u) rlist |= (1u << 14u); // LR
        // 降順書き込み (r15 から r0 へ)
        for (int r = 15; r >= 0; --r) {
            if ((rlist & (1u << r)) == 0u) continue;
            cpu_.regs[13] -= 4u;
            Write32(cpu_.regs[13], cpu_.regs[r]);
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── POP (0xBC00..0xBDFF) ─────────────────────────────────────────────────
    if ((opcode & 0xFE00u) == 0xBC00u) {
        uint32_t rlist = opcode & 0xFFu;
        const bool pop_pc = (opcode & 0x0100u) != 0u;
        if (pop_pc) rlist |= (1u << 15u);
        for (uint32_t r = 0u; r < 16u; ++r) {
            if ((rlist & (1u << r)) == 0u) continue;
            cpu_.regs[r] = Read32(cpu_.regs[13]);
            cpu_.regs[13] += 4u;
        }
        if (pop_pc) {
            cpu_.regs[15] &= ~1u;
            return; // no += 2
        }
        cpu_.regs[15] += 2u;
        return;
    }

    // ── STMIA (0xC000..0xC7FF) ───────────────────────────────────────────────
    if ((opcode & 0xF800u) == 0xC000u) {
        const uint32_t rn    = (opcode >> 8u) & 0x7u;
        const uint32_t rlist = opcode & 0xFFu;
        uint32_t addr = cpu_.regs[rn];
        if (rlist == 0u) {
            // ARM7TDMI quirk: empty list stores PC+4
            Write32(addr, cpu_.regs[15] + 2u);
            cpu_.regs[rn] += 0x40u;
            cpu_.regs[15] += 2u;
            return;
        }
        for (uint32_t r = 0u; r < 8u; ++r) {
            if ((rlist & (1u << r)) == 0u) continue;
            Write32(addr, cpu_.regs[r]);
            addr += 4u;
        }
        cpu_.regs[rn] = addr;
        cpu_.regs[15] += 2u;
        return;
    }

    // ── LDMIA (0xC800..0xCFFF) ───────────────────────────────────────────────
    if ((opcode & 0xF800u) == 0xC800u) {
        const uint32_t rn    = (opcode >> 8u) & 0x7u;
        const uint32_t rlist = opcode & 0xFFu;
        uint32_t addr = cpu_.regs[rn];
        if (rlist == 0u) {
            // ARM7TDMI quirk: empty list loads PC
            cpu_.regs[15] = Read32(addr) & ~1u;
            cpu_.regs[rn] += 0x40u;
            return;
        }
        for (uint32_t r = 0u; r < 8u; ++r) {
            if ((rlist & (1u << r)) == 0u) continue;
            cpu_.regs[r] = Read32(addr);
            addr += 4u;
        }
        // Rn がリストに含まれない場合のみライトバック
        if ((rlist & (1u << rn)) == 0u) cpu_.regs[rn] = addr;
        cpu_.regs[15] += 2u;
        return;
    }

    // 未処理命令 → 未定義
    HandleUndefinedInstruction(true);
}

} // namespace gba
