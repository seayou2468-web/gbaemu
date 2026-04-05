#ifndef GBA_CORE_PLATFORM_H
#define GBA_CORE_PLATFORM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t Uint8;
typedef uint16_t Uint16;
typedef uint32_t Uint32;
typedef int16_t Sint16;
typedef int32_t Sint32;

typedef int GBAKey;
typedef struct GBA_Mutex GBA_Mutex;
typedef struct GBA_Cond GBA_Cond;
typedef struct GBA_Joystick GBA_Joystick;

typedef struct GBA_Rect {
  Sint16 x, y;
  Uint16 w, h;
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
  Uint8 type;
  GBA_keysym keysym;
} GBA_KeyboardEvent;

typedef struct GBA_JoyButtonEvent {
  Uint8 type;
  Uint8 button;
} GBA_JoyButtonEvent;

typedef struct GBA_JoyAxisEvent {
  Uint8 type;
  Uint8 axis;
  Sint16 value;
} GBA_JoyAxisEvent;

typedef union GBA_Event {
  Uint8 type;
  GBA_KeyboardEvent key;
  GBA_JoyButtonEvent jbutton;
  GBA_JoyAxisEvent jaxis;
} GBA_Event;

typedef void (*GBA_AudioCallback)(void *userdata, Uint8 *stream, int len);
typedef struct GBA_AudioSpec {
  int freq;
  Uint16 format;
  Uint8 channels;
  Uint8 silence;
  Uint16 samples;
  Uint16 padding;
  Uint32 size;
  GBA_AudioCallback callback;
  void *userdata;
} GBA_AudioSpec;

#define GBA_INIT_VIDEO 0x00000020u
#define GBA_INIT_JOYSTICK 0x00000200u
#define GBA_INIT_NOPARACHUTE 0x00100000u

#define GBA_HWSURFACE 0x00000001u
#define GBA_ENABLE 1

#define AUDIO_S16 0x8010

#define GBA_QUIT 0x100
#define GBA_KEYDOWN 0x300
#define GBA_KEYUP 0x301
#define GBA_JOYAXISMOTION 0x600
#define GBA_JOYBUTTONDOWN 0x601
#define GBA_JOYBUTTONUP 0x602

#define GBAK_ESCAPE 27
#define GBAK_RETURN 13
#define GBAK_BACKSPACE 8
#define GBAK_BACKQUOTE '`'
#define GBAK_UP 273
#define GBAK_DOWN 274
#define GBAK_RIGHT 275
#define GBAK_LEFT 276
#define GBAK_LSHIFT 304
#define GBAK_RSHIFT 303
#define GBAK_LCTRL 306
#define GBAK_LALT 308
#define GBAK_F1 282
#define GBAK_F2 283
#define GBAK_F3 284
#define GBAK_F5 286
#define GBAK_F7 288
#define GBAK_F10 291
#define GBAK_a 'a'
#define GBAK_s 's'
#define GBAK_x 'x'
#define GBAK_z 'z'

int GBA_Init(Uint32 flags);
void GBA_Quit(void);
int GBA_PollEvent(GBA_Event *event);
int GBA_NumJoysticks(void);
GBA_Joystick *GBA_JoystickOpen(int index);
int GBA_JoystickEventState(int state);

GBA_Surface *GBA_SetVideoMode(int w, int h, int bpp, Uint32 flags);
GBA_Surface *GBA_CreateRGBSurface(Uint32 flags, int w, int h, int depth,
                                  Uint32 rmask, Uint32 gmask, Uint32 bmask, Uint32 amask);
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

Uint32 GBA_GetTicks(void);
void GBA_Delay(Uint32 ms);

#ifdef __cplusplus
}
#endif

#endif
