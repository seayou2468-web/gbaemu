#if defined(__cplusplus)

#include <cstdint>

// Cross-module forward declarations for aggregate include order.
int CPUUpdateTicks();
void CPUUpdateWindow0();
void CPUUpdateWindow1();
bool CPUIsGBABios(const char* file);
void GBAEmulate(int ticks);

// RTC/Sound declarations used by inline helpers and bootstrap paths.
uint16_t rtcRead(uint32_t address);
bool rtcWrite(uint32_t address, uint16_t value);
void rtcReset();
bool rtcIsEnabled();
void rtcUpdateTime(int ticks);

#endif
