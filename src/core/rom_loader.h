#ifndef ROM_LOADER_H
#define ROM_LOADER_H

#include <cstdint>
#include <string>
#include <vector>

namespace gba {

bool LoadFile(const std::string& path, std::vector<uint8_t>* out, std::string* error);

}

#endif
