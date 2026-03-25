#ifndef GBA_CORE_C_API_H
#define GBA_CORE_C_API_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GBACoreHandle GBACoreHandle;

GBACoreHandle* GBA_Create(void);
void GBA_Destroy(GBACoreHandle* handle);

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* rom_path);
bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* bios_path);
void GBA_LoadBuiltInBIOS(GBACoreHandle* handle);
void GBA_Reset(GBACoreHandle* handle);
void GBA_StepFrame(GBACoreHandle* handle);
size_t GBA_GetFrameBufferSize(const GBACoreHandle* handle);
bool GBA_CopyFrameBufferRGBA(const GBACoreHandle* handle, uint32_t* out_pixels, size_t pixel_count);

const char* GBA_GetLastError(const GBACoreHandle* handle);

#ifdef __cplusplus
}
#endif

#endif
