#ifndef GBAEMU_APU_MULTI_BUFFER_H
#define GBAEMU_APU_MULTI_BUFFER_H

#ifdef __cplusplus

#include "Blip_Buffer.h"

class Multi_Buffer {
public:
    virtual ~Multi_Buffer() = default;
    virtual long samples_avail() const { return 0; }
    virtual long read_samples(blip_sample_t*, long) { return 0; }
};

class Stereo_Buffer : public Multi_Buffer {
public:
    Blip_Buffer* left() { return &left_; }
    Blip_Buffer* right() { return &right_; }
    Blip_Buffer* center() { return &center_; }
    void end_frame(blip_time_t) {}
    int sample_rate() const { return sample_rate_; }
    void clear() {}
    int set_sample_rate(long rate) { sample_rate_ = (int)rate; return 0; }
    void clock_rate(long) {}

private:
    int sample_rate_ = 44100;
    Blip_Buffer left_;
    Blip_Buffer right_;
    Blip_Buffer center_;
};

#endif

#endif
