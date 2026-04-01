#ifndef GBA_CORE_H
#define GBA_CORE_H

#include <cstddef>
#include <array>
#include <cstdint>
#include <deque>
#include <string>
#include <vector>

namespace gba {

namespace mgba_compat {
constexpr uint32_t kBiosChecksum = 0xBAAE187Fu;
constexpr uint8_t kSwiDiv = 0x06u;
constexpr uint8_t kSwiDivArm = 0x07u;
constexpr uint8_t kSwiSqrt = 0x08u;
constexpr uint8_t kSwiArcTan = 0x09u;
constexpr uint8_t kSwiArcTan2 = 0x0Au;
constexpr uint8_t kSwiGetBiosChecksum = 0x0Du;
constexpr uint32_t kVideoHDrawCycles = 1006u;
constexpr uint32_t kVideoScanlineCycles = 1232u;
constexpr uint32_t kVideoVisibleLines = 160u;
constexpr uint32_t kVideoTotalLines = 228u;
constexpr uint32_t kAudioFifoCapacityBytes = 32u;
constexpr uint32_t kAudioFifoDmaRequestThreshold = 16u;
constexpr uint32_t kAudioFifoDmaWordsPerBurst = 4u;
}  // namespace mgba_compat

enum KeyMask : uint16_t {
  kKeyA = 1 << 0, kKeyB = 1 << 1, kKeySelect = 1 << 2, kKeyStart = 1 << 3, kKeyRight = 1 << 4, kKeyLeft = 1 << 5, kKeyUp = 1 << 6, kKeyDown = 1 << 7, kKeyR = 1 << 8, kKeyL = 1 << 9,
};

struct RomInfo {
  std::string title, game_code, maker_code;
  uint8_t fixed_value, unit_code, device_type, version, complement_check, computed_complement_check;
  bool logo_valid, complement_check_valid;
};

struct GameplayState {
  int player_x = 120, player_y = 80;
  uint32_t score = 0, combo = 0; uint8_t checkpoints = 0; bool cleared = false;
};

class GBACore {
 public:
  static constexpr int kScreenWidth = 240, kScreenHeight = 160;

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
  std::vector<uint8_t> ExportBackupData() const;

  uint32_t DebugGetPC() const { return cpu_.regs[15]; }
  uint32_t DebugGetCPSR() const { return cpu_.cpsr; }
  uint32_t DebugGetReg(size_t index) const { return cpu_.regs[index & 0xFu]; }
  uint32_t DebugGetLastExceptionVector() const { return debug_last_exception_vector_; }
  uint32_t DebugGetLastExceptionPc() const { return debug_last_exception_pc_; }
  uint32_t DebugGetLastExceptionCpsr() const { return debug_last_exception_cpsr_; }

 private:
  static constexpr uint32_t kCyclesPerFrame = 280896, kCyclesPerScanline = 1232, kVisibleScanlines = 160, kTotalScanlines = 228;

  uint8_t ComputeComplementCheck() const;
  bool ValidateNintendoLogo() const;
  void UpdateGameplayFromInput();
  void RenderDebugFrame();
  void RenderMode0Frame(); void RenderMode1Frame(); void RenderMode2Frame(); void RenderMode3Frame(); void RenderMode4Frame(); void RenderMode5Frame();
  void BuildObjWindowMask(); void RenderSprites(); void ApplyColorEffects();
  void StepPpu(uint32_t cycles); void StepTimers(uint32_t cycles); void StepDma(); void StepDmaVBlank(); void StepDmaHBlank();
  void ExecuteDmaTransfer(int ch, uint16_t cnt_h);
  void StepApu(uint32_t cycles); void StepSio(uint32_t cycles); void UpdateSioMode(); void StartSioTransfer(uint16_t siocnt); uint32_t EstimateSioTransferCycles(uint16_t siocnt) const; void CompleteSioTransfer();
  void PushAudioFifo(bool fifo_a, uint32_t value); void ConsumeAudioFifoOnTimer(size_t timer_index);
  void SyncKeyInputRegister(); void RaiseInterrupt(uint16_t mask); void EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state); void ServiceInterruptIfNeeded();
  static uint32_t NormalizeSpLrBankMode(uint32_t mode);

  uint8_t Read8(uint32_t addr) const; uint16_t Read16(uint32_t addr) const; uint32_t Read32(uint32_t addr) const;
  void Write8(uint32_t addr, uint8_t value); void Write16(uint32_t addr, uint16_t value); void Write32(uint32_t addr, uint32_t value);
  uint16_t ReadIO16(uint32_t addr) const; void WriteIO16(uint32_t addr, uint16_t value);
  void AddWaitstates(uint32_t addr, int size, bool is_write) const; void RebuildGamePakWaitstateTables(uint16_t waitcnt);
  uint32_t RotateRight(uint32_t value, unsigned bits) const; uint32_t ApplyShift(uint32_t value, uint32_t shift_type, uint32_t shift_amount, bool* carry_out) const;
  bool GetFlagC() const; void SetFlagC(bool carry); uint32_t ExpandArmImmediate(uint32_t imm12) const; bool CheckCondition(uint32_t cond) const;
  void SetNZFlags(uint32_t value); void SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t result64); void SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t result64);
  uint32_t GetCpuMode() const; bool IsPrivilegedMode(uint32_t mode) const; bool HasSpsr(uint32_t mode) const; void SwitchCpuMode(uint32_t new_mode);
  uint32_t EstimateArmCycles(uint32_t opcode) const; uint32_t EstimateThumbCycles(uint16_t opcode) const;
  void ExecuteArmInstruction(uint32_t opcode); void ExecuteThumbInstruction(uint16_t opcode);
  bool HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state); void HandleUndefinedInstruction(bool thumb_state);
  void HandleRegisterRamReset(uint8_t flags); void HandleCpuSet(bool fast_mode); uint32_t RunCpuSlice(uint32_t cycles);

  struct CpuState {
    std::array<uint32_t, 16> regs{}; uint32_t cpsr = 0x1Fu; std::array<uint32_t, 5> banked_fiq_r8_r12{}; std::array<uint32_t, 6> banked_sp{}, banked_lr{}, spsr{};
    uint32_t active_mode = 0x1Fu; bool halted = false;
  };
  enum class BackupType : uint8_t { kUnknown = 0, kSRAM = 1, kFlash64K = 2, kFlash128K = 3, kEEPROM = 4 };
  BackupType DetectBackupTypeFromRom() const; uint8_t ReadBackup8(uint32_t addr) const; void WriteBackup8(uint32_t addr, uint8_t value); void ResetBackupControllerState();

  std::vector<uint8_t> rom_; std::array<uint8_t, 16 * 1024> bios_{}; mutable uint32_t bios_fetch_latch_ = 0, open_bus_latch_ = 0;
  mutable uint32_t last_access_addr_ = 0; mutable uint8_t last_access_size_ = 0; mutable uint64_t waitstates_accum_ = 0;
  bool bios_loaded_ = false, bios_is_builtin_ = false; std::array<uint8_t, 256 * 1024> ewram_{}; std::array<uint8_t, 32 * 1024> iwram_{};
  std::array<uint8_t, 1024> io_regs_{}, palette_ram_{}, oam_{}; std::array<uint8_t, 96 * 1024> vram_{}; std::array<uint8_t, 64 * 1024> sram_{}, flash_bank1_{};
  RomInfo rom_info_{}; std::vector<uint32_t> frame_buffer_; uint32_t ppu_cycle_accum_ = 0;
  std::deque<uint8_t> fifo_a_, fifo_b_; uint32_t apu_frame_seq_cycles_ = 0; uint8_t apu_frame_seq_step_ = 0;

  struct TimerState { uint16_t reload = 0, counter = 0; uint32_t prescaler_accum = 0; };
  std::array<TimerState, 4> timers_{}; int32_t bg2_refx_internal_ = 0, bg2_refy_internal_ = 0, bg3_refx_internal_ = 0, bg3_refy_internal_ = 0;
  struct SioState { bool transfer_active = false; uint32_t transfer_cycles_remaining = 0; }; SioState sio_{};
  struct DmaState { bool active = false, pending = false; }; std::array<DmaState, 4> dma_shadows_{};
  CpuState cpu_{}; GameplayState gameplay_state_{}; uint64_t frame_count_ = 0, executed_cycles_ = 0; uint16_t keys_pressed_mask_ = 0, previous_keys_mask_ = 0;
  bool loaded_ = false; BackupType backup_type_ = BackupType::kUnknown;
  bool flash_mode_unlocked_ = false, flash_id_mode_ = false, flash_program_mode_ = false, flash_bank_switch_mode_ = false; uint8_t flash_command_ = 0, flash_bank_ = 0;
  bool swi_intrwait_active_ = false; uint16_t swi_intrwait_mask_ = 0;
  uint32_t debug_last_exception_vector_ = 0, debug_last_exception_pc_ = 0, debug_last_exception_cpsr_ = 0;
  mutable std::vector<uint8_t> eeprom_cmd_bits_{}, eeprom_read_bits_{}; mutable size_t eeprom_read_pos_ = 0;
};
}  // namespace gba
#endif
