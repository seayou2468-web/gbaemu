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

    // Test mode 4: check frame buffer for error code
    for (int i = 0; i < 600; ++i) {
        core.StepFrame();
        if (i % 60 == 0) {
            uint16_t dispcnt = core.DebugRead16(0x04000000u);
            if ((dispcnt & 7) == 4) {
                // Mode 4 active
            }
        }
    }
    const auto& fb = core.GetFrameBuffer();
    // In gba-tests, if it fails, it prints a number in the center.
    // If it passes, it usually stays green or has some pattern.
    // Let's just output the frame.
    std::ofstream of("test_out.fb", std::ios::binary);
    of.write(reinterpret_cast<const char*>(fb.data()), fb.size() * sizeof(uint32_t));
    return 0;
}
