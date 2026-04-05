

#ifndef GUI_H
#define GUI_H

#define GPSP_CONFIG_FILENAME "gpsp.cfg"

s32 load_file(const char **wildcards, char *result);
u32 adjust_frameskip(u32 button_id);
s32 load_game_config_file();
s32 load_config_file();
s32 save_game_config_file();
s32 save_config_file();
u32 menu(u16 *original_screen);

extern u32 savestate_slot;

void get_savestate_filename_noshot(u32 slot, char *name_buffer);
void get_savestate_filename(u32 slot, char *name_buffer);
void get_savestate_snapshot(char *savestate_filename);

#ifdef POLLUX_BUILD
  #define default_clock_speed 533
#elif defined(GP2X_BUILD)
  #define default_clock_speed 200
#else
  #define default_clock_speed 333
#endif

#endif

