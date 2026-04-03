#include "./gba_core_c_api.h"

#include "./gba_core.h"

#include <fstream>
#include <iterator>
#include <new>
#include <string>
#include <vector>

struct GBACoreHandle {
    gba::GBACore core;
    std::string last_error;
};

static std::vector<uint8_t> LoadFile(const char* path) {
    if (!path) {
        return {};
    }
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return {};
    }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

extern "C" {

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* handle = new (std::nothrow) GBACoreHandle();
    return handle;
}

void GBA_Destroy(GBACoreHandle* handle) {
    delete handle;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->core.LoadBuiltInBIOS();
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) {
        return false;
    }

    std::vector<uint8_t> rom = LoadFile(path);
    if (rom.empty()) {
        handle->last_error = "failed to load rom";
        return false;
    }

    std::string warning;
    if (!handle->core.LoadROM(rom, &warning)) {
        handle->last_error = warning.empty() ? "failed to load rom" : warning;
        return false;
    }

    handle->last_error.clear();
    return true;
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->core.Reset();
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->core.StepFrame();
}

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* out_size) {
    if (!handle) {
        return nullptr;
    }
    const std::vector<uint32_t>& fb = handle->core.GetFrameBuffer();
    if (out_size) {
        *out_size = fb.size();
    }
    return fb.data();
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* out_pixels, size_t out_size) {
    if (!handle || !out_pixels) {
        return false;
    }
    const std::vector<uint32_t>& fb = handle->core.GetFrameBuffer();
    if (out_size < fb.size()) {
        return false;
    }
    for (size_t i = 0; i < fb.size(); ++i) {
        out_pixels[i] = fb[i];
    }
    return true;
}

const char* GBA_GetLastError(GBACoreHandle* handle) {
    if (!handle) {
        return "invalid handle";
    }
    return handle->last_error.c_str();
}

}  // extern "C"
