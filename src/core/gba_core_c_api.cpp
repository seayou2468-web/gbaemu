#include "gba_core_c_api.h"

#include <string>
#include <vector>

#include "gba_core.h"
#include "rom_loader.h"

struct GBACoreHandle {
  gba::GBACore core;
  std::vector<uint8_t> rom_buffer;
  std::string last_error;
};

GBACoreHandle* GBA_Create(void) {
  return new GBACoreHandle();
}

void GBA_Destroy(GBACoreHandle* handle) {
  delete handle;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* rom_path) {
  if (handle == nullptr || rom_path == nullptr) {
    return false;
  }

  handle->last_error.clear();
  if (!gba::LoadFile(std::string(rom_path), &handle->rom_buffer, &handle->last_error) ||
      handle->rom_buffer.empty()) {
    if (handle->last_error.empty()) {
      handle->last_error = "ROM file loading failed";
    }
    return false;
  }

  if (!handle->core.LoadROM(handle->rom_buffer, &handle->last_error)) {
    if (handle->last_error.empty()) {
      handle->last_error = "Core ROM loading failed";
    }
    return false;
  }

  return true;
}

void GBA_Reset(GBACoreHandle* handle) {
  if (handle == nullptr) {
    return;
  }
  handle->core.Reset();
}

void GBA_StepFrame(GBACoreHandle* handle) {
  if (handle == nullptr) {
    return;
  }
  handle->core.StepFrame();
}

const char* GBA_GetLastError(const GBACoreHandle* handle) {
  if (handle == nullptr) {
    return "Invalid core handle";
  }
  return handle->last_error.c_str();
}
