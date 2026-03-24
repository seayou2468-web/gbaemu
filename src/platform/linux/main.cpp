#include <filesystem>
#include <cctype>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "../../core/gba_core.h"
#include "../../core/rom_loader.h"

namespace fs = std::filesystem;

int RunBatchTest(const std::string& rom_dir) {
  if (!fs::exists(rom_dir)) {
    std::cerr << "ROM directory not found: " << rom_dir << "\n";
    return 1;
  }

  int ok = 0;
  int fail = 0;

  for (const auto& entry : fs::directory_iterator(rom_dir)) {
    if (!entry.is_regular_file() || entry.path().extension() != ".gba") continue;

    std::vector<uint8_t> rom;
    std::string error;
    if (!gba::LoadFile(entry.path().string(), &rom, &error)) {
      std::cerr << "[FAIL] " << entry.path().filename().string() << " : " << error << "\n";
      ++fail;
      continue;
    }

    gba::GBACore core;
    if (!core.LoadROM(rom, &error)) {
      std::cerr << "[FAIL] " << entry.path().filename().string() << " : " << error << "\n";
      ++fail;
      continue;
    }

    for (int i = 0; i < 5; ++i) {
      core.StepFrame();
    }

    const auto& info = core.GetRomInfo();
    std::cout << "[OK] " << entry.path().filename().string() << " title='" << info.title
              << "' code='" << info.game_code << "' frames=" << core.frame_count()
              << " cycles=" << core.executed_cycles() << " hash=" << core.ComputeFrameHash()
              << " logo=" << info.logo_valid << " hdrchk=" << info.complement_check_valid
              << "\n";
    ++ok;
  }

  std::cout << "Summary: ok=" << ok << " fail=" << fail << "\n";
  return fail == 0 ? 0 : 2;
}

int RunGameplayTest(const std::string& rom_path) {
  std::vector<uint8_t> rom;
  std::string error;

  if (!gba::LoadFile(rom_path, &rom, &error)) {
    std::cerr << "Gameplay test ROM load failed: " << error << "\n";
    return 1;
  }

  gba::GBACore core;
  if (!core.LoadROM(rom, &error)) {
    std::cerr << "Gameplay test core load failed: " << error << "\n";
    return 2;
  }

  const auto before = core.gameplay_state();
  const auto hash_before = core.ComputeFrameHash();

  for (int i = 0; i < 30; ++i) {
    core.SetKeys(gba::kKeyRight | gba::kKeyA);
    core.StepFrame();
  }
  for (int i = 0; i < 15; ++i) {
    core.SetKeys(gba::kKeyDown | gba::kKeyB);
    core.StepFrame();
  }
  for (int i = 0; i < 10; ++i) {
    core.SetKeys(gba::kKeyLeft);
    core.StepFrame();
  }
  core.SetKeys(0);
  core.StepFrame();

  const auto after = core.gameplay_state();
  const auto hash_after = core.ComputeFrameHash();

  const bool moved = (after.player_x != before.player_x) || (after.player_y != before.player_y);
  const bool scored = after.score > before.score;
  const bool frame_changed = hash_before != hash_after;

  std::cout << "GameplayTest ROM='" << rom_path << "'\n"
            << "  before: x=" << before.player_x << " y=" << before.player_y
            << " score=" << before.score << " hash=" << hash_before << "\n"
            << "  after : x=" << after.player_x << " y=" << after.player_y
            << " score=" << after.score << " hash=" << hash_after << "\n"
            << "  checks: moved=" << moved << " scored=" << scored
            << " frame_changed=" << frame_changed << "\n";

  if (moved && scored && frame_changed) {
    std::cout << "GameplayTest: PASS\n";
    return 0;
  }

  std::cout << "GameplayTest: FAIL\n";
  return 3;
}

uint16_t ParseKeyToken(const std::string& token) {
  if (token == "A") return gba::kKeyA;
  if (token == "B") return gba::kKeyB;
  if (token == "SELECT") return gba::kKeySelect;
  if (token == "START") return gba::kKeyStart;
  if (token == "RIGHT") return gba::kKeyRight;
  if (token == "LEFT") return gba::kKeyLeft;
  if (token == "UP") return gba::kKeyUp;
  if (token == "DOWN") return gba::kKeyDown;
  if (token == "R") return gba::kKeyR;
  if (token == "L") return gba::kKeyL;
  return 0;
}

struct InputSegment {
  int frames = 0;
  uint16_t mask = 0;
};

std::vector<InputSegment> ParseInputScript(const std::string& script, std::string* error) {
  // Format example:
  //   "60:RIGHT+A,30:DOWN+B,10:NONE"
  std::vector<InputSegment> result;
  std::stringstream ss(script);
  std::string segment;

  while (std::getline(ss, segment, ',')) {
    if (segment.empty()) continue;
    const auto colon = segment.find(':');
    if (colon == std::string::npos) {
      if (error) *error = "Invalid segment (missing ':'): " + segment;
      return {};
    }

    const std::string frame_str = segment.substr(0, colon);
    const std::string keys_str = segment.substr(colon + 1);

    int frames = 0;
    try {
      frames = std::stoi(frame_str);
    } catch (...) {
      if (error) *error = "Invalid frame count: " + frame_str;
      return {};
    }
    if (frames <= 0) {
      if (error) *error = "Frame count must be > 0: " + frame_str;
      return {};
    }

    uint16_t mask = 0;
    std::stringstream key_ss(keys_str);
    std::string key_token;
    while (std::getline(key_ss, key_token, '+')) {
      for (char& c : key_token) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
      if (key_token == "NONE" || key_token.empty()) continue;
      const uint16_t key_mask = ParseKeyToken(key_token);
      if (key_mask == 0) {
        if (error) *error = "Unknown key token: " + key_token;
        return {};
      }
      mask |= key_mask;
    }

    result.push_back(InputSegment{frames, mask});
  }

  if (result.empty() && error) {
    *error = "Input script produced no usable segments.";
  }
  return result;
}

int RunPlayableSession(const std::string& rom_path, int total_frames, const std::string& script) {
  std::vector<uint8_t> rom;
  std::string error;

  if (!gba::LoadFile(rom_path, &rom, &error)) {
    std::cerr << "Run ROM load failed: " << error << "\n";
    return 1;
  }

  gba::GBACore core;
  if (!core.LoadROM(rom, &error)) {
    std::cerr << "Run core load failed: " << error << "\n";
    return 2;
  }

  std::vector<InputSegment> segments;
  if (!script.empty()) {
    segments = ParseInputScript(script, &error);
    if (segments.empty()) {
      std::cerr << "Input script parse failed: " << error << "\n";
      return 3;
    }
  }

  const auto& info = core.GetRomInfo();
  std::cout << "RunROM title='" << info.title << "' code='" << info.game_code
            << "' total_frames=" << total_frames << "\n";

  int frame_index = 0;
  size_t segment_index = 0;
  int segment_left = segments.empty() ? total_frames : segments[0].frames;
  uint16_t active_keys = segments.empty() ? 0 : segments[0].mask;

  while (frame_index < total_frames) {
    if (!segments.empty() && segment_left <= 0) {
      ++segment_index;
      if (segment_index < segments.size()) {
        segment_left = segments[segment_index].frames;
        active_keys = segments[segment_index].mask;
      } else {
        active_keys = 0;
        segment_left = total_frames - frame_index;
      }
    }

    core.SetKeys(active_keys);
    core.StepFrame();
    --segment_left;
    ++frame_index;
  }

  const auto& state = core.gameplay_state();
  std::cout << "RunROM finished frames=" << core.frame_count()
            << " cycles=" << core.executed_cycles()
            << " hash=" << core.ComputeFrameHash()
            << " state=(x=" << state.player_x
            << ",y=" << state.player_y
            << ",score=" << state.score << ")\n";
  return 0;
}

int main(int argc, char** argv) {
  if (argc >= 3 && std::string(argv[1]) == "--run-rom") {
    const std::string rom_path = argv[2];
    int frames = 300;
    std::string script;

    for (int i = 3; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--frames" && i + 1 < argc) {
        frames = std::stoi(argv[++i]);
      } else if (arg == "--script" && i + 1 < argc) {
        script = argv[++i];
      } else {
        std::cerr << "Unknown argument: " << arg << "\n";
        return 4;
      }
    }

    return RunPlayableSession(rom_path, frames, script);
  }

  if (argc >= 3 && std::string(argv[1]) == "--gameplay-test") {
    return RunGameplayTest(argv[2]);
  }

  std::string rom_dir = "utils/testroms";
  if (argc >= 2) {
    rom_dir = argv[1];
  }
  return RunBatchTest(rom_dir);
}
