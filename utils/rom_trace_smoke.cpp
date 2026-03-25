#include "src/core/gba_core.h"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {
std::vector<uint8_t> LoadFile(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
}

size_t CountVramNonZero(const gba::GBACore& core) {
  size_t n = 0;
  for (uint32_t addr = 0x06000000u; addr < 0x06018000u; ++addr) {
    if (core.DebugRead8(addr) != 0) ++n;
  }
  return n;
}
}  // namespace

int main() {
  const std::vector<std::string> roms = {
      "utils/testroms/test8.gba",  "utils/testroms/test9.gba",
      "utils/testroms/test10.gba", "utils/testroms/test11.gba",
      "utils/testroms/test12.gba", "utils/testroms/test13.gba",
      "utils/testroms/test14.gba", "utils/testroms/test15.gba",
      "utils/testroms/test16.gba", "utils/testroms/test17.gba",
  };

  for (const auto& path : roms) {
    const std::vector<uint8_t> rom = LoadFile(path);
    if (rom.empty()) {
      std::printf("%s: load_error=empty\n", path.c_str());
      continue;
    }

    gba::GBACore core;
    core.LoadBuiltInBIOS();
    std::string warning;
    if (!core.LoadROM(rom, &warning)) {
      std::printf("%s: load_error=%s\n", path.c_str(), warning.c_str());
      continue;
    }

    for (int i = 0; i < 12; ++i) core.StepFrame();
    const uint16_t dispcnt = core.DebugRead16(0x04000000u);
    const size_t vram_nonzero = CountVramNonZero(core);
    const auto hash = static_cast<unsigned long long>(core.ComputeFrameHash());
    std::printf("%s: pc=%08X cpsr=%08X mode=%u dispcnt=%04X vram_nonzero=%zu hash=%llu warning=%s\n",
                path.c_str(), core.DebugGetPC(), core.DebugGetCPSR(), dispcnt & 0x7u, dispcnt,
                vram_nonzero, hash, warning.c_str());
  }

  return 0;
}
