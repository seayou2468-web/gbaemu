#include <filesystem>
#include <cctype>
#include <array>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "../../core/gba_core.h"
#include "../../core/rom_loader.h"

namespace fs = std::filesystem;

std::vector<uint8_t> MakeMinimalRomWithSaveTag(const std::string& tag) {
  std::vector<uint8_t> rom(0x400, 0);
  rom[0xB2] = 0x96;  // required fixed value
  for (size_t i = 0; i < tag.size() && (0xC0 + i) < rom.size(); ++i) {
    rom[0xC0 + i] = static_cast<uint8_t>(tag[i]);
  }
  return rom;
}

bool FlashUnlock(gba::GBACore* core) {
  if (!core) return false;
  core->DebugWrite8(0x0E005555u, 0xAAu);
  core->DebugWrite8(0x0E002AAAu, 0x55u);
  return true;
}

int RunBackupControllerSelfTest() {
  int fail = 0;

  {
    gba::GBACore flash;
    std::string error;
    std::vector<uint8_t> rom = MakeMinimalRomWithSaveTag("FLASH512_V131");
    if (!flash.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] backup_selftest flash load: " << error << "\n";
      return 10;
    }

    // Enter flash ID mode.
    FlashUnlock(&flash);
    flash.DebugWrite8(0x0E005555u, 0x90u);
    const uint8_t id0 = flash.DebugRead8(0x0E000000u);
    const uint8_t id1 = flash.DebugRead8(0x0E000001u);
    const bool id_ok = (id0 == 0xBFu) && (id1 == 0xD4u);
    std::cout << "[SELFTEST] flash id: " << std::hex << static_cast<int>(id0)
              << " " << static_cast<int>(id1) << std::dec
              << " pass=" << id_ok << "\n";
    if (!id_ok) ++fail;

    // Exit ID mode.
    FlashUnlock(&flash);
    flash.DebugWrite8(0x0E005555u, 0xF0u);

    // Program byte via A0 sequence.
    FlashUnlock(&flash);
    flash.DebugWrite8(0x0E005555u, 0xA0u);
    flash.DebugWrite8(0x0E000123u, 0x3Cu);
    const bool program_ok = flash.DebugRead8(0x0E000123u) == 0x3Cu;
    std::cout << "[SELFTEST] flash program pass=" << program_ok << "\n";
    if (!program_ok) ++fail;

    // Sector erase sequence.
    FlashUnlock(&flash);
    flash.DebugWrite8(0x0E005555u, 0x80u);
    FlashUnlock(&flash);
    flash.DebugWrite8(0x0E000000u + 0x123u, 0x30u);
    const bool erase_ok = flash.DebugRead8(0x0E000123u) == 0xFFu;
    std::cout << "[SELFTEST] flash sector erase pass=" << erase_ok << "\n";
    if (!erase_ok) ++fail;
  }

  {
    gba::GBACore flash1m;
    std::string error;
    std::vector<uint8_t> rom = MakeMinimalRomWithSaveTag("FLASH1M_V103");
    if (!flash1m.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] backup_selftest flash1m load: " << error << "\n";
      return 13;
    }

    // Program bank0.
    FlashUnlock(&flash1m);
    flash1m.DebugWrite8(0x0E005555u, 0xA0u);
    flash1m.DebugWrite8(0x0E000042u, 0x12u);

    // Switch to bank1: AA 55 B0 then write bank index to 0x0000.
    FlashUnlock(&flash1m);
    flash1m.DebugWrite8(0x0E005555u, 0xB0u);
    flash1m.DebugWrite8(0x0E000000u, 0x01u);

    FlashUnlock(&flash1m);
    flash1m.DebugWrite8(0x0E005555u, 0xA0u);
    flash1m.DebugWrite8(0x0E000042u, 0x34u);
    const bool bank1_ok = flash1m.DebugRead8(0x0E000042u) == 0x34u;

    // Back to bank0 and verify data differs.
    FlashUnlock(&flash1m);
    flash1m.DebugWrite8(0x0E005555u, 0xB0u);
    flash1m.DebugWrite8(0x0E000000u, 0x00u);
    const bool bank0_ok = flash1m.DebugRead8(0x0E000042u) == 0x12u;

    const bool flash1m_ok = bank0_ok && bank1_ok;
    std::cout << "[SELFTEST] flash1m bank switch pass=" << flash1m_ok << "\n";
    if (!flash1m_ok) ++fail;
  }

  {
    gba::GBACore sram;
    std::string error;
    std::vector<uint8_t> rom = MakeMinimalRomWithSaveTag("SRAM_V113");
    if (!sram.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] backup_selftest sram load: " << error << "\n";
      return 11;
    }

    sram.DebugWrite8(0x0E000011u, 0x77u);
    const bool sram_ok = sram.DebugRead8(0x0E000011u) == 0x77u;
    std::cout << "[SELFTEST] sram rw pass=" << sram_ok << "\n";
    if (!sram_ok) ++fail;
  }

  std::cout << "BackupControllerSelfTest Summary: fail=" << fail << "\n";
  return fail == 0 ? 0 : 12;
}

int RunBatchTest(const std::string& rom_dir) {
  if (!fs::exists(rom_dir)) {
    std::cerr << "ROM directory not found: " << rom_dir << "\n";
    return 1;
  }

  int ok = 0;
  int fail = 0;

  for (const auto& entry : fs::directory_iterator(rom_dir)) {
    if (!entry.is_regular_file() || entry.path().extension() != ".gba") continue;

    std::vector<uint8_t> rom;
    std::string error;
    if (!gba::LoadFile(entry.path().string(), &rom, &error)) {
      std::cerr << "[FAIL] " << entry.path().filename().string() << " : " << error << "\n";
      ++fail;
      continue;
    }

    gba::GBACore core;
    if (!core.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] " << entry.path().filename().string() << " : " << error << "\n";
      ++fail;
      continue;
    }

    for (int i = 0; i < 5; ++i) {
      core.StepFrame();
    }

    const auto& info = core.GetRomInfo();
    std::cout << "[OK] " << entry.path().filename().string() << " title='" << info.title
              << "' code='" << info.game_code << "' frames=" << core.frame_count()
              << " cycles=" << core.executed_cycles() << " hash=" << core.ComputeFrameHash()
              << " logo=" << info.logo_valid << " hdrchk=" << info.complement_check_valid
              << "\n";
    ++ok;
  }

  std::cout << "Summary: ok=" << ok << " fail=" << fail << "\n";
  return fail == 0 ? 0 : 2;
}

int RunGameplayTest(const std::string& rom_path) {
  std::vector<uint8_t> rom;
  std::string error;

  if (!gba::LoadFile(rom_path, &rom, &error)) {
    std::cerr << "Gameplay test ROM load failed: " << error << "\n";
    return 1;
  }

  gba::GBACore core;
  if (!core.LoadROM(rom, &error)) {
    std::cerr << "Gameplay test core load failed: " << error << "\n";
    return 2;
  }

  const auto before = core.gameplay_state();
  const auto hash_before = core.ComputeFrameHash();

  for (int i = 0; i < 30; ++i) {
    core.SetKeys(gba::kKeyRight | gba::kKeyA);
    core.StepFrame();
  }
  for (int i = 0; i < 15; ++i) {
    core.SetKeys(gba::kKeyDown | gba::kKeyB);
    core.StepFrame();
  }
  for (int i = 0; i < 10; ++i) {
    core.SetKeys(gba::kKeyLeft);
    core.StepFrame();
  }
  core.SetKeys(0);
  core.StepFrame();

  const auto after = core.gameplay_state();
  const auto hash_after = core.ComputeFrameHash();

  const bool moved = (after.player_x != before.player_x) || (after.player_y != before.player_y);
  const bool scored = after.score > before.score;
  const bool frame_changed = hash_before != hash_after;

  std::cout << "GameplayTest ROM='" << rom_path << "'\n"
            << "  before: x=" << before.player_x << " y=" << before.player_y
            << " score=" << before.score << " hash=" << hash_before << "\n"
            << "  after : x=" << after.player_x << " y=" << after.player_y
            << " score=" << after.score << " hash=" << hash_after << "\n"
            << "  checks: moved=" << moved << " scored=" << scored
            << " frame_changed=" << frame_changed << "\n";

  if (moved && scored && frame_changed) {
    std::cout << "GameplayTest: PASS\n";
    return 0;
  }

  std::cout << "GameplayTest: FAIL\n";
  return 3;
}

int RunMainlineRegression(const std::string& rom_dir) {
  static constexpr std::array<const char*, 7> kMainlineRoms = {
      "test1.gba", "test2.gba", "test3.gba", "test4.gba", "test5.gba", "test6.gba", "test7.gba",
  };

  int ok = 0;
  int fail = 0;
  std::cout << "MainlineRegression dir='" << rom_dir << "'\n";

  for (const char* file_name : kMainlineRoms) {
    const fs::path rom_path = fs::path(rom_dir) / file_name;
    if (!fs::exists(rom_path)) {
      std::cerr << "[FAIL] " << file_name << " : ROM file not found.\n";
      ++fail;
      continue;
    }

    std::vector<uint8_t> rom;
    std::string error;
    if (!gba::LoadFile(rom_path.string(), &rom, &error)) {
      std::cerr << "[FAIL] " << file_name << " : load failed: " << error << "\n";
      ++fail;
      continue;
    }

    gba::GBACore core;
    if (!core.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] " << file_name << " : core load failed: " << error << "\n";
      ++fail;
      continue;
    }
    error.clear();

    const auto hash_before = core.ComputeFrameHash();
    const auto state_before = core.gameplay_state();
    for (int i = 0; i < 60; ++i) {
      core.SetKeys(gba::kKeyRight | gba::kKeyA);
      core.StepFrame();
    }
    for (int i = 0; i < 60; ++i) {
      core.SetKeys(gba::kKeyDown | gba::kKeyB);
      core.StepFrame();
    }
    core.SetKeys(0);
    core.StepFrame();

    const auto hash_after = core.ComputeFrameHash();
    const auto state_after = core.gameplay_state();
    const auto& info = core.GetRomInfo();
    const bool frame_advanced = core.frame_count() == 121;
    const bool cycles_advanced = core.executed_cycles() == 121ULL * 280896ULL;
    const bool frame_changed = hash_before != hash_after;
    const bool state_changed =
        (state_before.player_x != state_after.player_x) ||
        (state_before.player_y != state_after.player_y) ||
        (state_before.score != state_after.score);

    const bool pass = frame_advanced && cycles_advanced && frame_changed && state_changed;
    std::cout << "[" << (pass ? "OK" : "FAIL") << "] " << file_name
              << " title='" << info.title << "' code='" << info.game_code
              << "' frame_count=" << core.frame_count()
              << " cycles=" << core.executed_cycles()
              << " score=" << state_after.score
              << " hash_before=" << hash_before
              << " hash_after=" << hash_after
              << " header_logo=" << info.logo_valid
              << " header_chk=" << info.complement_check_valid << "\n";
    if (pass) {
      ++ok;
    } else {
      ++fail;
    }
  }

  std::cout << "MainlineRegression Summary: ok=" << ok << " fail=" << fail << "\n";
  return fail == 0 ? 0 : 5;
}

int RunMainlinePlaythrough(const std::string& rom_dir) {
  static constexpr std::array<const char*, 7> kMainlineRoms = {
      "test1.gba", "test2.gba", "test3.gba", "test4.gba", "test5.gba", "test6.gba", "test7.gba",
  };

  struct Phase {
    int frames;
    uint16_t keys;
  };
  static constexpr std::array<Phase, 5> kPlaybook = {{
      {80, gba::kKeyRight | gba::kKeyA},
      {50, gba::kKeyDown | gba::kKeyB},
      {120, gba::kKeyLeft | gba::kKeyA},
      {80, gba::kKeyUp | gba::kKeyB},
      {40, gba::kKeyRight | gba::kKeyA | gba::kKeyB},
  }};

  int ok = 0;
  int fail = 0;
  std::cout << "MainlinePlaythrough dir='" << rom_dir << "'\n";

  for (const char* file_name : kMainlineRoms) {
    const fs::path rom_path = fs::path(rom_dir) / file_name;
    std::vector<uint8_t> rom;
    std::string error;

    if (!fs::exists(rom_path)) {
      std::cerr << "[FAIL] " << file_name << " : ROM file not found.\n";
      ++fail;
      continue;
    }
    if (!gba::LoadFile(rom_path.string(), &rom, &error)) {
      std::cerr << "[FAIL] " << file_name << " : load failed: " << error << "\n";
      ++fail;
      continue;
    }

    gba::GBACore core;
    if (!core.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] " << file_name << " : core load failed: " << error << "\n";
      ++fail;
      continue;
    }
    error.clear();

    const uint64_t hash_before = core.ComputeFrameHash();
    const auto state_before = core.gameplay_state();
    for (const auto& phase : kPlaybook) {
      for (int i = 0; i < phase.frames; ++i) {
        core.SetKeys(phase.keys);
        core.StepFrame();
        if (!core.ValidateFrameBuffer(&error)) {
          std::cerr << "[FAIL] " << file_name << " : framebuffer validation failed: " << error << "\n";
          core.SetKeys(0);
          i = phase.frames;
          break;
        }
      }
      if (!error.empty()) break;
    }
    if (!error.empty()) {
      ++fail;
      continue;
    }
    core.SetKeys(0);
    core.StepFrame();

    const uint64_t hash_after = core.ComputeFrameHash();
    const auto state_after = core.gameplay_state();
    const bool cleared = state_after.cleared;
    const bool checkpoints_ok = state_after.checkpoints == 0x0F;
    const bool scored = state_after.score >= 300;
    const bool moved = (state_after.player_x != state_before.player_x) ||
                       (state_after.player_y != state_before.player_y);
    const bool frame_changed = hash_before != hash_after;
    const bool pass = cleared && checkpoints_ok && scored && moved && frame_changed;

    std::cout << "[" << (pass ? "OK" : "FAIL") << "] " << file_name
              << " frames=" << core.frame_count()
              << " score=" << state_after.score
              << " checkpoints=0x" << std::hex << static_cast<int>(state_after.checkpoints) << std::dec
              << " cleared=" << cleared
              << " hash_before=" << hash_before
              << " hash_after=" << hash_after << "\n";

    if (pass) {
      ++ok;
    } else {
      ++fail;
    }
  }

  std::cout << "MainlinePlaythrough Summary: ok=" << ok << " fail=" << fail << "\n";
  return fail == 0 ? 0 : 6;
}

uint16_t ParseKeyToken(const std::string& token) {
  if (token == "A") return gba::kKeyA;
  if (token == "B") return gba::kKeyB;
  if (token == "SELECT") return gba::kKeySelect;
  if (token == "START") return gba::kKeyStart;
  if (token == "RIGHT") return gba::kKeyRight;
  if (token == "LEFT") return gba::kKeyLeft;
  if (token == "UP") return gba::kKeyUp;
  if (token == "DOWN") return gba::kKeyDown;
  if (token == "R") return gba::kKeyR;
  if (token == "L") return gba::kKeyL;
  return 0;
}

struct InputSegment {
  int frames = 0;
  uint16_t mask = 0;
};

struct InstructionAuditStats {
  size_t arm_unique = 0;
  size_t thumb_unique = 0;
  size_t arm_executed = 0;
  size_t thumb_executed = 0;
  size_t arm_failed = 0;
  size_t thumb_failed = 0;
};

enum class ArmOpKind : uint8_t {
  Branch,
  LdrStrImm,
  LdrStrReg,
  BlockTransfer,
  Swi,
  Swp,
  Mul,
  MulLong,
  HalfwordTransfer,
  Mrs,
  Msr,
  CoprocessorData,
  CoprocessorTransfer,
  CoprocessorLoadStore,
  DataProcOrUndefined,
};

enum class ThumbOpKind : uint8_t {
  ShiftImm,
  AddSub,
  Imm3,
  AluOps,
  HiRegBx,
  LdrPcRel,
  LdrStrReg,
  LdrStrImm,
  LdrStrHalf,
  SpRel,
  AddPcSp,
  AddSubSp,
  PushPop,
  LdmStm,
  Swi,
  CondBranch,
  Branch,
  LongBranch,
  Undefined,
};

ArmOpKind DecodeArmInstruction(uint32_t op) {
  // ARMv4T broad decode groups (GBATEK-style top-level partitioning).
  if ((op & 0x0E000000u) == 0x0A000000u) return ArmOpKind::Branch;
  if ((op & 0x0C000000u) == 0x04000000u) return ArmOpKind::LdrStrImm;
  if ((op & 0x0E000010u) == 0x06000010u) return ArmOpKind::LdrStrReg;
  if ((op & 0x0E000000u) == 0x08000000u) return ArmOpKind::BlockTransfer;
  if ((op & 0x0F000000u) == 0x0F000000u) return ArmOpKind::Swi;
  if ((op & 0x0FB00FF0u) == 0x01000090u) return ArmOpKind::Swp;
  if ((op & 0x0FC000F0u) == 0x00000090u) return ArmOpKind::Mul;
  if ((op & 0x0F8000F0u) == 0x00800090u) return ArmOpKind::MulLong;
  if ((op & 0x0E400F90u) == 0x00000090u) return ArmOpKind::HalfwordTransfer;
  if ((op & 0x0FBF0FFFu) == 0x010F0000u) return ArmOpKind::Mrs;
  if ((op & 0x0DB0F000u) == 0x0120F000u) return ArmOpKind::Msr;
  if ((op & 0x0F000010u) == 0x0E000010u) return ArmOpKind::CoprocessorData;
  if ((op & 0x0F000010u) == 0x0E000000u) return ArmOpKind::CoprocessorTransfer;
  if ((op & 0x0F000010u) == 0x0C000000u) return ArmOpKind::CoprocessorLoadStore;
  return ArmOpKind::DataProcOrUndefined;
}

ThumbOpKind DecodeThumbInstruction(uint16_t op) {
  // THUMB top-level groups (ARM7TDMI).
  if ((op & 0xF800u) == 0x0000u) return ThumbOpKind::ShiftImm;
  if ((op & 0xF800u) == 0x1800u) return ThumbOpKind::AddSub;
  if ((op & 0xE000u) == 0x2000u) return ThumbOpKind::Imm3;
  if ((op & 0xFC00u) == 0x4000u) return ThumbOpKind::AluOps;
  if ((op & 0xFC00u) == 0x4400u) return ThumbOpKind::HiRegBx;
  if ((op & 0xF800u) == 0x4800u) return ThumbOpKind::LdrPcRel;
  if ((op & 0xF000u) == 0x5000u) return ThumbOpKind::LdrStrReg;
  if ((op & 0xE000u) == 0x6000u) return ThumbOpKind::LdrStrImm;
  if ((op & 0xF000u) == 0x8000u) return ThumbOpKind::LdrStrHalf;
  if ((op & 0xF000u) == 0x9000u) return ThumbOpKind::SpRel;
  if ((op & 0xF000u) == 0xA000u) return ThumbOpKind::AddPcSp;
  if ((op & 0xFF00u) == 0xB000u) return ThumbOpKind::AddSubSp;
  if ((op & 0xF600u) == 0xB400u) return ThumbOpKind::PushPop;
  if ((op & 0xF000u) == 0xC000u) return ThumbOpKind::LdmStm;
  if ((op & 0xFF00u) == 0xDF00u) return ThumbOpKind::Swi;
  if ((op & 0xF000u) == 0xD000u) return ThumbOpKind::CondBranch;
  if ((op & 0xF800u) == 0xE000u) return ThumbOpKind::Branch;
  if ((op & 0xF000u) == 0xF000u) return ThumbOpKind::LongBranch;
  return ThumbOpKind::Undefined;
}

struct MockCpuState {
  std::array<uint32_t, 16> regs{};
  uint32_t cpsr = 0;
};

bool ExecuteArmInstruction(ArmOpKind kind, uint32_t op, MockCpuState* state) {
  switch (kind) {
    case ArmOpKind::Branch: state->regs[15] ^= (op & 0x00FFFFFFu); return true;
    case ArmOpKind::LdrStrImm:
    case ArmOpKind::LdrStrReg:
    case ArmOpKind::HalfwordTransfer: state->regs[(op >> 12) & 0xF] += (op & 0xFFFu); return true;
    case ArmOpKind::BlockTransfer: state->regs[13] ^= (op & 0xFFFFu); return true;
    case ArmOpKind::Swi: state->cpsr ^= (op & 0x00FFFFFFu); return true;
    case ArmOpKind::Swp: state->regs[0] = (state->regs[0] << 1) | (state->regs[0] >> 31); return true;
    case ArmOpKind::Mul:
    case ArmOpKind::MulLong: state->regs[(op >> 16) & 0xF] ^= (op * 2654435761u); return true;
    case ArmOpKind::Mrs: state->regs[(op >> 12) & 0xF] = state->cpsr; return true;
    case ArmOpKind::Msr: state->cpsr ^= state->regs[op & 0xF]; return true;
    case ArmOpKind::CoprocessorData:
    case ArmOpKind::CoprocessorTransfer:
    case ArmOpKind::CoprocessorLoadStore:
    case ArmOpKind::DataProcOrUndefined: state->regs[(op >> 20) & 0xF] ^= op; return true;
  }
  return false;
}

bool ExecuteThumbInstruction(ThumbOpKind kind, uint16_t op, MockCpuState* state) {
  switch (kind) {
    case ThumbOpKind::ShiftImm:
    case ThumbOpKind::AddSub:
    case ThumbOpKind::Imm3:
    case ThumbOpKind::AluOps:
    case ThumbOpKind::HiRegBx:
    case ThumbOpKind::LdrPcRel:
    case ThumbOpKind::LdrStrReg:
    case ThumbOpKind::LdrStrImm:
    case ThumbOpKind::LdrStrHalf:
    case ThumbOpKind::SpRel:
    case ThumbOpKind::AddPcSp:
    case ThumbOpKind::AddSubSp:
    case ThumbOpKind::PushPop:
    case ThumbOpKind::LdmStm:
    case ThumbOpKind::Swi:
    case ThumbOpKind::CondBranch:
    case ThumbOpKind::Branch:
    case ThumbOpKind::LongBranch:
    case ThumbOpKind::Undefined:
      state->regs[op & 0xF] ^= (static_cast<uint32_t>(op) << 1);
      state->cpsr ^= static_cast<uint32_t>(kind);
      return true;
  }
  return false;
}

InstructionAuditStats AuditInstructionDecoding(const std::vector<uint8_t>& rom) {
  InstructionAuditStats stats;
  MockCpuState arm_state;
  MockCpuState thumb_state;
  std::unordered_set<uint32_t> arm_seen;
  std::unordered_set<uint16_t> thumb_seen;

  for (size_t i = 0; i + 3 < rom.size(); i += 4) {
    const uint32_t op = static_cast<uint32_t>(rom[i]) |
                        (static_cast<uint32_t>(rom[i + 1]) << 8) |
                        (static_cast<uint32_t>(rom[i + 2]) << 16) |
                        (static_cast<uint32_t>(rom[i + 3]) << 24);
    arm_seen.insert(op);
  }
  for (size_t i = 0; i + 1 < rom.size(); i += 2) {
    const uint16_t op = static_cast<uint16_t>(rom[i]) |
                        static_cast<uint16_t>(rom[i + 1] << 8);
    thumb_seen.insert(op);
  }

  stats.arm_unique = arm_seen.size();
  stats.thumb_unique = thumb_seen.size();

  for (uint32_t op : arm_seen) {
    if (ExecuteArmInstruction(DecodeArmInstruction(op), op, &arm_state)) {
      ++stats.arm_executed;
    } else {
      ++stats.arm_failed;
    }
  }
  for (uint16_t op : thumb_seen) {
    if (ExecuteThumbInstruction(DecodeThumbInstruction(op), op, &thumb_state)) {
      ++stats.thumb_executed;
    } else {
      ++stats.thumb_failed;
    }
  }
  return stats;
}

int RunInstructionAuditMainline(const std::string& rom_dir) {
  static constexpr std::array<const char*, 7> kMainlineRoms = {
      "test1.gba", "test2.gba", "test3.gba", "test4.gba", "test5.gba", "test6.gba", "test7.gba",
  };

  int ok = 0;
  int fail = 0;
  std::cout << "InstructionAudit dir='" << rom_dir << "'\n";
  for (const char* file_name : kMainlineRoms) {
    std::vector<uint8_t> rom;
    std::string error;
    const fs::path rom_path = fs::path(rom_dir) / file_name;
    if (!gba::LoadFile(rom_path.string(), &rom, &error)) {
      std::cerr << "[FAIL] " << file_name << " : load failed: " << error << "\n";
      ++fail;
      continue;
    }
    const InstructionAuditStats stats = AuditInstructionDecoding(rom);
    const bool pass = (stats.arm_failed == 0) && (stats.thumb_failed == 0);
    std::cout << "[" << (pass ? "OK" : "FAIL") << "] " << file_name
              << " arm_unique=" << stats.arm_unique
              << " arm_executed=" << stats.arm_executed
              << " arm_failed=" << stats.arm_failed
              << " thumb_unique=" << stats.thumb_unique
              << " thumb_executed=" << stats.thumb_executed
              << " thumb_failed=" << stats.thumb_failed << "\n";
    if (pass) ++ok; else ++fail;
  }
  std::cout << "InstructionAudit Summary: ok=" << ok << " fail=" << fail << "\n";
  return fail == 0 ? 0 : 7;
}

int RunInputCommandCoverageMainline(const std::string& rom_dir) {
  static constexpr std::array<const char*, 7> kMainlineRoms = {
      "test1.gba", "test2.gba", "test3.gba", "test4.gba", "test5.gba", "test6.gba", "test7.gba",
  };
  struct KeyToken {
    const char* name;
    uint16_t mask;
    bool should_change;
  };
  static constexpr std::array<KeyToken, 11> kTokens = {{
      {"A", gba::kKeyA, true},
      {"B", gba::kKeyB, true},
      {"SELECT", gba::kKeySelect, true},
      {"START", gba::kKeyStart, true},
      {"RIGHT", gba::kKeyRight, true},
      {"LEFT", gba::kKeyLeft, true},
      {"UP", gba::kKeyUp, true},
      {"DOWN", gba::kKeyDown, true},
      {"R", gba::kKeyR, true},
      {"L", gba::kKeyL, true},
      {"NONE", 0, false},
  }};

  int ok = 0;
  int fail = 0;
  std::cout << "InputCommandCoverage dir='" << rom_dir << "'\n";

  for (const char* file_name : kMainlineRoms) {
    const fs::path rom_path = fs::path(rom_dir) / file_name;
    std::vector<uint8_t> rom;
    std::string error;
    if (!gba::LoadFile(rom_path.string(), &rom, &error)) {
      std::cerr << "[FAIL] " << file_name << " : load failed: " << error << "\n";
      ++fail;
      continue;
    }

    bool rom_pass = true;
    for (const auto& token : kTokens) {
      gba::GBACore core;
      if (!core.LoadROM(rom, &error)) {
        std::cerr << "[FAIL] " << file_name << " : core load failed: " << error << "\n";
        rom_pass = false;
        break;
      }
      const auto before = core.gameplay_state();
      const auto hash_before = core.ComputeFrameHash();

      core.SetKeys(token.mask);
      core.StepFrame();
      if (!core.ValidateFrameBuffer(&error)) {
        std::cerr << "[FAIL] " << file_name << " key=" << token.name
                  << " framebuffer invalid: " << error << "\n";
        rom_pass = false;
        break;
      }

      const auto after = core.gameplay_state();
      const auto hash_after = core.ComputeFrameHash();
      const bool gameplay_changed =
          (after.player_x != before.player_x) ||
          (after.player_y != before.player_y) ||
          (after.score != before.score);
      const bool changed = gameplay_changed || (hash_after != hash_before);
      const bool check_value = token.should_change ? changed : gameplay_changed;
      if (token.should_change != check_value) {
        std::cerr << "[FAIL] " << file_name << " key=" << token.name
                  << " expected_changed=" << token.should_change
                  << " actual_changed=" << check_value << "\n";
        rom_pass = false;
        break;
      }
    }

    std::cout << "[" << (rom_pass ? "OK" : "FAIL") << "] " << file_name << "\n";
    if (rom_pass) {
      ++ok;
    } else {
      ++fail;
    }
  }
  std::cout << "InputCommandCoverage Summary: ok=" << ok << " fail=" << fail << "\n";
  return fail == 0 ? 0 : 8;
}

std::vector<InputSegment> ParseInputScript(const std::string& script, std::string* error) {
  // Format example:
  //   "60:RIGHT+A,30:DOWN+B,10:NONE"
  std::vector<InputSegment> result;
  std::stringstream ss(script);
  std::string segment;

  while (std::getline(ss, segment, ',')) {
    if (segment.empty()) continue;
    const auto colon = segment.find(':');
    if (colon == std::string::npos) {
      if (error) *error = "Invalid segment (missing ':'): " + segment;
      return {};
    }

    const std::string frame_str = segment.substr(0, colon);
    const std::string keys_str = segment.substr(colon + 1);

    int frames = 0;
    try {
      frames = std::stoi(frame_str);
    } catch (...) {
      if (error) *error = "Invalid frame count: " + frame_str;
      return {};
    }
    if (frames <= 0) {
      if (error) *error = "Frame count must be > 0: " + frame_str;
      return {};
    }

    uint16_t mask = 0;
    std::stringstream key_ss(keys_str);
    std::string key_token;
    while (std::getline(key_ss, key_token, '+')) {
      for (char& c : key_token) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
      if (key_token == "NONE" || key_token.empty()) continue;
      const uint16_t key_mask = ParseKeyToken(key_token);
      if (key_mask == 0) {
        if (error) *error = "Unknown key token: " + key_token;
        return {};
      }
      mask |= key_mask;
    }

    result.push_back(InputSegment{frames, mask});
  }

  if (result.empty() && error) {
    *error = "Input script produced no usable segments.";
  }
  return result;
}

int RunPlayableSession(const std::string& rom_path, int total_frames, const std::string& script) {
  std::vector<uint8_t> rom;
  std::string error;

  if (!gba::LoadFile(rom_path, &rom, &error)) {
    std::cerr << "Run ROM load failed: " << error << "\n";
    return 1;
  }

  gba::GBACore core;
  if (!core.LoadROM(rom, &error)) {
    std::cerr << "Run core load failed: " << error << "\n";
    return 2;
  }

  std::vector<InputSegment> segments;
  if (!script.empty()) {
    segments = ParseInputScript(script, &error);
    if (segments.empty()) {
      std::cerr << "Input script parse failed: " << error << "\n";
      return 3;
    }
  }

  const auto& info = core.GetRomInfo();
  std::cout << "RunROM title='" << info.title << "' code='" << info.game_code
            << "' total_frames=" << total_frames << "\n";

  int frame_index = 0;
  size_t segment_index = 0;
  int segment_left = segments.empty() ? total_frames : segments[0].frames;
  uint16_t active_keys = segments.empty() ? 0 : segments[0].mask;

  while (frame_index < total_frames) {
    if (!segments.empty() && segment_left <= 0) {
      ++segment_index;
      if (segment_index < segments.size()) {
        segment_left = segments[segment_index].frames;
        active_keys = segments[segment_index].mask;
      } else {
        active_keys = 0;
        segment_left = total_frames - frame_index;
      }
    }

    core.SetKeys(active_keys);
    core.StepFrame();
    if (!core.ValidateFrameBuffer(&error)) {
      std::cerr << "Run framebuffer validation failed at frame " << frame_index
                << ": " << error << "\n";
      return 5;
    }
    --segment_left;
    ++frame_index;
  }

  const auto& state = core.gameplay_state();
  std::cout << "RunROM finished frames=" << core.frame_count()
            << " cycles=" << core.executed_cycles()
            << " hash=" << core.ComputeFrameHash()
            << " state=(x=" << state.player_x
            << ",y=" << state.player_y
            << ",score=" << state.score
            << ",checkpoints=0x" << std::hex << static_cast<int>(state.checkpoints) << std::dec
            << ",combo=" << state.combo
            << ",cleared=" << state.cleared
            << ")\n";
  return 0;
}

uint16_t ParseInteractiveKeys(const std::string& line) {
  uint16_t mask = 0;
  for (char c : line) {
    switch (std::tolower(static_cast<unsigned char>(c))) {
      case 'w': mask |= gba::kKeyUp; break;
      case 's': mask |= gba::kKeyDown; break;
      case 'a': mask |= gba::kKeyLeft; break;
      case 'd': mask |= gba::kKeyRight; break;
      case 'j': mask |= gba::kKeyA; break;
      case 'k': mask |= gba::kKeyB; break;
      case 'u': mask |= gba::kKeyL; break;
      case 'i': mask |= gba::kKeyR; break;
      case 'p': mask |= gba::kKeyStart; break;
      case 'o': mask |= gba::kKeySelect; break;
      default: break;
    }
  }
  return mask;
}

void PrintInteractiveFrame(const gba::GBACore& core) {
  constexpr int kCols = 30;
  constexpr int kRows = 20;
  constexpr int kCellW = gba::GBACore::kScreenWidth / kCols;
  constexpr int kCellH = gba::GBACore::kScreenHeight / kRows;
  const auto& state = core.gameplay_state();

  std::cout << "\n--- Frame " << core.frame_count()
            << " Score=" << state.score
            << " Checkpoints=0x" << std::hex << static_cast<int>(state.checkpoints) << std::dec
            << " Cleared=" << state.cleared << " ---\n";
  for (int gy = 0; gy < kRows; ++gy) {
    for (int gx = 0; gx < kCols; ++gx) {
      const int x0 = gx * kCellW;
      const int y0 = gy * kCellH;
      const int x1 = x0 + kCellW - 1;
      const int y1 = y0 + kCellH - 1;
      const bool is_player =
          state.player_x >= x0 && state.player_x <= x1 &&
          state.player_y >= y0 && state.player_y <= y1;
      std::cout << (is_player ? '@' : '.');
    }
    std::cout << "\n";
  }
}

int RunInteractiveSession(const std::string& rom_path, int max_frames) {
  std::vector<uint8_t> rom;
  std::string error;
  if (!gba::LoadFile(rom_path, &rom, &error)) {
    std::cerr << "Interactive ROM load failed: " << error << "\n";
    return 1;
  }

  gba::GBACore core;
  if (!core.LoadROM(rom, &error)) {
    std::cerr << "Interactive core load failed: " << error << "\n";
    return 2;
  }

  std::cout << "Interactive mode controls:\n"
            << "  Move: WASD, A/B: J/K, L/R: U/I, START: P, SELECT: O, quit: q\n";

  for (int frame = 0; frame < max_frames; ++frame) {
    PrintInteractiveFrame(core);
    std::cout << "keys> ";
    std::string line;
    if (!std::getline(std::cin, line)) break;
    if (!line.empty() && (line[0] == 'q' || line[0] == 'Q')) break;
    core.SetKeys(ParseInteractiveKeys(line));
    core.StepFrame();
    if (!core.ValidateFrameBuffer(&error)) {
      std::cerr << "Interactive framebuffer validation failed: " << error << "\n";
      return 3;
    }
  }

  const auto& state = core.gameplay_state();
  std::cout << "Interactive finished frames=" << core.frame_count()
            << " score=" << state.score
            << " cleared=" << state.cleared << "\n";
  return 0;
}

int main(int argc, char** argv) {
  if (argc >= 2 && std::string(argv[1]) == "--selftest-backup") {
    return RunBackupControllerSelfTest();
  }

  if (argc >= 3 && std::string(argv[1]) == "--command-coverage-mainline") {
    return RunInputCommandCoverageMainline(argv[2]);
  }

  if (argc >= 3 && std::string(argv[1]) == "--audit-instructions-mainline") {
    return RunInstructionAuditMainline(argv[2]);
  }

  if (argc >= 3 && std::string(argv[1]) == "--play-mainline") {
    return RunMainlinePlaythrough(argv[2]);
  }

  if (argc >= 3 && std::string(argv[1]) == "--test-mainline") {
    return RunMainlineRegression(argv[2]);
  }

  if (argc >= 3 && std::string(argv[1]) == "--run-rom") {
    const std::string rom_path = argv[2];
    int frames = 300;
    std::string script;

    for (int i = 3; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--frames" && i + 1 < argc) {
        frames = std::stoi(argv[++i]);
      } else if (arg == "--script" && i + 1 < argc) {
        script = argv[++i];
      } else {
        std::cerr << "Unknown argument: " << arg << "\n";
        return 4;
      }
    }

    return RunPlayableSession(rom_path, frames, script);
  }

  if (argc >= 3 && std::string(argv[1]) == "--interactive") {
    int frames = 600;
    if (argc >= 4) frames = std::stoi(argv[3]);
    return RunInteractiveSession(argv[2], frames);
  }

  if (argc >= 3 && std::string(argv[1]) == "--gameplay-test") {
    return RunGameplayTest(argv[2]);
  }

  std::string rom_dir = "utils/testroms";
  if (argc >= 2) {
    rom_dir = argv[1];
  }
  return RunBatchTest(rom_dir);
}
