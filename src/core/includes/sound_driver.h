#ifndef VBAM_CORE_BASE_SOUND_DRIVER_H_
#define VBAM_CORE_BASE_SOUND_DRIVER_H_

#include <cstdint>

// Sound driver abstract interface for the core to use to output sound.
// Subclass this to implement a new sound driver.
class SoundDriver {
public:
    virtual ~SoundDriver() = default;

    // Initialize the sound driver. `sampleRate` in Hertz.
    // Returns true if the driver was successfully initialized.
    virtual bool init(long sampleRate) = 0;

    // Pause the sound driver.
    virtual void pause() = 0;

    // Reset the sound driver.
    virtual void reset() = 0;

    // Resume the sound driver, following a pause.
    virtual void resume() = 0;

    // Write length bytes of data from the finalWave buffer to the driver output buffer.
    virtual void write(uint16_t* finalWave, int length) = 0;

    virtual void setThrottle(unsigned short throttle) = 0;
};

#endif  // VBAM_CORE_BASE_SOUND_DRIVER_H_
