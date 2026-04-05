#ifndef CPU_H
#define CPU_H

#include <stdint.h>

typedef enum {
  CPU_ALERT_NONE = 0,
  CPU_ALERT_HALT,
  CPU_ALERT_STOP,
  CPU_ALERT_IRQ,
} cpu_alert_type;

typedef enum {
  RUN = 0,
  STEP_RUN,
  COUNTDOWN_BREAKPOINT,
  PC_BREAKPOINT,
} debug_state;

extern uint32_t* reg;
extern uint32_t irq_raised;

void flush_translation_cache_rom(void);
void flush_translation_cache_ram(void);
void flush_translation_cache_bios(void);
void execute_arm_translate(uint32_t cycles);
void execute_thumb_translate(uint32_t cycles);

#endif
