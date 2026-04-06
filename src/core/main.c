#include <SDL2/SDL.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "./gba_core_c_api.h"

enum {
  GBA_KEY_A = 1 << 0,
  GBA_KEY_B = 1 << 1,
  GBA_KEY_SELECT = 1 << 2,
  GBA_KEY_START = 1 << 3,
  GBA_KEY_RIGHT = 1 << 4,
  GBA_KEY_LEFT = 1 << 5,
  GBA_KEY_UP = 1 << 6,
  GBA_KEY_DOWN = 1 << 7,
  GBA_KEY_R = 1 << 8,
  GBA_KEY_L = 1 << 9,
};

static uint16_t BuildKeyMask(const Uint8* keys) {
  uint16_t mask = 0;
  if (keys[SDL_SCANCODE_Z]) mask |= GBA_KEY_A;
  if (keys[SDL_SCANCODE_X]) mask |= GBA_KEY_B;
  if (keys[SDL_SCANCODE_BACKSPACE]) mask |= GBA_KEY_SELECT;
  if (keys[SDL_SCANCODE_RETURN]) mask |= GBA_KEY_START;
  if (keys[SDL_SCANCODE_RIGHT]) mask |= GBA_KEY_RIGHT;
  if (keys[SDL_SCANCODE_LEFT]) mask |= GBA_KEY_LEFT;
  if (keys[SDL_SCANCODE_UP]) mask |= GBA_KEY_UP;
  if (keys[SDL_SCANCODE_DOWN]) mask |= GBA_KEY_DOWN;
  if (keys[SDL_SCANCODE_S]) mask |= GBA_KEY_R;
  if (keys[SDL_SCANCODE_A]) mask |= GBA_KEY_L;
  return mask;
}

static void PrintUsage(const char* argv0) {
  printf("Usage: %s <rom_path> [bios_path]\n", argv0);
  printf("Controls: Z=A, X=B, Enter=Start, Backspace=Select, Arrows=DPad, A=L, S=R\n");
}

int main(int argc, char** argv) {
  if (argc < 2) {
    PrintUsage(argv[0]);
    return 1;
  }

  const char* rom_path = argv[1];
  const char* bios_path = (argc >= 3) ? argv[2] : NULL;

  GBACoreHandle* core = GBA_Create();
  if (core == NULL) {
    fprintf(stderr, "failed to create core\n");
    return 1;
  }

  if (bios_path != NULL) {
    if (!GBA_LoadBIOSFromPath(core, bios_path)) {
      fprintf(stderr, "failed to load BIOS: %s\n", GBA_GetLastError(core));
      GBA_Destroy(core);
      return 1;
    }
  } else {
    GBA_LoadBuiltInBIOS(core);
  }

  if (!GBA_LoadROMFromPath(core, rom_path)) {
    fprintf(stderr, "failed to load ROM: %s\n", GBA_GetLastError(core));
    GBA_Destroy(core);
    return 1;
  }

  GBA_Reset(core);
  if (GBA_GetLastError(core)[0] != '\0') {
    fprintf(stderr, "reset failed: %s\n", GBA_GetLastError(core));
    GBA_Destroy(core);
    return 1;
  }

  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
    fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
    GBA_Destroy(core);
    return 1;
  }

  const int screen_w = 240;
  const int screen_h = 160;
  const int window_scale = 3;
  SDL_Window* window = SDL_CreateWindow(
      "GBAEmu (Linux SDL)",
      SDL_WINDOWPOS_CENTERED,
      SDL_WINDOWPOS_CENTERED,
      screen_w * window_scale,
      screen_h * window_scale,
      SDL_WINDOW_SHOWN);
  if (window == NULL) {
    fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
    SDL_Quit();
    GBA_Destroy(core);
    return 1;
  }

  SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
  if (renderer == NULL) {
    fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
    SDL_DestroyWindow(window);
    SDL_Quit();
    GBA_Destroy(core);
    return 1;
  }

  SDL_Texture* texture = SDL_CreateTexture(
      renderer,
      SDL_PIXELFORMAT_ABGR8888,
      SDL_TEXTUREACCESS_STREAMING,
      screen_w,
      screen_h);
  if (texture == NULL) {
    fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError());
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    GBA_Destroy(core);
    return 1;
  }

  bool running = true;
  while (running) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
      if (event.type == SDL_QUIT) running = false;
    }

    const Uint8* keyboard = SDL_GetKeyboardState(NULL);
    GBA_SetKeys(core, BuildKeyMask(keyboard));

    GBA_StepFrame(core);
    if (GBA_GetLastError(core)[0] != '\0') {
      fprintf(stderr, "step failed: %s\n", GBA_GetLastError(core));
      running = false;
      break;
    }

    size_t pixel_count = 0;
    const uint32_t* pixels = GBA_GetFrameBufferRGBA(core, &pixel_count);
    if (pixels == NULL || pixel_count < (size_t)(screen_w * screen_h)) {
      fprintf(stderr, "framebuffer unavailable\n");
      running = false;
      break;
    }

    SDL_UpdateTexture(texture, NULL, pixels, screen_w * (int)sizeof(uint32_t));
    SDL_RenderClear(renderer);
    SDL_RenderCopy(renderer, texture, NULL, NULL);
    SDL_RenderPresent(renderer);
  }

  SDL_DestroyTexture(texture);
  SDL_DestroyRenderer(renderer);
  SDL_DestroyWindow(window);
  SDL_Quit();
  GBA_Destroy(core);
  return 0;
}
