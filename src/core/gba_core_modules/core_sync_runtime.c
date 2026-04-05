#if defined(__cplusplus)
void CPUInterrupt()
{
    uint32_t PC = reg[15].I;
    bool savedState = armState;
    CPUSwitchMode(0x12, true, false);
    reg[14].I = PC;
    if (!savedState)
        reg[14].I += 2;
    reg[15].I = 0x18;
    armState = true;
    armIrqEnable = false;

    armNextPC = reg[15].I;
    reg[15].I += 4;
    ARM_PREFETCH;

    //  if(!holdState)
    biosProtected[0] = 0x02;
    biosProtected[1] = 0xc0;
    biosProtected[2] = 0x5e;
    biosProtected[3] = 0xe5;
}

static uint32_t joy;
static bool has_frames;

void CPULoop(int ticks)
{
    int clockTicks;
    int timerOverflow = 0;
    // variable used by the CPU core
    cpuTotalTicks = 0;

#ifndef NO_LINK
// shuffle2: what's the purpose?
//if(GetLinkMode() != LINK_DISCONNECTED)
//cpuNextEvent = 1;
#endif

    cpuBreakLoop = false;
    cpuNextEvent = CPUUpdateTicks();
    if (cpuNextEvent > ticks)
        cpuNextEvent = ticks;
    
    for (;;) {
        if (!holdState && !SWITicks) {
            if (armState) {
                armOpcodeCount++;
                if (!armExecute())
                    return;
                if (debugger)
                    return;
            } else {
                thumbOpcodeCount++;
                if (!thumbExecute())
                    return;
                if (debugger)
                    return;
            }
            clockTicks = 0;
        } else
            clockTicks = CPUUpdateTicks();

        cpuTotalTicks += clockTicks;

        if (rtcIsEnabled())
            rtcUpdateTime(cpuTotalTicks);

        if (cpuTotalTicks >= cpuNextEvent) {
            int remainingTicks = cpuTotalTicks - cpuNextEvent;

            if (SWITicks) {
                SWITicks -= clockTicks;
                if (SWITicks < 0)
                    SWITicks = 0;
            }

            clockTicks = cpuNextEvent;
            cpuTotalTicks = 0;

        updateLoop:

            if (IRQTicks) {
                IRQTicks -= clockTicks;
                if (IRQTicks < 0)
                    IRQTicks = 0;
            }

            lcdTicks -= clockTicks;

            soundTicks += clockTicks;

            if (lcdTicks <= 0) {
                if (DISPSTAT & 1) { // V-BLANK
                    // if in V-Blank mode, keep computing...
                    if (DISPSTAT & 2) {
                        lcdTicks += 1008;
                        VCOUNT++;
                        UPDATE_REG(IO_REG_VCOUNT, VCOUNT);
                        DISPSTAT &= 0xFFFD;
                        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                        CPUCompareVCOUNT();
                    } else {
                        lcdTicks += 224;
                        DISPSTAT |= 2;
                        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                        if (DISPSTAT & 16) {
                            IF |= 2;
                            UPDATE_REG(IO_REG_IF, IF);
                        }
                    }

                    if (VCOUNT > 227) { //Reaching last line
                        DISPSTAT &= 0xFFFC;
                        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                        VCOUNT = 0;
                        UPDATE_REG(IO_REG_VCOUNT, VCOUNT);
                        CPUCompareVCOUNT();
                        gfxNewFrame();
                    }
                } else {
                    int framesToSkip = systemFrameSkip;

                    static bool speedup_throttle_set = false;
                    bool turbo_button_pressed        = (joy >> 10) & 1;
#ifndef __LIBRETRO__
                    static uint32_t last_throttle;
                    static bool current_volume_saved = false;
                    static float current_volume;

                    if (turbo_button_pressed) {
                        if (coreOptions.speedup_frame_skip)
                            framesToSkip = coreOptions.speedup_frame_skip;
                        else {
                            if (!speedup_throttle_set && coreOptions.throttle != coreOptions.speedup_throttle) {
                                last_throttle = coreOptions.throttle;
                                soundSetThrottle(DowncastU16(coreOptions.speedup_throttle));
                                speedup_throttle_set = true;
                            }

                            if (coreOptions.speedup_throttle_frame_skip)
                                framesToSkip += static_cast<int>(std::ceil(double(coreOptions.speedup_throttle) / 100.0) - 1);
                        }

                        if (coreOptions.speedup_mute && !current_volume_saved) {
                            current_volume = soundGetVolume();
                            current_volume_saved = true;
                            soundSetVolume(0);
                        }
                    }
                    else {
                        if (current_volume_saved) {
                            soundSetVolume(current_volume);
                            current_volume_saved = false;
                        }

                        if (speedup_throttle_set) {
                            soundSetThrottle(DowncastU16(last_throttle));
                            speedup_throttle_set = false;
                        }
                    }
#else
                    if (turbo_button_pressed)
                        framesToSkip = 9;
#endif

                    if (DISPSTAT & 2) {
                        // if in H-Blank, leave it and move to drawing mode
                        VCOUNT++;
                        UPDATE_REG(IO_REG_VCOUNT, VCOUNT);

                        lcdTicks += 1008;
                        DISPSTAT &= 0xFFFD;
                        if (VCOUNT == 160) {
                            P1 = 0x03FF ^ (joy & 0x3FF);
                            systemUpdateMotionSensor();
                            UPDATE_REG(IO_REG_KEYINPUT, P1);
                            uint16_t P1CNT = READ16LE(((uint16_t*)&g_ioMem[0x132]));

                            // this seems wrong, but there are cases where the game
                            // can enter the stop state without requesting an IRQ from
                            // the joypad.
                            if ((P1CNT & 0x4000) || stopState) {
                                uint16_t p1 = (0x3FF ^ P1) & 0x3FF;
                                if (P1CNT & 0x8000) {
                                    if (p1 == (P1CNT & 0x3FF)) {
                                        IF |= 0x1000;
                                        UPDATE_REG(IO_REG_IF, IF);
                                    }
                                } else {
                                    if (p1 & P1CNT) {
                                        IF |= 0x1000;
                                        UPDATE_REG(IO_REG_IF, IF);
                                    }
                                }
                            }

                            DISPSTAT |= 1;
                            DISPSTAT &= 0xFFFD;
                            UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                            if (DISPSTAT & 0x0008) {
                                IF |= 1;
                                UPDATE_REG(IO_REG_IF, IF);
                            }
                            CPUCheckDMA(1, 0x0f);

                            // Let VBlank begin and its IRQ become observable before
                            // ending the frame loop.
                            if (has_frames)
                                cpuBreakLoop = true;
                        }

                        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                        CPUCompareVCOUNT();

                    } else {
                        if (frameCount >= framesToSkip) {
                            (*renderLine)();
                            switch (systemColorDepth) {
                            case 8: {
#ifdef __LIBRETRO__
                                uint8_t* dest = (uint8_t*)g_pix + 240 * VCOUNT;
#else
                                uint8_t* dest = (uint8_t*)g_pix + 244 * (VCOUNT + 1);
#endif
                                for (int x = 0; x < 240;) {
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];

                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];

                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];

                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap8[g_lineMix[x++] & 0xFFFF];
                                }
                                // for filters that read past the screen
#ifndef __LIBRETRO__
                                * dest++ = 0;
#endif
                            } break;
                            case 16: {
#ifdef __LIBRETRO__
                                uint16_t* dest = (uint16_t*)g_pix + 240 * VCOUNT;
#else
                                uint16_t* dest = (uint16_t*)g_pix + 242 * (VCOUNT + 1);
#endif
                                for (int x = 0; x < 240;) {
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];

                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];

                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];

                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = systemColorMap16[g_lineMix[x++] & 0xFFFF];
                                }
// for filters that read past the screen
#ifndef __LIBRETRO__
                                *dest++ = 0;
#endif
                            } break;
                            case 24: {
                                uint8_t* dest = (uint8_t*)g_pix + (240 * 3) * (VCOUNT + 1);
                                for (int x = 0; x < 240;) {
                                    uint32_t color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);

                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);

                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                    color = systemColorMap32[g_lineMix[x++] & 0xFFFF];
                                    *dest++ = (uint8_t)(color & 0xFF);
                                    *dest++ = (uint8_t)((color >> 8) & 0xFF);
                                    *dest++ = (uint8_t)((color >> 16) & 0xFF);
                                }
                            } break;
                            case 32: {
#ifdef __LIBRETRO__
                                uint32_t* dest = (uint32_t*)g_pix + 240 * VCOUNT;
#else
                                uint32_t* dest = (uint32_t*)g_pix + 241 * (VCOUNT + 1);
#endif
                                for (int x = 0; x < 240; x++) {
                                    *dest++ = systemColorMap32[g_lineMix[x] & 0xFFFF];
                                }
                            } break;
                            }
                        }
                        // entering H-Blank
                        DISPSTAT |= 2;
                        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                        lcdTicks += 224;
                        CPUCheckDMA(2, 0x0f);
                        if (DISPSTAT & 16) {
                            IF |= 2;
                            UPDATE_REG(IO_REG_IF, IF);
                        }
                        if (VCOUNT == 159) {
                            g_count++;
                            systemFrame();

                            if ((g_count % 10) == 0) {
                                system10Frames();
                            }
                            if (g_count == 60) {
                                uint32_t time = systemGetClock();
                                if (time != lastTime) {
                                    uint32_t t = 100000 / (time - lastTime);
                                    systemShowSpeed(t);
                                } else
                                    systemShowSpeed(0);
                                lastTime = time;
                                g_count = 0;
                            }

                            uint32_t ext = (joy >> 10);
                            // If no (m) code is enabled, apply the cheats at each LCDline
                            if ((coreOptions.cheatsEnabled) && (mastercode == 0))
                                remainingTicks += cheatsCheckKeys(P1 ^ 0x3FF, ext);

                            coreOptions.speedup = false;

                            if (ext & 1 && !speedup_throttle_set)
                                coreOptions.speedup = true;

                            capture = (ext & 2) ? true : false;

                            if (capture && !capturePrevious) {
                                captureNumber++;
                                systemScreenCapture(captureNumber);
                            }
                            capturePrevious = capture;

                            if (frameCount >= framesToSkip) {
                                systemDrawScreen();
                                frameCount = 0;
                            } else {
                                frameCount++;
                                systemSendScreen();
                            }
                            if (systemPauseOnFrame()) {
                                ticks = 0;
                            }
                            
                            has_frames = true;
                        }
                    }
                }
            }

            // we shouldn't be doing sound in stop state, but we loose synchronization
            // if sound is disabled, so in stop state, soundTick will just produce
            // mute sound

            //soundTicks -= clockTicks;
            //if (soundTicks <= 0) {
                //psoundTickfn();
                //soundTicks += SOUND_CLOCK_TICKS;
            //}

            if (!stopState) {
                if (timer0On) {
                    timer0Ticks -= clockTicks;
                    if (timer0Ticks <= 0) {
                        timer0Ticks += (0x10000 - timer0Reload) << timer0ClockReload;
                        timerOverflow |= 1;
                        soundTimerOverflow(0);
                        if (TM0CNT & 0x40) {
                            IF |= 0x08;
                            UPDATE_REG(IO_REG_IF, IF);
                        }
                    }
                    TM0D = 0xFFFF - DowncastU16(timer0Ticks >> timer0ClockReload);
                    UPDATE_REG(IO_REG_TM0CNT_L, TM0D);
                }

                if (timer1On) {
                    if (TM1CNT & 4) {
                        if (timerOverflow & 1) {
                            TM1D++;
                            if (TM1D == 0) {
                                TM1D += DowncastU16(timer1Reload);
                                timerOverflow |= 2;
                                soundTimerOverflow(1);
                                if (TM1CNT & 0x40) {
                                    IF |= 0x10;
                                    UPDATE_REG(IO_REG_IF, IF);
                                }
                            }
                            UPDATE_REG(IO_REG_TM1CNT_L, TM1D);
                        }
                    } else {
                        timer1Ticks -= clockTicks;
                        if (timer1Ticks <= 0) {
                            timer1Ticks += (0x10000 - timer1Reload) << timer1ClockReload;
                            timerOverflow |= 2;
                            soundTimerOverflow(1);
                            if (TM1CNT & 0x40) {
                                IF |= 0x10;
                                UPDATE_REG(IO_REG_IF, IF);
                            }
                        }
                        TM1D = 0xFFFF - DowncastU16(timer1Ticks >> timer1ClockReload);
                        UPDATE_REG(IO_REG_TM1CNT_L, TM1D);
                    }
                }

                if (timer2On) {
                    if (TM2CNT & 4) {
                        if (timerOverflow & 2) {
                            TM2D++;
                            if (TM2D == 0) {
                                TM2D += DowncastU16(timer2Reload);
                                timerOverflow |= 4;
                                if (TM2CNT & 0x40) {
                                    IF |= 0x20;
                                    UPDATE_REG(IO_REG_IF, IF);
                                }
                            }
                            UPDATE_REG(IO_REG_TM2CNT_L, TM2D);
                        }
                    } else {
                        timer2Ticks -= clockTicks;
                        if (timer2Ticks <= 0) {
                            timer2Ticks += (0x10000 - timer2Reload) << timer2ClockReload;
                            timerOverflow |= 4;
                            if (TM2CNT & 0x40) {
                                IF |= 0x20;
                                UPDATE_REG(IO_REG_IF, IF);
                            }
                        }
                        TM2D = 0xFFFF - DowncastU16(timer2Ticks >> timer2ClockReload);
                        UPDATE_REG(IO_REG_TM2CNT_L, TM2D);
                    }
                }

                if (timer3On) {
                    if (TM3CNT & 4) {
                        if (timerOverflow & 4) {
                            TM3D++;
                            if (TM3D == 0) {
                                TM3D += DowncastU16(timer3Reload);
                                if (TM3CNT & 0x40) {
                                    IF |= 0x40;
                                    UPDATE_REG(IO_REG_IF, IF);
                                }
                            }
                            UPDATE_REG(IO_REG_TM3CNT_L, TM3D);
                        }
                    } else {
                        timer3Ticks -= clockTicks;
                        if (timer3Ticks <= 0) {
                            timer3Ticks += (0x10000 - timer3Reload) << timer3ClockReload;
                            if (TM3CNT & 0x40) {
                                IF |= 0x40;
                                UPDATE_REG(IO_REG_IF, IF);
                            }
                        }
                        TM3D = 0xFFFF - DowncastU16(timer3Ticks >> timer3ClockReload);
                        UPDATE_REG(IO_REG_TM3CNT_L, TM3D);
                    }
                }
            }

            timerOverflow = 0;

#ifdef PROFILING
            profilingTicks -= clockTicks;
            if (profilingTicks <= 0) {
                profilingTicks += profilingTicksReload;
                if (profilSegment) {
                    profile_segment* seg = profilSegment;
                    do {
                        uint16_t* b = (uint16_t*)seg->sbuf;
                        int pc = ((reg[15].I - seg->s_lowpc) * seg->s_scale) / 0x10000;
                        if (pc >= 0 && pc < seg->ssiz) {
                            b[pc]++;
                            break;
                        }

                        seg = seg->next;
                    } while (seg);
                }
            }
#endif

            ticks -= clockTicks;

#ifndef NO_LINK
            if (GetLinkMode() != LINK_DISCONNECTED)
                LinkUpdate(clockTicks);
#endif

            cpuNextEvent = CPUUpdateTicks();

            if (cpuDmaTicksToUpdate > 0) {
                if (cpuDmaTicksToUpdate > cpuNextEvent)
                    clockTicks = cpuNextEvent;
                else
                    clockTicks = cpuDmaTicksToUpdate;
                cpuDmaTicksToUpdate -= clockTicks;
                if (cpuDmaTicksToUpdate < 0)
                    cpuDmaTicksToUpdate = 0;
                goto updateLoop;
            }

#ifndef NO_LINK
            // shuffle2: what's the purpose?
            if (GetLinkMode() != LINK_DISCONNECTED || gba_joybus_active)
                cpuNextEvent = 1;
#endif

            if (IF && (IME & 1) && armIrqEnable) {
                int res = IF & IE;
                if (stopState)
                    res &= 0x3080;
                if (res) {
                    if (intState) {
                        if (!IRQTicks) {
                            CPUInterrupt();
                            intState = false;
                            holdState = false;
                            stopState = false;
                            holdType = 0;
                        }
                    } else {
                        if (!holdState) {
                            intState = true;
                            IRQTicks = 7;
                            if (cpuNextEvent > IRQTicks)
                                cpuNextEvent = IRQTicks;
                        } else {
                            CPUInterrupt();
                            holdState = false;
                            stopState = false;
                            holdType = 0;
                        }
                    }

                    // Stops the SWI Ticks emulation if an IRQ is executed
                    //(to avoid problems with nested IRQ/SWI)
                    if (SWITicks)
                        SWITicks = 0;
                }
            }

            if (remainingTicks > 0) {
                if (remainingTicks > cpuNextEvent)
                    clockTicks = cpuNextEvent;
                else
                    clockTicks = remainingTicks;
                remainingTicks -= clockTicks;
                if (remainingTicks < 0)
                    remainingTicks = 0;
                goto updateLoop;
            }

            if (timerOnOffDelay)
                applyTimer();

            if (cpuNextEvent > ticks)
                cpuNextEvent = ticks;

            // end loop when a frame is done
            if (ticks <= 0 || cpuBreakLoop)
                break;
        }
    }
#ifndef NO_LINK
    if (GetLinkMode() != LINK_DISCONNECTED)
        CheckLinkConnection();
#endif
}

void GBAEmulate(int ticks)
{
    has_frames = false;

    // update joystick information
    if (systemReadJoypads())
        // read default joystick
        joy = systemReadJoypad(-1);

    // Runs nth number of ticks till vblank, outputs audio
    // then the video frames.
    // sanity check:
    // wrapped in loop in case frames has not been written yet
    while (!has_frames && (soundTicks < SOUND_CLOCK_TICKS))
        CPULoop(ticks);

    // Flush sound using accumulated soundTick
    psoundTickfn();

}

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
