#ifndef SDL_H
#define SDL_H

#include <stdint.h>

typedef uint32_t Uint32;
typedef int32_t Sint32;
typedef uint16_t Uint16;
typedef uint8_t Uint8;

typedef struct SDL_mutex SDL_mutex;
typedef struct SDL_cond SDL_cond;
typedef struct SDL_Joystick SDL_Joystick;

typedef struct SDL_Rect { int16_t x, y; uint16_t w, h; } SDL_Rect;
typedef struct SDL_Surface { void* pixels; int w; int h; int pitch; } SDL_Surface;

typedef struct SDL_keysym { int sym; } SDL_keysym;
typedef struct SDL_KeyboardEvent { SDL_keysym keysym; } SDL_KeyboardEvent;
typedef struct SDL_JoyButtonEvent { uint8_t button; } SDL_JoyButtonEvent;
typedef struct SDL_JoyAxisEvent { uint8_t axis; int16_t value; } SDL_JoyAxisEvent;

typedef struct SDL_Event {
  uint32_t type;
  SDL_KeyboardEvent key;
  SDL_JoyButtonEvent jbutton;
  SDL_JoyAxisEvent jaxis;
} SDL_Event;

typedef struct SDL_AudioSpec {
  int freq;
  Uint16 format;
  Uint8 channels;
  Uint16 samples;
  Uint32 size;
  void (*callback)(void*, Uint8*, int);
  void* userdata;
} SDL_AudioSpec;

typedef int SDLKey;

enum {
  SDL_INIT_VIDEO = 0x00000020,
  SDL_INIT_JOYSTICK = 0x00000200,
  SDL_INIT_NOPARACHUTE = 0x00100000,
  SDL_ENABLE = 1,
  SDL_HWSURFACE = 0x00000001,
  SDL_QUIT = 0x100,
  SDL_KEYDOWN = 0x300,
  SDL_KEYUP = 0x301,
  SDL_JOYAXISMOTION = 0x600,
  SDL_JOYBUTTONDOWN = 0x603,
  SDL_JOYBUTTONUP = 0x604,
  AUDIO_S16SYS = 0x8010,
};

enum {
  SDLK_ESCAPE = 27,
  SDLK_DOWN, SDLK_UP, SDLK_LEFT, SDLK_RIGHT,
  SDLK_RETURN, SDLK_BACKSPACE,
  SDLK_x, SDLK_z, SDLK_a, SDLK_s,
  SDLK_LSHIFT, SDLK_RSHIFT, SDLK_LCTRL, SDLK_LALT,
  SDLK_F1, SDLK_F2, SDLK_F3, SDLK_F5, SDLK_F7, SDLK_F10,
  SDLK_BACKQUOTE
};

int SDL_Init(Uint32 flags);
void SDL_Quit(void);
void SDL_Delay(Uint32 ms);
Uint32 SDL_GetTicks(void);
int SDL_PollEvent(SDL_Event* event);
int SDL_NumJoysticks(void);
SDL_Joystick* SDL_JoystickOpen(int index);
int SDL_JoystickEventState(int state);
SDL_Surface* SDL_SetVideoMode(int width, int height, int bpp, Uint32 flags);
SDL_Surface* SDL_CreateRGBSurface(Uint32 flags, int width, int height, int bpp, Uint32 Rmask, Uint32 Gmask, Uint32 Bmask, Uint32 Amask);
int SDL_BlitSurface(SDL_Surface* src, SDL_Rect* srcrect, SDL_Surface* dst, SDL_Rect* dstrect);
int SDL_Flip(SDL_Surface* screen);
void SDL_FreeSurface(SDL_Surface* surface);
int SDL_ShowCursor(int toggle);
void SDL_WM_SetCaption(const char* title, const char* icon);

SDL_mutex* SDL_CreateMutex(void);
void SDL_DestroyMutex(SDL_mutex* mutex);
int SDL_LockMutex(SDL_mutex* mutex);
int SDL_UnlockMutex(SDL_mutex* mutex);
SDL_cond* SDL_CreateCond(void);
void SDL_DestroyCond(SDL_cond* cond);
int SDL_CondWait(SDL_cond* cond, SDL_mutex* mutex);
int SDL_CondSignal(SDL_cond* cond);

int SDL_OpenAudio(SDL_AudioSpec* desired, SDL_AudioSpec* obtained);
void SDL_CloseAudio(void);
void SDL_PauseAudio(int pause_on);

#endif
