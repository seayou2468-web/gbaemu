#include "../src/core/gba_core_c_api.h"

#include <cstdio>
#include <vector>

int main() {
    GBACoreHandle* h = GBA_Create();
    if (!h) {
        std::fprintf(stderr, "create failed\n");
        return 1;
    }

    GBA_LoadBuiltInBIOS(h);
    if (!GBA_LoadROMFromPath(h, "utils/testroms/test1.gba")) {
        std::fprintf(stderr, "rom load failed: %s\n", GBA_GetLastError(h));
        GBA_Destroy(h);
        return 2;
    }

    GBA_Reset(h);
    for (int i = 0; i < 5; ++i) {
        GBA_StepFrame(h);
    }

    size_t n = 0;
    const uint32_t* px = GBA_GetFrameBufferRGBA(h, &n);
    if (!px || n != 240 * 160) {
        std::fprintf(stderr, "framebuffer invalid\n");
        GBA_Destroy(h);
        return 3;
    }

    std::vector<uint32_t> copy(n);
    if (!GBA_CopyFrameBufferRGBA(h, copy.data(), copy.size())) {
        std::fprintf(stderr, "copy failed\n");
        GBA_Destroy(h);
        return 4;
    }

    std::printf("ok pixels=%zu first=%08X\n", n, copy[0]);
    GBA_Destroy(h);
    return 0;
}
