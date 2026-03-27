#include "src/core/gba_core.h"
#include <cstdio>
#include <fstream>
#include <vector>
#include <string>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "utils/stb_image_write.h"

std::vector<uint8_t> LoadFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
    if (argc < 4) {
        std::printf("Usage: %s <rom_path> <frames> <output_png>\n", argv[0]);
        return 1;
    }

    std::string rom_path = argv[1];
    int frames = std::stoi(argv[2]);
    std::string output_path = argv[3];

    std::vector<uint8_t> rom = LoadFile(rom_path);
    if (rom.empty()) {
        std::printf("Failed to load ROM: %s\n", rom_path.c_str());
        return 1;
    }

    gba::GBACore core;
    core.LoadBuiltInBIOS();
    std::string warning;
    if (!core.LoadROM(rom, &warning)) {
        std::printf("Warning/Error loading ROM: %s\n", warning.c_str());
    }

    for (int i = 0; i < frames; ++i) {
        core.StepFrame();
        if ((i + 1) % 50 == 0) {
           std::printf("Step frame %d... PC=%08X\n", i + 1, core.DebugGetPC());
        }
    }

    const std::vector<uint32_t>& fb = core.GetFrameBuffer();
    stbi_write_png(output_path.c_str(), gba::GBACore::kScreenWidth, gba::GBACore::kScreenHeight, 4, fb.data(), gba::GBACore::kScreenWidth * 4);
    std::printf("Saved frame %d to %s. PC=%08X CPSR=%08X\n", frames, output_path.c_str(), core.DebugGetPC(), core.DebugGetCPSR());

    return 0;
}
