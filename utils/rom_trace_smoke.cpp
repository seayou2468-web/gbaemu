#include "src/core/gba_core.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <algorithm>
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
  std::vector<std::string> roms;
  for (const auto& entry : std::filesystem::directory_iterator("utils/testroms")) {
    if (!entry.is_regular_file()) continue;
    if (entry.path().extension() != ".gba") continue;
    roms.push_back(entry.path().string());
  }
  std::sort(roms.begin(), roms.end());
  if (roms.empty()) {
    std::printf("utils/testroms: load_error=no_roms\n");
    return 1;
  }

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

    for (int i = 0; i < 60; ++i) core.StepFrame();
    core.DebugWrite16(0x06000000u, 0x1357u);
    core.DebugWrite16(0x06018000u, 0x2468u);
    const uint16_t vram_0000 = core.DebugRead16(0x06000000u);
    const uint16_t vram_10000 = core.DebugRead16(0x06010000u);
    const uint16_t vram_18000 = core.DebugRead16(0x06018000u);
    const bool vram_mirror_ok = (vram_0000 == 0x1357u) && (vram_10000 == 0x2468u) && (vram_18000 == 0x2468u);
    const uint16_t dispcnt = core.DebugRead16(0x04000000u);
    const size_t vram_nonzero = CountVramNonZero(core);
    const auto hash = static_cast<unsigned long long>(core.ComputeFrameHash());
    std::printf("%s: pc=%08X cpsr=%08X mode=%u dispcnt=%04X vram_nonzero=%zu hash=%llu vram_mirror=%s warning=%s\n",
                path.c_str(), core.DebugGetPC(), core.DebugGetCPSR(), dispcnt & 0x7u, dispcnt,
                vram_nonzero, hash, vram_mirror_ok ? "ok" : "ng", warning.c_str());
  }

  return 0;
}
