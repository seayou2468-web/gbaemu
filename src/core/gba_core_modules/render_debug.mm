#include "../gba_core.h"

#include <algorithm>

namespace gba {

void GBACore::SyncKeyInputRegister() {
  const uint16_t keyinput = static_cast<uint16_t>(~keys_pressed_mask_ & 0x03FFu);
  io_regs_[0x130] = static_cast<uint8_t>(keyinput & 0xFF);
  io_regs_[0x131] = static_cast<uint8_t>(keyinput >> 8);
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) {
  previous_keys_mask_ = keys_pressed_mask_;
  keys_pressed_mask_ = static_cast<uint16_t>(keys_pressed_mask & 0x03FFu);
  SyncKeyInputRegister();
}

void GBACore::UpdateGameplayFromInput() {
  if (keys_pressed_mask_ & kKeyLeft) gameplay_state_.player_x--;
  if (keys_pressed_mask_ & kKeyRight) gameplay_state_.player_x++;
  if (keys_pressed_mask_ & kKeyUp) gameplay_state_.player_y--;
  if (keys_pressed_mask_ & kKeyDown) gameplay_state_.player_y++;
  gameplay_state_.player_x = std::clamp(gameplay_state_.player_x, 0, kScreenWidth - 1);
  gameplay_state_.player_y = std::clamp(gameplay_state_.player_y, 0, kScreenHeight - 1);
}

void GBACore::RenderDebugFrame() {
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);
  const int x = gameplay_state_.player_x;
  const int y = gameplay_state_.player_y;
  if (x >= 0 && x < kScreenWidth && y >= 0 && y < kScreenHeight) {
    frame_buffer_[y * kScreenWidth + x] = 0xFFFFFFFFu;
  }
}

void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;
  RunCpuSlice(cycles);
  StepTimers(cycles);
  StepDma();
  StepApu(cycles);
  StepSio(cycles);
  StepPpu(cycles);
  ServiceInterruptIfNeeded();
  executed_cycles_ += cycles;
}

void GBACore::StepFrame() {
  if (!loaded_) return;
  UpdateGameplayFromInput();
  RunCycles(kCyclesPerFrame);
  ++frame_count_;
}

}  // namespace gba
