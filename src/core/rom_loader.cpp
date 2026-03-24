#include "rom_loader.h"

#include <fstream>

namespace gba {

bool LoadFile(const std::string& path, std::vector<uint8_t>* out, std::string* error) {
  std::ifstream ifs(path, std::ios::binary);
  if (!ifs.is_open()) {
    if (error) *error = "Failed to open: " + path;
    return false;
  }

  ifs.seekg(0, std::ios::end);
  const std::streamsize size = ifs.tellg();
  if (size <= 0) {
    if (error) *error = "File is empty: " + path;
    return false;
  }

  ifs.seekg(0, std::ios::beg);
  out->resize(static_cast<size_t>(size));
  if (!ifs.read(reinterpret_cast<char*>(out->data()), size)) {
    if (error) *error = "Failed to read: " + path;
    return false;
  }

  return true;
}

}  // namespace gba
