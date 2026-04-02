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
    const auto& fb = core.GetFrameBuffer();
    size_t nonBlackPixels = 0;
    for (uint32_t px : fb) {
      if (px != 0xFF000000u) ++nonBlackPixels;
    }
    const auto hash = static_cast<unsigned long long>(core.ComputeFrameHash());
    std::printf("%s: non_black=%zu hash=%llu warning=%s\n",
                path.c_str(), nonBlackPixels, hash, warning.c_str());
  }

  return 0;
}
