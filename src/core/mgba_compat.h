#ifndef MGBA_COMPAT_H
#define MGBA_COMPAT_H

#include <cstdint>

namespace gba::mgba_compat {

// Derived from mGBA internal BIOS/GBA headers.
constexpr uint32_t kBiosChecksum = 0xBAAE187Fu;

constexpr uint8_t kSwiDiv = 0x06u;
constexpr uint8_t kSwiDivArm = 0x07u;
constexpr uint8_t kSwiSqrt = 0x08u;
constexpr uint8_t kSwiArcTan = 0x09u;
constexpr uint8_t kSwiArcTan2 = 0x0Au;
constexpr uint8_t kSwiGetBiosChecksum = 0x0Du;

// Video timing constants equivalent to mGBA/GBA timing.
constexpr uint32_t kVideoHDrawCycles = 1006u;
constexpr uint32_t kVideoScanlineCycles = 1232u;
constexpr uint32_t kVideoVisibleLines = 160u;
constexpr uint32_t kVideoTotalLines = 228u;

// Audio FIFO constants aligned with mGBA behavior.
constexpr uint32_t kAudioFifoCapacityBytes = 32u;
constexpr uint32_t kAudioFifoDmaRequestThreshold = 16u;
constexpr uint32_t kAudioFifoDmaWordsPerBurst = 4u;

}  // namespace gba::mgba_compat

#endif
