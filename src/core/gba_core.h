#ifndef GBA_CORE_H
#define GBA_CORE_H

#include <cstddef>
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace gba {

enum KeyMask : uint16_t {
  kKeyA = 1 << 0,
  kKeyB = 1 << 1,
  kKeySelect = 1 << 2,
  kKeyStart = 1 << 3,
  kKeyRight = 1 << 4,
  kKeyLeft = 1 << 5,
  kKeyUp = 1 << 6,
  kKeyDown = 1 << 7,
  kKeyR = 1 << 8,
  kKeyL = 1 << 9,
};

struct RomInfo {
  std::string title;
  std::string game_code;
  std::string maker_code;
  uint8_t fixed_value;
  uint8_t unit_code;
  uint8_t device_type;
  uint8_t version;
  uint8_t complement_check;
  uint8_t computed_complement_check;
  bool logo_valid;
  bool complement_check_valid;
};

struct GameplayState {
  int player_x = 120;
  int player_y = 80;
  uint32_t score = 0;
  uint8_t checkpoints = 0;
  uint32_t combo = 0;
  bool cleared = false;
};

class GBACore {
 public:
  static constexpr int kScreenWidth = 240;
  static constexpr int kScreenHeight = 160;

  bool LoadROM(const std::vector<uint8_t>& rom, std::string* error);
  void Reset();
  void RunCycles(uint32_t cycles);
  void StepFrame();

  void SetKeys(uint16_t keys_pressed_mask);
  uint16_t GetKeys() const { return keys_pressed_mask_; }

  const RomInfo& GetRomInfo() const { return rom_info_; }
  const std::vector<uint32_t>& GetFrameBuffer() const { return frame_buffer_; }
  const GameplayState& gameplay_state() const { return gameplay_state_; }
  uint64_t frame_count() const { return frame_count_; }
  uint64_t executed_cycles() const { return executed_cycles_; }
  bool loaded() const { return loaded_; }

  uint64_t ComputeFrameHash() const;
  bool ValidateFrameBuffer(std::string* error) const;

 private:
  uint8_t ComputeComplementCheck() const;
  bool ValidateNintendoLogo() const;
  void UpdateGameplayFromInput();
  void RenderDebugFrame();
  uint32_t Read32(uint32_t addr) const;
  uint16_t Read16(uint32_t addr) const;
  void Write32(uint32_t addr, uint32_t value);
  uint32_t RotateRight(uint32_t value, unsigned bits) const;
  uint32_t ExpandArmImmediate(uint32_t imm12) const;
  bool CheckCondition(uint32_t cond) const;
  void SetNZFlags(uint32_t value);
  void SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t result64);
  void SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t result64);
  void ExecuteArmInstruction(uint32_t opcode);
  void ExecuteThumbInstruction(uint16_t opcode);
  void RunCpuSlice(uint32_t cycles);

  struct CpuState {
    std::array<uint32_t, 16> regs{};
    uint32_t cpsr = 0x1Fu;  // System mode
    bool halted = false;
  };

  std::vector<uint8_t> rom_;
  std::array<uint8_t, 256 * 1024> ewram_{};
  std::array<uint8_t, 32 * 1024> iwram_{};
  RomInfo rom_info_{};
  std::vector<uint32_t> frame_buffer_;
  CpuState cpu_{};
  GameplayState gameplay_state_{};
  uint64_t frame_count_ = 0;
  uint64_t executed_cycles_ = 0;
  uint16_t keys_pressed_mask_ = 0;
  uint16_t previous_keys_mask_ = 0;
  bool loaded_ = false;
};

}  // namespace gba

#endif
