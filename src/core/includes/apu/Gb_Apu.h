#ifndef GBAEMU_APU_GB_APU_H
#define GBAEMU_APU_GB_APU_H

#ifdef __cplusplus

#include "Blip_Buffer.h"

struct gb_apu_state_t {
    unsigned char regs[0x80] = {};
};

class Gb_Apu {
public:
    static constexpr int mode_agb = 1;
    static constexpr long clock_rate = 1 << 21;

    void write_register(blip_time_t, int, int) {}
    void volume(float) {}
    void end_frame(blip_time_t) {}
    void set_output(Blip_Buffer*, Blip_Buffer*, Blip_Buffer*, int) {}
    void reset(int, bool) {}
    void save_state(gb_apu_state_t*) const {}
    void load_state(const gb_apu_state_t&) {}
};

#endif

#endif
