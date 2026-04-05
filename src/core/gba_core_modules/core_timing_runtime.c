#if defined(__cplusplus)
inline int CPUUpdateTicks()
{
    int cpuLoopTicks = lcdTicks;

    //if (soundTicks < cpuLoopTicks)
        //cpuLoopTicks = soundTicks;

    if (timer0On && (timer0Ticks < cpuLoopTicks)) {
        cpuLoopTicks = timer0Ticks;
    }
    if (timer1On && !(TM1CNT & 4) && (timer1Ticks < cpuLoopTicks)) {
        cpuLoopTicks = timer1Ticks;
    }
    if (timer2On && !(TM2CNT & 4) && (timer2Ticks < cpuLoopTicks)) {
        cpuLoopTicks = timer2Ticks;
    }
    if (timer3On && !(TM3CNT & 4) && (timer3Ticks < cpuLoopTicks)) {
        cpuLoopTicks = timer3Ticks;
    }
#ifdef PROFILING
    if (profilingTicksReload != 0) {
        if (profilingTicks < cpuLoopTicks) {
            cpuLoopTicks = profilingTicks;
        }
    }
#endif

    if (SWITicks) {
        if (SWITicks < cpuLoopTicks)
            cpuLoopTicks = SWITicks;
    }

    if (IRQTicks) {
        if (IRQTicks < cpuLoopTicks)
            cpuLoopTicks = IRQTicks;
    }

    // CPU event scheduling must never return 0 or a negative value.
    // If it does (e.g. while halted and a timer has underflowed), the core
    // can stop advancing LCD/interrupt timing and BIOS boot can deadlock.
    if (cpuLoopTicks <= 0)
        cpuLoopTicks = 1;

    return cpuLoopTicks;
}

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
