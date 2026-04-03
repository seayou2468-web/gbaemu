#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GBACoreHandle GBACoreHandle;

GBACoreHandle* GBA_Create(void);
void GBA_Destroy(GBACoreHandle* handle);

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle);
bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path);
bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path);

void GBA_Reset(GBACoreHandle* handle);
void GBA_StepFrame(GBACoreHandle* handle);
void GBA_SetKeys(GBACoreHandle* handle, uint16_t keys_pressed_mask);

size_t GBA_GetFrameBufferSize(GBACoreHandle* handle);
const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* out_size);
bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* out_pixels, size_t out_size);

const char* GBA_GetLastError(GBACoreHandle* handle);

#ifdef __cplusplus
}
#endif
