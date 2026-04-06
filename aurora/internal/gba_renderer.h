#ifndef AURORA_INTERNAL_GBA_RENDERER_H
#define AURORA_INTERNAL_GBA_RENDERER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void AuroraRenderSoftwareFrameFromSource(const uint16_t *src,
                                         uint16_t *dst,
                                         uint32_t width,
                                         uint32_t height,
                                         uint32_t src_pitch_pixels);

#ifdef __cplusplus
}
#endif

#endif
