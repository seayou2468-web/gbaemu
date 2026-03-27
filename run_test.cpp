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
    if (!core.LoadROM(rom, &err)) {
        printf("FAILED to load ROM: %s\n", err.c_str());
        return 1;
    }
    printf("Running %s...\n", argv[1]);
    for (int i = 0; i < 600; ++i) { // Run for 10 seconds (60fps)
        core.StepFrame();
        if (i % 60 == 0) {
             printf("Frame %d: PC=%08X CPSR=%08X\n", i, core.DebugGetPC(), core.DebugGetCPSR());
        }
    }
    printf("Finished %s. Final PC=%08X\n", argv[1], core.DebugGetPC());
    return 0;
}
