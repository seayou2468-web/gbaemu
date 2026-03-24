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

  bool LoadBIOS(const std::vector<uint8_t>& bios, std::string* error);
  void LoadBuiltInBIOS();
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
  const std::array<uint8_t, 64 * 1024>& GetSaveRAM() const { return sram_; }
  void LoadSaveRAM(const std::vector<uint8_t>& data);
  std::vector<uint8_t> SaveStateBlob() const;
  bool LoadStateBlob(const std::vector<uint8_t>& blob, std::string* error);

  // Debug/testing bus accessors (tooling/front-end diagnostics only).
  uint8_t DebugRead8(uint32_t addr) const;
  uint16_t DebugRead16(uint32_t addr) const;
  uint32_t DebugRead32(uint32_t addr) const;
  void DebugWrite8(uint32_t addr, uint8_t value);
  void DebugWrite16(uint32_t addr, uint16_t value);
  void DebugWrite32(uint32_t addr, uint32_t value);

 private:
  static constexpr uint32_t kCyclesPerFrame = 280896;
  static constexpr uint32_t kCyclesPerScanline = 1232;
  static constexpr uint32_t kVisibleScanlines = 160;
  static constexpr uint32_t kTotalScanlines = 228;

  uint8_t ComputeComplementCheck() const;
  bool ValidateNintendoLogo() const;
  void UpdateGameplayFromInput();
  void RenderDebugFrame();
  void RenderMode0Frame();
  void RenderMode3Frame();
  void RenderMode4Frame();
  void RenderSprites();
  void StepPpu(uint32_t cycles);
  void StepTimers(uint32_t cycles);
  void StepDma();
  void StepApu(uint32_t cycles);
  void SyncKeyInputRegister();
  void RaiseInterrupt(uint16_t mask);
  void EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state);
  void ServiceInterruptIfNeeded();

  uint32_t Read32(uint32_t addr) const;
  uint16_t Read16(uint32_t addr) const;
  uint8_t Read8(uint32_t addr) const;
  void Write32(uint32_t addr, uint32_t value);
  void Write16(uint32_t addr, uint16_t value);
  void Write8(uint32_t addr, uint8_t value);
  uint16_t ReadIO16(uint32_t addr) const;
  void WriteIO16(uint32_t addr, uint16_t value);
  uint32_t RotateRight(uint32_t value, unsigned bits) const;
  uint32_t ApplyShift(uint32_t value, uint32_t shift_type, uint32_t shift_amount, bool* carry_out) const;
  bool GetFlagC() const;
  void SetFlagC(bool carry);
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

  enum class BackupType : uint8_t {
    kUnknown = 0,
    kSRAM = 1,
    kFlash64K = 2,
    kEEPROM = 3,
  };

  BackupType DetectBackupTypeFromRom() const;
  uint8_t ReadBackup8(uint32_t addr) const;
  void WriteBackup8(uint32_t addr, uint8_t value);
  void ResetBackupControllerState();

  std::vector<uint8_t> rom_;
  std::array<uint8_t, 16 * 1024> bios_{};
  bool bios_loaded_ = false;
  std::array<uint8_t, 256 * 1024> ewram_{};
  std::array<uint8_t, 32 * 1024> iwram_{};
  std::array<uint8_t, 1024> io_regs_{};
  std::array<uint8_t, 1024> palette_ram_{};
  std::array<uint8_t, 96 * 1024> vram_{};
  std::array<uint8_t, 1024> oam_{};
  std::array<uint8_t, 64 * 1024> sram_{};
  RomInfo rom_info_{};
  std::vector<uint32_t> frame_buffer_;
  uint32_t ppu_cycle_accum_ = 0;
  uint16_t audio_mix_level_ = 0;

  struct TimerState {
    uint16_t reload = 0;
    uint16_t control = 0;
    uint16_t counter = 0;
    uint32_t prescaler_accum = 0;
  };
  std::array<TimerState, 4> timers_{};

  CpuState cpu_{};
  GameplayState gameplay_state_{};
  uint64_t frame_count_ = 0;
  uint64_t executed_cycles_ = 0;
  uint16_t keys_pressed_mask_ = 0;
  uint16_t previous_keys_mask_ = 0;
  bool loaded_ = false;
  BackupType backup_type_ = BackupType::kUnknown;
  bool flash_mode_unlocked_ = false;
  uint8_t flash_command_ = 0;
  bool flash_id_mode_ = false;
  bool flash_program_mode_ = false;
};

}  // namespace gba

#endif
