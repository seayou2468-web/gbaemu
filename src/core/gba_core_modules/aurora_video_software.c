#include "../common.h"
#include "../includes/memory.h"
#include <aurora/internal/gba_renderer.h>

#include <stdlib.h>
#include <string.h>

extern u32 instruction_count;
extern u32 frame_ticks;

/*
 * Unknown.zip renderers/software-mode0.c のタイル解決ロジックを簡易移植。
 * SDL依存なし（標準Cのみ）。
 */
#define DIRTY_SCANLINE(MAP, Y) ((MAP)[(Y) >> 5] |= (1U << ((Y) & 31)))
#define CLEAN_SCANLINE(MAP, Y) ((MAP)[(Y) >> 5] &= ~(1U << ((Y) & 31)))
#define IS_DIRTY_SCANLINE(MAP, Y) (((MAP)[(Y) >> 5] >> ((Y) & 31)) & 1U)

static uint16_t *s_prev_frame = NULL;
static uint32_t s_prev_width = 0;
static uint32_t s_prev_height = 0;
static uint32_t s_scanline_dirty[(160 + 31) / 32];
static uint32_t s_frame_counter = 0;

static void AuroraEnsureBuffers(uint32_t width, uint32_t height)
{
  if (s_prev_frame && s_prev_width == width && s_prev_height == height) {
    return;
  }

  free(s_prev_frame);
  s_prev_frame = (uint16_t *)malloc((size_t)width * (size_t)height * sizeof(uint16_t));
  s_prev_width = width;
  s_prev_height = height;
  memset(s_scanline_dirty, 0xFF, sizeof(s_scanline_dirty));
}

static inline uint16_t AuroraRenderMode0Bg0Pixel(uint32_t x, uint32_t y)
{
  const uint16_t bg0cnt = io_registers[REG_BG0CNT];
  const uint32_t char_base = ((bg0cnt >> 2) & 0x3) * 0x4000;
  const uint32_t screen_base = ((bg0cnt >> 8) & 0x1F) * 0x800;
  const uint32_t screen_size = (bg0cnt >> 14) & 0x3;

  const uint32_t hofs = io_registers[REG_BG0HOFS] & 0x1FF;
  const uint32_t vofs = io_registers[REG_BG0VOFS] & 0x1FF;

  const uint32_t sx = (x + hofs) & 0x1FF;
  const uint32_t sy = (y + vofs) & 0x1FF;

  const uint32_t tile_x = sx >> 3;
  const uint32_t tile_y = sy >> 3;

  uint32_t block = 0;
  if ((screen_size & 1) && tile_x >= 32) block += 1;
  if ((screen_size & 2) && tile_y >= 32) block += 2;

  const uint32_t local_x = tile_x & 31;
  const uint32_t local_y = tile_y & 31;
  const uint32_t map_index = block * 1024 + local_y * 32 + local_x;

  const uint16_t map_data = *(uint16_t *)&vram[screen_base + map_index * 2];

  uint32_t tx = sx & 7;
  uint32_t ty = sy & 7;
  if (map_data & (1 << 10)) tx = 7 - tx;
  if (map_data & (1 << 11)) ty = 7 - ty;

  const uint32_t tile = map_data & 0x3FF;
  const uint32_t pal_bank = (map_data >> 12) & 0xF;
  const uint32_t tile_addr = char_base + tile * 32 + ty * 4 + (tx >> 1);

  const uint8_t packed = vram[tile_addr];
  const uint8_t idx = (tx & 1) ? (packed >> 4) : (packed & 0x0F);
  const uint32_t pal_idx = idx ? (pal_bank * 16 + idx) : 0;
  return palette_ram_converted[pal_idx];
}

static inline uint16_t AuroraRenderMode3Pixel(uint32_t x, uint32_t y)
{
  const uint32_t addr = (y * 240 + x) * 2;
  return *(uint16_t *)&vram[addr];
}

static inline uint16_t AuroraRenderMode4Pixel(uint32_t x, uint32_t y, uint32_t frame_base)
{
  const uint32_t addr = frame_base + (y * 240 + x);
  const uint8_t index = vram[addr];
  return palette_ram_converted[index];
}

static inline uint16_t AuroraRenderMode5Pixel(uint32_t x, uint32_t y, uint32_t frame_base)
{
  if (x >= 160 || y >= 128) {
    return 0;
  }
  const uint32_t addr = frame_base + (y * 160 + x) * 2;
  return *(uint16_t *)&vram[addr];
}

void AuroraRenderSoftwareFrameFromSource(const uint16_t *src,
                                         uint16_t *dst,
                                         uint32_t width,
                                         uint32_t height,
                                         uint32_t src_pitch_pixels)
{
  if (!dst || width == 0 || height == 0) {
    return;
  }

  if (!src || src_pitch_pixels < width) {
    memset(dst, 0, (size_t)width * (size_t)height * sizeof(uint16_t));
    src = dst;
    src_pitch_pixels = width;
  }

  ++s_frame_counter;
  AuroraEnsureBuffers(width, height);
  if (!s_prev_frame) {
    return;
  }

  const uint16_t dispcnt = io_registers[REG_DISPCNT];
  const uint32_t mode = dispcnt & 0x7;
  const int bg0_enable = (dispcnt & 0x0100) != 0;

  if (0 && mode == 0 && bg0_enable) {
    for (uint32_t y = 0; y < height; ++y) {
      uint16_t *dst_row = dst + (size_t)y * width;
      for (uint32_t x = 0; x < width; ++x) {
        dst_row[x] = AuroraRenderMode0Bg0Pixel(x, y);
      }
      memcpy(s_prev_frame + (size_t)y * width, dst_row, (size_t)width * sizeof(uint16_t));
      CLEAN_SCANLINE(s_scanline_dirty, y);
    }
  } else if (mode == 3) {
    for (uint32_t y = 0; y < height; ++y) {
      uint16_t *dst_row = dst + (size_t)y * width;
      for (uint32_t x = 0; x < width; ++x) {
        dst_row[x] = AuroraRenderMode3Pixel(x, y);
      }
      memcpy(s_prev_frame + (size_t)y * width, dst_row, (size_t)width * sizeof(uint16_t));
      CLEAN_SCANLINE(s_scanline_dirty, y);
    }
  } else if (mode == 4) {
    const uint32_t frame_base = (dispcnt & 0x0010) ? 0xA000 : 0x0000;
    for (uint32_t y = 0; y < height; ++y) {
      uint16_t *dst_row = dst + (size_t)y * width;
      for (uint32_t x = 0; x < width; ++x) {
        dst_row[x] = AuroraRenderMode4Pixel(x, y, frame_base);
      }
      memcpy(s_prev_frame + (size_t)y * width, dst_row, (size_t)width * sizeof(uint16_t));
      CLEAN_SCANLINE(s_scanline_dirty, y);
    }
  } else if (mode == 5) {
    const uint32_t frame_base = (dispcnt & 0x0010) ? 0xA000 : 0x0000;
    for (uint32_t y = 0; y < height; ++y) {
      uint16_t *dst_row = dst + (size_t)y * width;
      for (uint32_t x = 0; x < width; ++x) {
        dst_row[x] = AuroraRenderMode5Pixel(x, y, frame_base);
      }
      memcpy(s_prev_frame + (size_t)y * width, dst_row, (size_t)width * sizeof(uint16_t));
      CLEAN_SCANLINE(s_scanline_dirty, y);
    }
  } else {
    for (uint32_t y = 0; y < height; ++y) {
      const uint16_t *src_row = src + (size_t)y * src_pitch_pixels;
      uint16_t *dst_row = dst + (size_t)y * width;
      uint16_t *prev_row = s_prev_frame + (size_t)y * width;

      if (memcmp(prev_row, src_row, (size_t)width * sizeof(uint16_t)) != 0) {
        DIRTY_SCANLINE(s_scanline_dirty, y);
        memcpy(prev_row, src_row, (size_t)width * sizeof(uint16_t));
        memcpy(dst_row, src_row, (size_t)width * sizeof(uint16_t));
      } else if (IS_DIRTY_SCANLINE(s_scanline_dirty, y)) {
        memcpy(dst_row, src_row, (size_t)width * sizeof(uint16_t));
        CLEAN_SCANLINE(s_scanline_dirty, y);
      } else {
        memcpy(dst_row, prev_row, (size_t)width * sizeof(uint16_t));
      }
    }
  }

}

