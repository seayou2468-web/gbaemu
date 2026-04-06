#ifndef GBAEMU_APU_BLIP_BUFFER_H
#define GBAEMU_APU_BLIP_BUFFER_H

#ifdef __cplusplus

typedef int blip_time_t;
typedef short blip_sample_t;

struct blip_eq_t {
    blip_eq_t(int, int, int, int) {}
};

class Blip_Buffer {
public:
    Blip_Buffer() = default;
};

enum { blip_best_quality = 0 };

template<int quality, int range>
class Blip_Synth {
public:
    void offset(blip_time_t, int, Blip_Buffer*) {}
    void volume(float) {}
    void treble_eq(const blip_eq_t&) {}
};

#endif

#endif
