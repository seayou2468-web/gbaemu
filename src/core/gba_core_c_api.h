#pragma once

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GBACoreHandle GBACoreHandle;

GBACoreHandle* GBA_Create(void);
void GBA_Destroy(GBACoreHandle* handle);

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path);
bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path);
void GBA_LoadBuiltInBIOS(GBACoreHandle* handle);

void GBA_Reset(GBACoreHandle* handle);
void GBA_StepFrame(GBACoreHandle* handle);
void GBA_SetKeys(GBACoreHandle* handle, uint16_t keysPressedMask);

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* pixelCount);
size_t GBA_GetFrameBufferSize(GBACoreHandle* handle);
bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* dst, size_t pixels);

const char* GBA_GetLastError(GBACoreHandle* handle);

#ifdef __cplusplus
}
#endif
