#include "../gba_platform.h"
#include "../gba_platform_gp2x.h"

#include <pthread.h>
#include <sys/select.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

struct GBA_Mutex {
  pthread_mutex_t impl;
};

struct GBA_Cond {
  pthread_cond_t impl;
};

struct GBA_Joystick {
  int index;
};

typedef struct AudioRuntime {
  GBA_AudioSpec spec;
  pthread_t thread;
  int thread_started;
  int running;
  int paused;
  Uint8 *mix_buffer;
  size_t mix_size;
  GBA_Mutex *lock;
} AudioRuntime;

static AudioRuntime g_audio;

static void SleepForMilliseconds(Uint32 ms) {
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

int GBA_Init(Uint32 flags) {
  (void)flags;
  return 0;
}

void GBA_Quit(void) {
  GBA_CloseAudio();
}

int GBA_PollEvent(GBA_Event *event) {
  (void)event;
  return 0;
}

int GBA_NumJoysticks(void) { return 0; }

GBA_Joystick *GBA_JoystickOpen(int index) {
  GBA_Joystick *joy = (GBA_Joystick *)calloc(1, sizeof(GBA_Joystick));
  if (joy) joy->index = index;
  return joy;
}

int GBA_JoystickEventState(int state) { return state; }

GBA_Surface *GBA_SetVideoMode(int w, int h, int bpp, Uint32 flags) {
  (void)bpp;
  (void)flags;
  GBA_Surface *s = (GBA_Surface *)calloc(1, sizeof(GBA_Surface));
  if (!s) return NULL;
  s->w = w;
  s->h = h;
  s->pitch = w * 2;
  s->pixels = calloc((size_t)h, (size_t)s->pitch);
  return s;
}

GBA_Surface *GBA_CreateRGBSurface(Uint32 flags, int w, int h, int depth,
                                  Uint32 rmask, Uint32 gmask, Uint32 bmask, Uint32 amask) {
  (void)flags; (void)depth; (void)rmask; (void)gmask; (void)bmask; (void)amask;
  return GBA_SetVideoMode(w, h, depth, 0);
}

int GBA_BlitSurface(GBA_Surface *src, const GBA_Rect *srcrect, GBA_Surface *dst, GBA_Rect *dstrect) {
  (void)srcrect;
  (void)dstrect;
  if (!src || !dst || !src->pixels || !dst->pixels) return -1;
  const int copy_h = (src->h < dst->h) ? src->h : dst->h;
  const int copy_pitch = (src->pitch < dst->pitch) ? src->pitch : dst->pitch;
  for (int y = 0; y < copy_h; ++y) {
    memcpy((Uint8*)dst->pixels + (size_t)y * (size_t)dst->pitch,
           (const Uint8*)src->pixels + (size_t)y * (size_t)src->pitch,
           (size_t)copy_pitch);
  }
  return 0;
}

int GBA_Flip(GBA_Surface *screen) {
  (void)screen;
  return 0;
}

void GBA_FreeSurface(GBA_Surface *surface) {
  if (!surface) return;
  free(surface->pixels);
  free(surface);
}

int GBA_ShowCursor(int toggle) { return toggle; }

void GBA_SetCaption(const char *title, const char *icon) {
  (void)title;
  (void)icon;
}

GBA_Mutex *GBA_CreateMutex(void) {
  GBA_Mutex *m = (GBA_Mutex *)calloc(1, sizeof(GBA_Mutex));
  if (!m) return NULL;
  if (pthread_mutex_init(&m->impl, NULL) != 0) {
    free(m);
    return NULL;
  }
  return m;
}

void GBA_DestroyMutex(GBA_Mutex *mutex) {
  if (!mutex) return;
  pthread_mutex_destroy(&mutex->impl);
  free(mutex);
}

int GBA_LockMutex(GBA_Mutex *mutex) {
  if (!mutex) return 0;
  return pthread_mutex_lock(&mutex->impl);
}

int GBA_UnlockMutex(GBA_Mutex *mutex) {
  if (!mutex) return 0;
  return pthread_mutex_unlock(&mutex->impl);
}

GBA_Cond *GBA_CreateCond(void) {
  GBA_Cond *c = (GBA_Cond *)calloc(1, sizeof(GBA_Cond));
  if (!c) return NULL;
  if (pthread_cond_init(&c->impl, NULL) != 0) {
    free(c);
    return NULL;
  }
  return c;
}

void GBA_DestroyCond(GBA_Cond *cond) {
  if (!cond) return;
  pthread_cond_destroy(&cond->impl);
  free(cond);
}

int GBA_CondWait(GBA_Cond *cond, GBA_Mutex *mutex) {
  if (!cond || !mutex) return -1;
  return pthread_cond_wait(&cond->impl, &mutex->impl);
}

int GBA_CondSignal(GBA_Cond *cond) {
  if (!cond) return -1;
  return pthread_cond_signal(&cond->impl);
}

int GBA_OpenAudio(GBA_AudioSpec *desired, GBA_AudioSpec *obtained) {
  if (!desired) return -1;

  memset(&g_audio, 0, sizeof(g_audio));
  g_audio.spec = *desired;
  if (g_audio.spec.samples == 0) g_audio.spec.samples = 1024;
  if (g_audio.spec.channels == 0) g_audio.spec.channels = 2;
  g_audio.spec.size = (Uint32)g_audio.spec.samples * (Uint32)g_audio.spec.channels * 2u;
  g_audio.mix_size = g_audio.spec.size;
  g_audio.mix_buffer = (Uint8 *)calloc(1, g_audio.mix_size);
  g_audio.lock = GBA_CreateMutex();
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
  GBA_DestroyMutex(g_audio.lock);
  g_audio.lock = NULL;
  free(g_audio.mix_buffer);
  g_audio.mix_buffer = NULL;
  return -1;
}

void GBA_CloseAudio(void) {
  if (!g_audio.running && !g_audio.thread_started) return;
  g_audio.running = 0;
  if (g_audio.thread_started) {
    pthread_join(g_audio.thread, NULL);
  }
  g_audio.thread_started = 0;
  GBA_DestroyMutex(g_audio.lock);
  g_audio.lock = NULL;
  free(g_audio.mix_buffer);
  g_audio.mix_buffer = NULL;
}

void GBA_PauseAudio(int pause_on) {
  g_audio.paused = (pause_on != 0);
}

Uint32 GBA_GetTicks(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (Uint32)((tv.tv_sec * 1000ull) + ((uint64_t)tv.tv_usec / 1000ull));
}

void GBA_Delay(Uint32 ms) {
  SleepForMilliseconds(ms);
}

void GBA_GP2X_AllowGfxMemory(void *ptr, int size) {
  (void)ptr;
  (void)size;
}
