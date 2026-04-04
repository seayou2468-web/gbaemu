#include "src/core/gba_core.hpp"
#include <cstdio>
#include <cstdint>
#include <fstream>
#include <vector>
#include <string>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "utils/stb_image_write.h"

int main(int argc, char** argv) {
    if (argc < 4) {
        std::printf("Usage: %s <rom_path> <frames> <output_png> [bios_path]\n", argv[0]);
        return 1;
    }

    std::string rom_path = argv[1];
    int frames = std::stoi(argv[2]);
    std::string output_path = argv[3];
    std::string bios_path = (argc >= 5) ? argv[4] : "";

    gba::GBACore core;
    if (!bios_path.empty()) {
        if (!core.LoadBIOSFromPath(bios_path)) {
            std::printf("Failed to load BIOS (%s): %s\n", bios_path.c_str(), core.GetLastError().c_str());
            return 1;
        }
    } else {
        core.LoadBuiltInBIOS();
    }
    std::string warning;
    if (!core.LoadROMFromPath(rom_path, &warning)) {
        std::printf("Warning/Error loading ROM: %s\n", warning.c_str());
        return 1;
    }

    for (int i = 0; i < frames; ++i) {
        core.StepFrame();
        if ((i + 1) % 50 == 0) {
           std::printf("Step frame %d...\n", i + 1);
        }
    }

    const std::vector<uint32_t>& fb = core.GetFrameBuffer();
    stbi_write_png(output_path.c_str(), gba::GBACore::kScreenWidth, gba::GBACore::kScreenHeight, 4, fb.data(), gba::GBACore::kScreenWidth * 4);
    std::printf("Saved frame %d to %s.\n", frames, output_path.c_str());

    return 0;
}
