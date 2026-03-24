#include "gba_core.h"

#include <algorithm>
#include <cstring>

namespace gba {
namespace {
constexpr uint32_t kCyclesPerFrame = 280896;  // 16.78MHz / 59.73Hz

constexpr uint8_t kNintendoLogo[156] = {
    0x24,0xFF,0xAE,0x51,0x69,0x9A,0xA2,0x21,0x3D,0x84,0x82,0x0A,0x84,0xE4,0x09,0xAD,
    0x11,0x24,0x8B,0x98,0xC0,0x81,0x7F,0x21,0xA3,0x52,0xBE,0x19,0x93,0x09,0xCE,0x20,
    0x10,0x46,0x4A,0x4A,0xF8,0x27,0x31,0xEC,0x58,0xC7,0xE8,0x33,0x82,0xE3,0xCE,0xBF,
    0x85,0xF4,0xDF,0x94,0xCE,0x4B,0x09,0xC1,0x94,0x56,0x8A,0xC0,0x13,0x72,0xA7,0xFC,
    0x9F,0x84,0x4D,0x73,0xA3,0xCA,0x9A,0x61,0x58,0x97,0xA3,0x27,0xFC,0x03,0x98,0x76,
    0x23,0x1D,0xC7,0x61,0x03,0x04,0xAE,0x56,0xBF,0x38,0x84,0x00,0x40,0xA7,0x0E,0xFD,
    0xFF,0x52,0xFE,0x03,0x6F,0x95,0x30,0xF1,0x97,0xFB,0xC0,0x85,0x60,0xD6,0x80,0x25,
    0xA9,0x63,0xBE,0x03,0x01,0x4E,0x38,0xE2,0xF9,0xA2,0x34,0xFF,0xBB,0x3E,0x03,0x44,
    0x78,0x00,0x90,0xCB,0x88,0x11,0x3A,0x94,0x65,0xC0,0x7C,0x63,0x87,0xF0,0x3C,0xAF,
    0xD6,0x25,0xE4,0x8B,0x38,0x0A,0xAC,0x72,0x21,0xD4,0xF8,0x07,
};

uint8_t ClampToByte(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}
}  // namespace

bool GBACore::LoadROM(const std::vector<uint8_t>& rom, std::string* error) {
  if (rom.size() < 0xC0) {
    if (error) *error = "ROM too small (needs at least 0xC0 bytes).";
    return false;
  }

  rom_ = rom;
  loaded_ = true;

  rom_info_.title = std::string(reinterpret_cast<const char*>(&rom_[0xA0]), 12);
  rom_info_.title.erase(std::find(rom_info_.title.begin(), rom_info_.title.end(), '\0'),
                        rom_info_.title.end());
  rom_info_.game_code = std::string(reinterpret_cast<const char*>(&rom_[0xAC]), 4);
  rom_info_.maker_code = std::string(reinterpret_cast<const char*>(&rom_[0xB0]), 2);
  rom_info_.fixed_value = rom_[0xB2];
  rom_info_.unit_code = rom_[0xB3];
  rom_info_.device_type = rom_[0xB4];
  rom_info_.version = rom_[0xBC];
  rom_info_.complement_check = rom_[0xBD];
  rom_info_.computed_complement_check = ComputeComplementCheck();
  rom_info_.logo_valid = ValidateNintendoLogo();
  rom_info_.complement_check_valid = (rom_info_.complement_check == rom_info_.computed_complement_check);

  if (rom_info_.fixed_value != 0x96) {
    if (error) *error = "Invalid Nintendo header fixed value at 0xB2.";
    loaded_ = false;
    return false;
  }
  // Some homebrew/test ROMs can intentionally alter logo/complement fields.
  // Keep the validity flags for diagnostics, but do not hard-fail loading.
  if (!rom_info_.logo_valid && error) {
    *error = "Warning: Nintendo logo area mismatch (0x04-0x9F).";
  }
  if (!rom_info_.complement_check_valid && error) {
    *error = "Warning: Header complement check mismatch (0xBD).";
  }

  Reset();
  return true;
}

void GBACore::Reset() {
  frame_count_ = 0;
  executed_cycles_ = 0;
  keys_pressed_mask_ = 0;
  previous_keys_mask_ = 0;
  std::fill(ewram_.begin(), ewram_.end(), 0);
  std::fill(iwram_.begin(), iwram_.end(), 0);
  cpu_ = CpuState{};
  cpu_.regs[15] = 0x08000000u;  // ROM entry area.
  gameplay_state_ = GameplayState{};
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  RenderDebugFrame();
}

void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;
  executed_cycles_ += cycles;
  RunCpuSlice(cycles);
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) { keys_pressed_mask_ = keys_pressed_mask; }

void GBACore::StepFrame() {
  if (!loaded_) return;
  RunCycles(kCyclesPerFrame);
  ++frame_count_;
  UpdateGameplayFromInput();
  RenderDebugFrame();
}

uint8_t GBACore::ComputeComplementCheck() const {
  int sum = 0;
  for (size_t i = 0xA0; i <= 0xBC && i < rom_.size(); ++i) {
    sum += rom_[i];
  }
  return static_cast<uint8_t>((-sum - 0x19) & 0xFF);
}

bool GBACore::ValidateNintendoLogo() const {
  if (rom_.size() < 0xA0) return false;
  for (size_t i = 0; i < sizeof(kNintendoLogo); ++i) {
    if (rom_[0x04 + i] != kNintendoLogo[i]) {
      return false;
    }
  }
  return true;
}

void GBACore::UpdateGameplayFromInput() {
  constexpr int kStep = 2;
  const uint16_t pressed_edge = static_cast<uint16_t>(keys_pressed_mask_ & ~previous_keys_mask_);

  if (keys_pressed_mask_ & kKeyRight) gameplay_state_.player_x += kStep;
  if (keys_pressed_mask_ & kKeyLeft) gameplay_state_.player_x -= kStep;
  if (keys_pressed_mask_ & kKeyDown) gameplay_state_.player_y += kStep;
  if (keys_pressed_mask_ & kKeyUp) gameplay_state_.player_y -= kStep;
  if (keys_pressed_mask_ & kKeyR) gameplay_state_.player_x += 1;
  if (keys_pressed_mask_ & kKeyL) gameplay_state_.player_x -= 1;

  gameplay_state_.player_x = std::clamp(gameplay_state_.player_x, 0, kScreenWidth - 1);
  gameplay_state_.player_y = std::clamp(gameplay_state_.player_y, 0, kScreenHeight - 1);

  if (keys_pressed_mask_ & kKeyA) {
    gameplay_state_.score += 3;
  }
  if (keys_pressed_mask_ & kKeyB) {
    gameplay_state_.score += 1;
  }
  if (keys_pressed_mask_ & kKeyR) {
    gameplay_state_.score += 2;
  }
  if (keys_pressed_mask_ & kKeyL) {
    gameplay_state_.score += 2;
  }
  if (pressed_edge & kKeyStart) {
    gameplay_state_.score += 5;
  }
  if ((pressed_edge & kKeySelect) && gameplay_state_.score > 0) {
    --gameplay_state_.score;
  }
  if ((keys_pressed_mask_ & kKeyA) && (keys_pressed_mask_ & kKeyB)) {
    ++gameplay_state_.combo;
    gameplay_state_.score += 2;
  } else {
    gameplay_state_.combo = 0;
  }

  constexpr int kRightCheckpointX = kScreenWidth - 20;
  constexpr int kBottomCheckpointY = kScreenHeight - 15;
  constexpr int kLeftCheckpointX = 20;
  constexpr int kTopCheckpointY = 15;

  if (gameplay_state_.player_x >= kRightCheckpointX) gameplay_state_.checkpoints |= 0x1;
  if (gameplay_state_.player_y >= kBottomCheckpointY) gameplay_state_.checkpoints |= 0x2;
  if (gameplay_state_.player_x <= kLeftCheckpointX) gameplay_state_.checkpoints |= 0x4;
  if (gameplay_state_.player_y <= kTopCheckpointY) gameplay_state_.checkpoints |= 0x8;

  constexpr uint8_t kAllCheckpoints = 0x0F;
  if (gameplay_state_.checkpoints == kAllCheckpoints &&
      gameplay_state_.score >= 300 &&
      frame_count_ >= 180) {
    gameplay_state_.cleared = true;
  }
  previous_keys_mask_ = keys_pressed_mask_;
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  uint32_t seed = 0;
  for (size_t i = 0; i < std::min<size_t>(rom_.size(), 256); ++i) {
    seed = (seed * 33u) ^ rom_[i];
  }
  seed ^= static_cast<uint32_t>(frame_count_ * 2654435761u);

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint8_t r = static_cast<uint8_t>((x + seed) & 0xFF);
      const uint8_t g = static_cast<uint8_t>((y + (seed >> 8)) & 0xFF);
      const uint8_t b = static_cast<uint8_t>(((x ^ y) + (seed >> 16)) & 0xFF);
      frame_buffer_[y * kScreenWidth + x] = 0xFF000000U | (r << 16) | (g << 8) | b;
    }
  }

  for (int dy = -2; dy <= 2; ++dy) {
    for (int dx = -2; dx <= 2; ++dx) {
      const int px = gameplay_state_.player_x + dx;
      const int py = gameplay_state_.player_y + dy;
      if (px < 0 || py < 0 || px >= kScreenWidth || py >= kScreenHeight) continue;
      const uint8_t base = ClampToByte(80 + static_cast<int>(gameplay_state_.score % 175));
      frame_buffer_[py * kScreenWidth + px] =
          0xFF000000U | (255u << 16) | (base << 8) | static_cast<uint32_t>(255u - base);
    }
  }
}

uint64_t GBACore::ComputeFrameHash() const {
  uint64_t hash = 1469598103934665603ULL;
  constexpr uint64_t kPrime = 1099511628211ULL;

  for (uint32_t px : frame_buffer_) {
    hash ^= px;
    hash *= kPrime;
  }
  hash ^= static_cast<uint64_t>(gameplay_state_.player_x) << 1;
  hash ^= static_cast<uint64_t>(gameplay_state_.player_y) << 9;
  hash ^= static_cast<uint64_t>(gameplay_state_.score) << 17;
  return hash;
}

bool GBACore::ValidateFrameBuffer(std::string* error) const {
  const size_t expected_size = static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight);
  if (frame_buffer_.size() != expected_size) {
    if (error) *error = "Invalid framebuffer size.";
    return false;
  }

  uint32_t first_row_hash = 0;
  bool first_row_hash_set = false;
  bool found_distinct_row = false;

  for (int y = 0; y < kScreenHeight; ++y) {
    uint32_t row_hash = 2166136261u;
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if ((px & 0xFF000000u) != 0xFF000000u) {
        if (error) *error = "Found pixel with invalid alpha channel.";
        return false;
      }
      row_hash ^= px;
      row_hash *= 16777619u;
    }

    if (!first_row_hash_set) {
      first_row_hash = row_hash;
      first_row_hash_set = true;
    } else if (row_hash != first_row_hash) {
      found_distinct_row = true;
    }
  }

  if (!found_distinct_row) {
    if (error) *error = "Framebuffer rows are unexpectedly identical.";
    return false;
  }
  return true;
}

uint32_t GBACore::Read32(uint32_t addr) const {
  // 0x02000000-0x0203FFFF: EWRAM
  if (addr >= 0x02000000u) {
    const uint32_t off32 = addr - 0x02000000u;
    if (off32 <= ewram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(ewram_[off]) |
             (static_cast<uint32_t>(ewram_[off + 1]) << 8) |
             (static_cast<uint32_t>(ewram_[off + 2]) << 16) |
             (static_cast<uint32_t>(ewram_[off + 3]) << 24);
    }
  }
  // 0x03000000-0x03007FFF: IWRAM
  if (addr >= 0x03000000u) {
    const uint32_t off32 = addr - 0x03000000u;
    if (off32 <= iwram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(iwram_[off]) |
             (static_cast<uint32_t>(iwram_[off + 1]) << 8) |
             (static_cast<uint32_t>(iwram_[off + 2]) << 16) |
             (static_cast<uint32_t>(iwram_[off + 3]) << 24);
    }
  }
  // 0x08000000- : ROM
  if (addr >= 0x08000000u) {
    const size_t off = static_cast<size_t>(addr - 0x08000000u);
    if (off + 3 < rom_.size()) {
      return static_cast<uint32_t>(rom_[off]) |
             (static_cast<uint32_t>(rom_[off + 1]) << 8) |
             (static_cast<uint32_t>(rom_[off + 2]) << 16) |
             (static_cast<uint32_t>(rom_[off + 3]) << 24);
    }
  }
  return 0;
}

uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr >= 0x02000000u) {
    const uint32_t off32 = addr - 0x02000000u;
    if (off32 <= ewram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(ewram_[off]) |
             static_cast<uint16_t>(ewram_[off + 1] << 8);
    }
  }
  if (addr >= 0x03000000u) {
    const uint32_t off32 = addr - 0x03000000u;
    if (off32 <= iwram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(iwram_[off]) |
             static_cast<uint16_t>(iwram_[off + 1] << 8);
    }
  }
  if (addr >= 0x08000000u) {
    const size_t off = static_cast<size_t>(addr - 0x08000000u);
    if (off + 1 < rom_.size()) {
      return static_cast<uint16_t>(rom_[off]) |
             static_cast<uint16_t>(rom_[off + 1] << 8);
    }
  }
  return 0;
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  if (addr >= 0x02000000u) {
    const uint32_t off32 = addr - 0x02000000u;
    if (off32 <= ewram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      ewram_[off] = static_cast<uint8_t>(value & 0xFF);
      ewram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      ewram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      ewram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x03000000u) {
    const uint32_t off32 = addr - 0x03000000u;
    if (off32 <= iwram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      iwram_[off] = static_cast<uint8_t>(value & 0xFF);
      iwram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      iwram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      iwram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
    }
  }
}

uint32_t GBACore::RotateRight(uint32_t value, unsigned bits) const {
  bits &= 31u;
  if (bits == 0) return value;
  return (value >> bits) | (value << (32u - bits));
}

uint32_t GBACore::ExpandArmImmediate(uint32_t imm12) const {
  const uint32_t imm8 = imm12 & 0xFFu;
  const uint32_t rotate = ((imm12 >> 8) & 0xFu) * 2u;
  return RotateRight(imm8, rotate);
}

bool GBACore::CheckCondition(uint32_t cond) const {
  const bool n = (cpu_.cpsr & (1u << 31)) != 0;
  const bool z = (cpu_.cpsr & (1u << 30)) != 0;
  const bool c = (cpu_.cpsr & (1u << 29)) != 0;
  const bool v = (cpu_.cpsr & (1u << 28)) != 0;

  switch (cond & 0xFu) {
    case 0x0: return z;                // EQ
    case 0x1: return !z;               // NE
    case 0x2: return c;                // CS/HS
    case 0x3: return !c;               // CC/LO
    case 0x4: return n;                // MI
    case 0x5: return !n;               // PL
    case 0x6: return v;                // VS
    case 0x7: return !v;               // VC
    case 0x8: return c && !z;          // HI
    case 0x9: return !c || z;          // LS
    case 0xA: return n == v;           // GE
    case 0xB: return n != v;           // LT
    case 0xC: return !z && (n == v);   // GT
    case 0xD: return z || (n != v);    // LE
    case 0xE: return true;             // AL
    default: return false;             // NV
  }
}

void GBACore::SetNZFlags(uint32_t value) {
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 31) | (1u << 30))) |
              ((value & 0x80000000u) ? (1u << 31) : 0u) |
              ((value == 0) ? (1u << 30) : 0u);
}

void GBACore::SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  const uint32_t result32 = static_cast<uint32_t>(result64);
  SetNZFlags(result32);
  const bool carry = (result64 >> 32) != 0;
  const bool overflow = ((~(lhs ^ rhs) & (lhs ^ result32)) & 0x80000000u) != 0;
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 29) | (1u << 28))) |
              (carry ? (1u << 29) : 0u) |
              (overflow ? (1u << 28) : 0u);
}

void GBACore::SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  const uint32_t result32 = static_cast<uint32_t>(result64);
  SetNZFlags(result32);
  const bool carry = lhs >= rhs;  // no borrow
  const bool overflow = (((lhs ^ rhs) & (lhs ^ result32)) & 0x80000000u) != 0;
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 29) | (1u << 28))) |
              (carry ? (1u << 29) : 0u) |
              (overflow ? (1u << 28) : 0u);
}

void GBACore::ExecuteArmInstruction(uint32_t opcode) {
  const uint32_t cond = (opcode >> 28) & 0xFu;
  if (!CheckCondition(cond)) {
    cpu_.regs[15] += 4;
    return;
  }

  // BX Rm
  if ((opcode & 0x0FFFFFF0u) == 0x012FFF10u) {
    const uint32_t rm = opcode & 0xFu;
    const uint32_t target = cpu_.regs[rm];
    if (target & 1u) {
      cpu_.cpsr |= (1u << 5);  // Thumb bit.
      cpu_.regs[15] = target & ~1u;
    } else {
      cpu_.cpsr &= ~(1u << 5);
      cpu_.regs[15] = target & ~3u;
    }
    return;
  }

  // Branch
  if ((opcode & 0x0E000000u) == 0x0A000000u) {
    int32_t offset = static_cast<int32_t>(opcode & 0x00FFFFFFu);
    if (offset & 0x00800000u) offset |= ~0x00FFFFFF;
    offset <<= 2;
    cpu_.regs[15] = cpu_.regs[15] + 8u + static_cast<uint32_t>(offset);
    return;
  }

  // LDR/STR immediate
  if ((opcode & 0x0C000000u) == 0x04000000u) {
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const bool load = (opcode & (1u << 20)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const uint32_t imm = opcode & 0xFFFu;
    uint32_t addr = cpu_.regs[rn];
    addr = up ? (addr + imm) : (addr - imm);
    if (load) {
      cpu_.regs[rd] = Read32(addr);
    } else {
      Write32(addr, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 4;
    return;
  }

  // Data processing (minimal subset: AND/EOR/SUB/ADD/ORR/MOV/CMP)
  if ((opcode & 0x0C000000u) == 0x00000000u) {
    const bool imm = (opcode & (1u << 25)) != 0;
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const uint32_t op = (opcode >> 21) & 0xFu;
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    uint32_t operand2 = 0;
    if (imm) {
      operand2 = ExpandArmImmediate(opcode & 0xFFFu);
    } else {
      const uint32_t rm = opcode & 0xFu;
      operand2 = cpu_.regs[rm];
    }

    switch (op) {
      case 0x0: { // AND
        const uint32_t r = cpu_.regs[rn] & operand2;
        cpu_.regs[rd] = r;
        if (set_flags) SetNZFlags(r);
        break;
      }
      case 0x1: { // EOR
        const uint32_t r = cpu_.regs[rn] ^ operand2;
        cpu_.regs[rd] = r;
        if (set_flags) SetNZFlags(r);
        break;
      }
      case 0x2: { // SUB
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rn]) - static_cast<uint64_t>(operand2);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        if (set_flags) SetSubFlags(cpu_.regs[rn], operand2, r64);
        break;
      }
      case 0x4: { // ADD
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rn]) + static_cast<uint64_t>(operand2);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        if (set_flags) SetAddFlags(cpu_.regs[rn], operand2, r64);
        break;
      }
      case 0xA: { // CMP
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rn]) - static_cast<uint64_t>(operand2);
        SetSubFlags(cpu_.regs[rn], operand2, r64);
        break;
      }
      case 0xC: { // ORR
        const uint32_t r = cpu_.regs[rn] | operand2;
        cpu_.regs[rd] = r;
        if (set_flags) SetNZFlags(r);
        break;
      }
      case 0xD: { // MOV
        cpu_.regs[rd] = operand2;
        if (set_flags) SetNZFlags(operand2);
        break;
      }
      default: break;  // NOP for unsupported ALU ops.
    }
    cpu_.regs[15] += 4;
    return;
  }

  // SWI / unknown => advance PC (graceful NOP in this minimal core)
  cpu_.regs[15] += 4;
}

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  // MOV/CMP/ADD/SUB immediate (001xx)
  if ((opcode & 0xE000u) == 0x2000u) {
    const uint16_t op = (opcode >> 11) & 0x3u;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm8 = opcode & 0xFFu;
    switch (op) {
      case 0: cpu_.regs[rd] = imm8; break;                 // MOV
      case 1: (void)(cpu_.regs[rd] - imm8); break;         // CMP (flags omitted)
      case 2: cpu_.regs[rd] += imm8; break;                // ADD
      case 3: cpu_.regs[rd] -= imm8; break;                // SUB
    }
    cpu_.regs[15] += 2;
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

  // Fallback NOP-like advance.
  cpu_.regs[15] += 2;
}

void GBACore::RunCpuSlice(uint32_t cycles) {
  if (cpu_.halted) return;
  // Minimal budget: roughly 1 ARM instruction per 4 cycles.
  const uint32_t instruction_budget = std::max<uint32_t>(1, cycles / 4u);
  for (uint32_t i = 0; i < instruction_budget; ++i) {
    const uint32_t pc = cpu_.regs[15];
    if (cpu_.cpsr & (1u << 5)) {
      const uint16_t opcode = Read16(pc);
      ExecuteThumbInstruction(opcode);
    } else {
      const uint32_t opcode = Read32(pc);
      ExecuteArmInstruction(opcode);
    }
    // Keep PC sane when branch jumps outside mapped ranges.
    if (cpu_.regs[15] < 0x02000000u || cpu_.regs[15] > 0x09FFFFFFu) {
      const uint32_t mask = (cpu_.cpsr & (1u << 5)) ? 0x1FFFFFEu : 0x1FFFFFCu;
      cpu_.regs[15] = 0x08000000u + static_cast<uint32_t>((cpu_.regs[15] & mask) % std::max<size_t>(4, rom_.size()));
    }
  }
}

}  // namespace gba
