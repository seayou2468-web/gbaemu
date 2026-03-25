#include "gba_core_c_api.h"

#include <algorithm>
#include <cstdint>
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

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* bios_path) {
  if (handle == nullptr || bios_path == nullptr) {
    return false;
  }

  handle->last_error.clear();
  std::vector<uint8_t> bios_buffer;
  if (!gba::LoadFile(std::string(bios_path), &bios_buffer, &handle->last_error) ||
      bios_buffer.empty()) {
    if (handle->last_error.empty()) {
      handle->last_error = "BIOS file loading failed";
    }
    return false;
  }

  if (!handle->core.LoadBIOS(bios_buffer, &handle->last_error)) {
    if (handle->last_error.empty()) {
      handle->last_error = "Core BIOS loading failed";
    }
    return false;
  }

  return true;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
  if (handle == nullptr) {
    return;
  }
  handle->core.LoadBuiltInBIOS();
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

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keys_pressed_mask) {
  if (handle == nullptr) {
    return;
  }
  handle->core.SetKeys(keys_pressed_mask);
}

size_t GBA_GetFrameBufferSize(const GBACoreHandle* handle) {
  if (handle == nullptr) {
    return 0;
  }
  return handle->core.GetFrameBuffer().size();
}

bool GBA_CopyFrameBufferRGBA(const GBACoreHandle* handle, uint32_t* out_pixels, size_t pixel_count) {
  if (handle == nullptr || out_pixels == nullptr) {
    return false;
  }
  const std::vector<uint32_t>& frame = handle->core.GetFrameBuffer();
  if (frame.empty() || pixel_count < frame.size()) {
    return false;
  }
  std::copy(frame.begin(), frame.end(), out_pixels);
  return true;
}

const char* GBA_GetLastError(const GBACoreHandle* handle) {
  if (handle == nullptr) {
    return "Invalid core handle";
  }
  return handle->last_error.c_str();
}
