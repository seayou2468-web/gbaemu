#include "src/core/gba_core.h"
#include <cstdio>
#include <fstream>
#include <vector>
#include <string>

std::vector<uint8_t> LoadFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
    if (argc < 3) return 1;
    const std::vector<uint8_t> rom = LoadFile(argv[1]);
    if (rom.empty()) return 1;
    gba::GBACore core;
    core.LoadBuiltInBIOS();
    std::string err;
    core.LoadROM(rom, &err);
    printf("Running %s...\n", argv[1]);
    for (int i = 0; i < 60; ++i) {
        core.StepFrame();
    }
    const auto& fb = core.GetFrameBuffer();
    std::ofstream of(argv[2], std::ios::binary);
    of.write(reinterpret_cast<const char*>(fb.data()), fb.size() * sizeof(uint32_t));
    printf("Captured frame to %s\n", argv[2]);
    return 0;
}
