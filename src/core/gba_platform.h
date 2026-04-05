#pragma once
// Platform abstraction layer.

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int PlatformKey;
typedef struct PlatformMutex PlatformMutex;
typedef struct PlatformCond PlatformCond;
typedef struct PlatformJoystick PlatformJoystick;

typedef struct PlatformRect {
  int16_t x, y;
  uint16_t w, h;
} PlatformRect;

typedef struct PlatformSurface {
  int w;
  int h;
  int pitch;
  void *pixels;
} PlatformSurface;

typedef struct PlatformKeysym {
  PlatformKey sym;
} PlatformKeysym;

typedef struct PlatformKeyboardEvent {
  uint8_t type;
  PlatformKeysym keysym;
} PlatformKeyboardEvent;

typedef struct PlatformJoyButtonEvent {
  uint8_t type;
  uint8_t button;
} PlatformJoyButtonEvent;

typedef struct PlatformJoyAxisEvent {
  uint8_t type;
  uint8_t axis;
  int16_t value;
} PlatformJoyAxisEvent;

typedef union PlatformEvent {
  uint8_t type;
  PlatformKeyboardEvent key;
  PlatformJoyButtonEvent jbutton;
  PlatformJoyAxisEvent jaxis;
} PlatformEvent;

typedef void (*PlatformAudioCallback)(void *userdata, uint8_t *stream, int len);
typedef struct PlatformAudioSpec {
  int freq;
  uint16_t format;
  uint8_t channels;
  uint8_t silence;
  uint16_t samples;
  uint16_t padding;
  uint32_t size;
  PlatformAudioCallback callback;
  void *userdata;
} PlatformAudioSpec;

int PlatformInit(uint32_t flags);
void PlatformQuit(void);
int PlatformPollEvent(PlatformEvent *event);
int PlatformNumJoysticks(void);
PlatformJoystick *PlatformJoystickOpen(int index);
int PlatformJoystickEventState(int state);

PlatformSurface *PlatformSetVideoMode(int w, int h, int bpp, uint32_t flags);
PlatformSurface *PlatformCreateRGBSurface(uint32_t flags, int w, int h, int depth,
                                  uint32_t rmask, uint32_t gmask, uint32_t bmask, uint32_t amask);
int PlatformBlitSurface(PlatformSurface *src, const PlatformRect *srcrect, PlatformSurface *dst, PlatformRect *dstrect);
int PlatformFlip(PlatformSurface *screen);
void PlatformFreeSurface(PlatformSurface *surface);
int PlatformShowCursor(int toggle);
void PlatformSetCaption(const char *title, const char *icon);

PlatformMutex *PlatformCreateMutex(void);
void PlatformDestroyMutex(PlatformMutex *mutex);
int PlatformLockMutex(PlatformMutex *mutex);
int PlatformUnlockMutex(PlatformMutex *mutex);

PlatformCond *PlatformCreateCond(void);
void PlatformDestroyCond(PlatformCond *cond);
int PlatformCondWait(PlatformCond *cond, PlatformMutex *mutex);
int PlatformCondSignal(PlatformCond *cond);

int PlatformOpenAudio(PlatformAudioSpec *desired, PlatformAudioSpec *obtained);
void PlatformCloseAudio(void);
void PlatformPauseAudio(int pause_on);

uint32_t PlatformGetTicks(void);
void PlatformDelay(uint32_t ms);

void gpsp_plat_init(void);
void gpsp_plat_quit(void);

#ifdef __cplusplus
}

#endif
