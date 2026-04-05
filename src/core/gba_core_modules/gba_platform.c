#include "../gba_platform.h"

#include <pthread.h>
#include <sys/select.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

struct PlatformMutex {
  pthread_mutex_t impl;
};

struct PlatformCond {
  pthread_cond_t impl;
};

struct PlatformJoystick {
  int index;
};

typedef struct AudioRuntime {
  PlatformAudioSpec spec;
  pthread_t thread;
  int thread_started;
  int running;
  int paused;
  uint8_t *mix_buffer;
  size_t mix_size;
  PlatformMutex *lock;
} AudioRuntime;

static AudioRuntime g_audio;

static void SleepForMilliseconds(uint32_t ms) {
  struct timeval tv;
  tv.tv_sec = (time_t)(ms / 1000u);
  tv.tv_usec = (suseconds_t)((ms % 1000u) * 1000u);
  select(0, NULL, NULL, NULL, &tv);
}

static void* AudioThreadMain(void* arg) {
  (void)arg;
  while (g_audio.running) {
    if (!g_audio.paused && g_audio.spec.callback && g_audio.mix_buffer && g_audio.mix_size) {
      g_audio.spec.callback(g_audio.spec.userdata, g_audio.mix_buffer, (int)g_audio.mix_size);
    }
    SleepForMilliseconds(1);
  }
  return NULL;
}

int PlatformInit(uint32_t flags) {
  (void)flags;
  return 0;
}

void gpsp_plat_init(void) {
  (void)PlatformInit(0);
}

void PlatformQuit(void) {
  PlatformCloseAudio();
}

void gpsp_plat_quit(void) {
  PlatformQuit();
}

int PlatformPollEvent(PlatformEvent *event) {
  (void)event;
  return 0;
}

int PlatformNumJoysticks(void) { return 0; }

PlatformJoystick *PlatformJoystickOpen(int index) {
  PlatformJoystick *joy = (PlatformJoystick *)calloc(1, sizeof(PlatformJoystick));
  if (joy) joy->index = index;
  return joy;
}

int PlatformJoystickEventState(int state) { return state; }

PlatformSurface *PlatformSetVideoMode(int w, int h, int bpp, uint32_t flags) {
  (void)bpp;
  (void)flags;
  PlatformSurface *s = (PlatformSurface *)calloc(1, sizeof(PlatformSurface));
  if (!s) return NULL;
  s->w = w;
  s->h = h;
  s->pitch = w * 2;
  s->pixels = calloc((size_t)h, (size_t)s->pitch);
  return s;
}

PlatformSurface *PlatformCreateRGBSurface(uint32_t flags, int w, int h, int depth,
                                  uint32_t rmask, uint32_t gmask, uint32_t bmask, uint32_t amask) {
  (void)flags; (void)depth; (void)rmask; (void)gmask; (void)bmask; (void)amask;
  return PlatformSetVideoMode(w, h, depth, 0);
}

int PlatformBlitSurface(PlatformSurface *src, const PlatformRect *srcrect, PlatformSurface *dst, PlatformRect *dstrect) {
  (void)srcrect;
  (void)dstrect;
  if (!src || !dst || !src->pixels || !dst->pixels) return -1;
  const int copy_h = (src->h < dst->h) ? src->h : dst->h;
  const int copy_pitch = (src->pitch < dst->pitch) ? src->pitch : dst->pitch;
  for (int y = 0; y < copy_h; ++y) {
    memcpy((uint8_t*)dst->pixels + (size_t)y * (size_t)dst->pitch,
           (const uint8_t*)src->pixels + (size_t)y * (size_t)src->pitch,
           (size_t)copy_pitch);
  }
  return 0;
}

int PlatformFlip(PlatformSurface *screen) {
  (void)screen;
  return 0;
}

void PlatformFreeSurface(PlatformSurface *surface) {
  if (!surface) return;
  free(surface->pixels);
  free(surface);
}

int PlatformShowCursor(int toggle) { return toggle; }

void PlatformSetCaption(const char *title, const char *icon) {
  (void)title;
  (void)icon;
}

PlatformMutex *PlatformCreateMutex(void) {
  PlatformMutex *m = (PlatformMutex *)calloc(1, sizeof(PlatformMutex));
  if (!m) return NULL;
  if (pthread_mutex_init(&m->impl, NULL) != 0) {
    free(m);
    return NULL;
  }
  return m;
}

void PlatformDestroyMutex(PlatformMutex *mutex) {
  if (!mutex) return;
  pthread_mutex_destroy(&mutex->impl);
  free(mutex);
}

int PlatformLockMutex(PlatformMutex *mutex) {
  if (!mutex) return 0;
  return pthread_mutex_lock(&mutex->impl);
}

int PlatformUnlockMutex(PlatformMutex *mutex) {
  if (!mutex) return 0;
  return pthread_mutex_unlock(&mutex->impl);
}

PlatformCond *PlatformCreateCond(void) {
  PlatformCond *c = (PlatformCond *)calloc(1, sizeof(PlatformCond));
  if (!c) return NULL;
  if (pthread_cond_init(&c->impl, NULL) != 0) {
    free(c);
    return NULL;
  }
  return c;
}

void PlatformDestroyCond(PlatformCond *cond) {
  if (!cond) return;
  pthread_cond_destroy(&cond->impl);
  free(cond);
}

int PlatformCondWait(PlatformCond *cond, PlatformMutex *mutex) {
  if (!cond || !mutex) return -1;
  return pthread_cond_wait(&cond->impl, &mutex->impl);
}

int PlatformCondSignal(PlatformCond *cond) {
  if (!cond) return -1;
  return pthread_cond_signal(&cond->impl);
}

int PlatformOpenAudio(PlatformAudioSpec *desired, PlatformAudioSpec *obtained) {
  if (!desired) return -1;

  memset(&g_audio, 0, sizeof(g_audio));
  g_audio.spec = *desired;
  if (g_audio.spec.samples == 0) g_audio.spec.samples = 1024;
  if (g_audio.spec.channels == 0) g_audio.spec.channels = 2;
  g_audio.spec.size = (uint32_t)g_audio.spec.samples * (uint32_t)g_audio.spec.channels * 2u;
  g_audio.mix_size = g_audio.spec.size;
  g_audio.mix_buffer = (uint8_t *)calloc(1, g_audio.mix_size);
  g_audio.lock = PlatformCreateMutex();
  g_audio.paused = 1;
  g_audio.running = 1;

  if (obtained) {
    *obtained = g_audio.spec;
  }

  if (pthread_create(&g_audio.thread, NULL, AudioThreadMain, NULL) == 0) {
    g_audio.thread_started = 1;
    return 0;
  }

  g_audio.running = 0;
  PlatformDestroyMutex(g_audio.lock);
  g_audio.lock = NULL;
  free(g_audio.mix_buffer);
  g_audio.mix_buffer = NULL;
  return -1;
}

void PlatformCloseAudio(void) {
  if (!g_audio.running && !g_audio.thread_started) return;
  g_audio.running = 0;
  if (g_audio.thread_started) {
    pthread_join(g_audio.thread, NULL);
  }
  g_audio.thread_started = 0;
  PlatformDestroyMutex(g_audio.lock);
  g_audio.lock = NULL;
  free(g_audio.mix_buffer);
  g_audio.mix_buffer = NULL;
}

void PlatformPauseAudio(int pause_on) {
  g_audio.paused = (pause_on != 0);
}

uint32_t PlatformGetTicks(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint32_t)((tv.tv_sec * 1000ull) + ((uint64_t)tv.tv_usec / 1000ull));
}

void PlatformDelay(uint32_t ms) {
  SleepForMilliseconds(ms);
}

void PlatformAllowGfxMemory(void *ptr, int size) {
  (void)ptr;
  (void)size;
}

int GBA_Init(uint32_t flags) { return PlatformInit(flags); }
void GBA_Quit(void) { PlatformQuit(); }
int GBA_PollEvent(PlatformEvent *event) { return PlatformPollEvent(event); }
int GBA_NumJoysticks(void) { return PlatformNumJoysticks(); }
PlatformJoystick *GBA_JoystickOpen(int index) { return PlatformJoystickOpen(index); }
int GBA_JoystickEventState(int state) { return PlatformJoystickEventState(state); }
PlatformSurface *GBA_SetVideoMode(int w, int h, int bpp, uint32_t flags) { return PlatformSetVideoMode(w, h, bpp, flags); }
PlatformSurface *GBA_CreateRGBSurface(uint32_t flags, int w, int h, int depth,
                                      uint32_t rmask, uint32_t gmask, uint32_t bmask, uint32_t amask) {
  return PlatformCreateRGBSurface(flags, w, h, depth, rmask, gmask, bmask, amask);
}
int GBA_BlitSurface(PlatformSurface *src, const PlatformRect *srcrect, PlatformSurface *dst, PlatformRect *dstrect) {
  return PlatformBlitSurface(src, srcrect, dst, dstrect);
}
int GBA_Flip(PlatformSurface *screen) { return PlatformFlip(screen); }
void GBA_FreeSurface(PlatformSurface *surface) { PlatformFreeSurface(surface); }
int GBA_ShowCursor(int toggle) { return PlatformShowCursor(toggle); }
void GBA_SetCaption(const char *title, const char *icon) { PlatformSetCaption(title, icon); }
PlatformMutex *GBA_CreateMutex(void) { return PlatformCreateMutex(); }
void GBA_DestroyMutex(PlatformMutex *mutex) { PlatformDestroyMutex(mutex); }
int GBA_LockMutex(PlatformMutex *mutex) { return PlatformLockMutex(mutex); }
int GBA_UnlockMutex(PlatformMutex *mutex) { return PlatformUnlockMutex(mutex); }
PlatformCond *GBA_CreateCond(void) { return PlatformCreateCond(); }
void GBA_DestroyCond(PlatformCond *cond) { PlatformDestroyCond(cond); }
int GBA_CondWait(PlatformCond *cond, PlatformMutex *mutex) { return PlatformCondWait(cond, mutex); }
int GBA_CondSignal(PlatformCond *cond) { return PlatformCondSignal(cond); }
int GBA_OpenAudio(PlatformAudioSpec *desired, PlatformAudioSpec *obtained) { return PlatformOpenAudio(desired, obtained); }
void GBA_CloseAudio(void) { PlatformCloseAudio(); }
void GBA_PauseAudio(int pause_on) { PlatformPauseAudio(pause_on); }
uint32_t GBA_GetTicks(void) { return PlatformGetTicks(); }
void GBA_Delay(uint32_t ms) { PlatformDelay(ms); }
