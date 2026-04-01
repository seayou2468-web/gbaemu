// main.mm (SDL2 + GBAコア表示)

#include <SDL2/SDL.h>
#include <stdio.h>
#include <vector>
#include <stdint.h>

#include "./gba_core_c_api.h"

#define SCREEN_WIDTH 240
#define SCREEN_HEIGHT 160
#define SCALE 3

static uint16_t MapInput(const Uint8* keystate) {
    uint16_t keys = 0;

    if (keystate[SDL_SCANCODE_X]) keys |= (1 << 0); // A
    if (keystate[SDL_SCANCODE_Z]) keys |= (1 << 1); // B
    if (keystate[SDL_SCANCODE_RETURN]) keys |= (1 << 3); // START
    if (keystate[SDL_SCANCODE_RSHIFT]) keys |= (1 << 2); // SELECT

    if (keystate[SDL_SCANCODE_UP])    keys |= (1 << 6);
    if (keystate[SDL_SCANCODE_DOWN])  keys |= (1 << 7);
    if (keystate[SDL_SCANCODE_LEFT])  keys |= (1 << 5);
    if (keystate[SDL_SCANCODE_RIGHT]) keys |= (1 << 4);

    if (keystate[SDL_SCANCODE_A]) keys |= (1 << 9); // L
    if (keystate[SDL_SCANCODE_S]) keys |= (1 << 8); // R

    return keys;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("Usage: %s game.gba [bios.bin]\n", argv[0]);
        return 1;
    }

    const char* rom = argv[1];
    const char* bios = (argc >= 3) ? argv[2] : NULL;

    // --- GBA core ---
    GBACoreHandle* core = GBA_Create();
    if (!core) return 1;

    if (bios) {
        if (!GBA_LoadBIOSFromPath(core, bios)) {
            printf("BIOS error: %s\n", GBA_GetLastError(core));
            return 1;
        }
    } else {
        GBA_LoadBuiltInBIOS(core);
    }

    if (!GBA_LoadROMFromPath(core, rom)) {
        printf("ROM error: %s\n", GBA_GetLastError(core));
        return 1;
    }

    GBA_Reset(core);

    size_t fb_size = GBA_GetFrameBufferSize(core);
    std::vector<uint32_t> framebuffer(fb_size);

    // --- SDL ---
    SDL_Init(SDL_INIT_VIDEO);

    SDL_Window* window = SDL_CreateWindow(
        "GBA Core",
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        SCREEN_WIDTH * SCALE,
        SCREEN_HEIGHT * SCALE,
        0
    );

    SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);

    SDL_Texture* texture = SDL_CreateTexture(
        renderer,
        SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING,
        SCREEN_WIDTH,
        SCREEN_HEIGHT
    );

    bool running = true;
    SDL_Event e;

    uint32_t frame_delay = 1000 / 60;

    while (running) {
        uint32_t start = SDL_GetTicks();

        // --- イベント ---
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) {
                running = false;
            }
        }

        const Uint8* keystate = SDL_GetKeyboardState(NULL);
        uint16_t keys = MapInput(keystate);

        GBA_SetKeys(core, keys);
        GBA_StepFrame(core);

        if (!GBA_CopyFrameBufferRGBA(core, framebuffer.data(), framebuffer.size())) {
            printf("FB error: %s\n", GBA_GetLastError(core));
            break;
        }

        // --- 描画 ---
        SDL_UpdateTexture(texture, NULL, framebuffer.data(), SCREEN_WIDTH * sizeof(uint32_t));
        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, texture, NULL, NULL);
        SDL_RenderPresent(renderer);

        // --- 60FPS制御 ---
        uint32_t elapsed = SDL_GetTicks() - start;
        if (elapsed < frame_delay) {
            SDL_Delay(frame_delay - elapsed);
        }
    }

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    GBA_Destroy(core);
    return 0;
}
