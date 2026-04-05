#pragma once
// Platform abstraction layer.

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int GBAKey;
typedef struct GBA_Mutex GBA_Mutex;
typedef struct GBA_Cond GBA_Cond;
typedef struct GBA_Joystick GBA_Joystick;

typedef struct GBA_Rect {
  int16_t x, y;
  uint16_t w, h;
} GBA_Rect;

typedef struct GBA_Surface {
  int w;
  int h;
  int pitch;
  void *pixels;
} GBA_Surface;

typedef struct GBA_keysym {
  GBAKey sym;
} GBA_keysym;

typedef struct GBA_KeyboardEvent {
  uint8_t type;
  GBA_keysym keysym;
} GBA_KeyboardEvent;

typedef struct GBA_JoyButtonEvent {
  uint8_t type;
  uint8_t button;
} GBA_JoyButtonEvent;

typedef struct GBA_JoyAxisEvent {
  uint8_t type;
  uint8_t axis;
  int16_t value;
} GBA_JoyAxisEvent;

typedef union GBA_Event {
  uint8_t type;
  GBA_KeyboardEvent key;
  GBA_JoyButtonEvent jbutton;
  GBA_JoyAxisEvent jaxis;
} GBA_Event;

typedef void (*GBA_AudioCallback)(void *userdata, uint8_t *stream, int len);
typedef struct GBA_AudioSpec {
  int freq;
  uint16_t format;
  uint8_t channels;
  uint8_t silence;
  uint16_t samples;
  uint16_t padding;
  uint32_t size;
  GBA_AudioCallback callback;
  void *userdata;
} GBA_AudioSpec;

int GBA_Init(uint32_t flags);
void GBA_Quit(void);
int GBA_PollEvent(GBA_Event *event);
int GBA_NumJoysticks(void);
GBA_Joystick *GBA_JoystickOpen(int index);
int GBA_JoystickEventState(int state);

GBA_Surface *GBA_SetVideoMode(int w, int h, int bpp, uint32_t flags);
GBA_Surface *GBA_CreateRGBSurface(uint32_t flags, int w, int h, int depth,
                                  uint32_t rmask, uint32_t gmask, uint32_t bmask, uint32_t amask);
int GBA_BlitSurface(GBA_Surface *src, const GBA_Rect *srcrect, GBA_Surface *dst, GBA_Rect *dstrect);
int GBA_Flip(GBA_Surface *screen);
void GBA_FreeSurface(GBA_Surface *surface);
int GBA_ShowCursor(int toggle);
void GBA_SetCaption(const char *title, const char *icon);

GBA_Mutex *GBA_CreateMutex(void);
void GBA_DestroyMutex(GBA_Mutex *mutex);
int GBA_LockMutex(GBA_Mutex *mutex);
int GBA_UnlockMutex(GBA_Mutex *mutex);

GBA_Cond *GBA_CreateCond(void);
void GBA_DestroyCond(GBA_Cond *cond);
int GBA_CondWait(GBA_Cond *cond, GBA_Mutex *mutex);
int GBA_CondSignal(GBA_Cond *cond);

int GBA_OpenAudio(GBA_AudioSpec *desired, GBA_AudioSpec *obtained);
void GBA_CloseAudio(void);
void GBA_PauseAudio(int pause_on);

uint32_t GBA_GetTicks(void);
void GBA_Delay(uint32_t ms);

void gpsp_plat_init(void);
void gpsp_plat_quit(void);

#ifdef __cplusplus
}

#endif
