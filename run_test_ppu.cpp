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
    if (argc < 2) return 1;
    const std::vector<uint8_t> rom = LoadFile(argv[1]);
    if (rom.empty()) return 1;
    gba::GBACore core;
    core.LoadBuiltInBIOS();
    std::string err;
    core.LoadROM(rom, &err);

    // Check for VRAM nonzero
    auto count_vram = [&]() {
        size_t n = 0;
        for (uint32_t a = 0x06000000; a < 0x06018000; ++a) {
            if (core.DebugRead8(a) != 0) n++;
        }
        return n;
    };

    printf("Initial VRAM nonzero: %zu\n", count_vram());
    for (int i = 0; i < 60; ++i) {
        core.StepFrame();
    }
    printf("Final VRAM nonzero: %zu\n", count_vram());
    printf("Final PC: %08X\n", core.DebugGetPC());
    return 0;
}
