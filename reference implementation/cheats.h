

#define CHEAT_NAME_LENGTH 17

typedef enum
{
  CHEAT_TYPE_GAMESHARK_V1,
  CHEAT_TYPE_GAMESHARK_V3,
  CHEAT_TYPE_INVALID
} cheat_variant_enum;

typedef struct
{
  char cheat_name[CHEAT_NAME_LENGTH];
  u32 cheat_active;
  u32 cheat_codes[256];
  u32 num_cheat_lines;
  cheat_variant_enum cheat_variant;
} cheat_type;

void process_cheats();
void add_cheats(char *cheats_filename);

#define MAX_CHEATS 16

extern cheat_type cheats[MAX_CHEATS];
extern u32 num_cheats;
