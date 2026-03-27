#include <cstdio>
#include <vector>
#include <fstream>
#include <iterator>
#include <cstdint>

int main(int argc, char** argv) {
    if (argc < 3) return 1;
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    unsigned int addr = 0;
    sscanf(argv[2], "%x", &addr);
    unsigned int offset = addr & 0x01FFFFFFu;
    for (int i = 0; i < 16; ++i) {
        if (offset + i < rom.size()) {
            printf("%02X ", rom[offset + i]);
        }
    }
    printf("\n");
    return 0;
}
