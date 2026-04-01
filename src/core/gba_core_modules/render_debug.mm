#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::StepSio(uint32_t cycles) {
  if (sio_.transfer_active) {
    if (sio_.transfer_cycles_remaining <= cycles) {
      CompleteSioTransfer();
    } else {
      sio_.transfer_cycles_remaining -= cycles;
    }
  }
}

void GBACore::UpdateSioMode() {
  // Logic to handle SioMode change
}

void GBACore::StartSioTransfer(uint16_t siocnt) {
  sio_.transfer_active = true;
  sio_.transfer_cycles_remaining = EstimateSioTransferCycles(siocnt);
}

uint32_t GBACore::EstimateSioTransferCycles(uint16_t siocnt) const {
  // Estimate transfer time based on baud rate
  return 1024; // placeholder: 1024 cycles
}

void GBACore::CompleteSioTransfer() {
  sio_.transfer_active = false;
  // Trigger SIO IRQ (bit 14 of SIOCNT)
  uint16_t siocnt = ReadIO16(0x04000128);
  if (siocnt & (1 << 14)) RaiseInterrupt(1 << 7);
}

} // namespace gba
