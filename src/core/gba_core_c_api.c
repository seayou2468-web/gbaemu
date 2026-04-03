#include "./gba_core_c_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GBACoreHandle {
    char last_error[256];
    uint32_t* framebuffer;
    size_t framebuffer_size;
    uint32_t frame_counter;
    int has_rom;
};

static void SetLastError(GBACoreHandle* handle, const char* message) {
    if (!handle) {
        return;
    }
    if (!message) {
        handle->last_error[0] = '\0';
        return;
    }
    snprintf(handle->last_error, sizeof(handle->last_error), "%s", message);
}

static int FileExists(const char* path) {
    if (!path) {
        return 0;
    }
    FILE* f = fopen(path, "rb");
    if (!f) {
        return 0;
    }
    fclose(f);
    return 1;
}

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* handle = (GBACoreHandle*)calloc(1, sizeof(GBACoreHandle));
    if (!handle) {
        return NULL;
    }
    handle->framebuffer_size = 240u * 160u;
    handle->framebuffer = (uint32_t*)malloc(handle->framebuffer_size * sizeof(uint32_t));
    if (!handle->framebuffer) {
        free(handle);
        return NULL;
    }
    for (size_t i = 0; i < handle->framebuffer_size; ++i) {
        handle->framebuffer[i] = 0xFF000000u;
    }
    SetLastError(handle, "");
    return handle;
}

void GBA_Destroy(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    free(handle->framebuffer);
    free(handle);
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    SetLastError(handle, "");
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) {
        return false;
    }
    if (!FileExists(path)) {
        SetLastError(handle, "failed to load rom");
        return false;
    }

    handle->has_rom = 1;
    SetLastError(handle, "");
    return true;
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->frame_counter = 0;
    for (size_t i = 0; i < handle->framebuffer_size; ++i) {
        handle->framebuffer[i] = 0xFF000000u;
    }
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle || !handle->has_rom) {
        return;
    }
    ++handle->frame_counter;
    if (handle->framebuffer_size > 0) {
        handle->framebuffer[0] = 0xFF000000u | (handle->frame_counter & 0x00FFFFFFu);
    }
}

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* out_size) {
    if (!handle) {
        return NULL;
    }
    if (out_size) {
        *out_size = handle->framebuffer_size;
    }
    return handle->framebuffer;
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* out_pixels, size_t out_size) {
    if (!handle || !out_pixels) {
        return false;
    }
    if (out_size < handle->framebuffer_size) {
        return false;
    }
    memcpy(out_pixels, handle->framebuffer, handle->framebuffer_size * sizeof(uint32_t));
    return true;
}

const char* GBA_GetLastError(GBACoreHandle* handle) {
    if (!handle) {
        return "invalid handle";
    }
    return handle->last_error;
}
