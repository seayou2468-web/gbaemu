#include "src/core/gba_core.h"
#include <cstdio>
#include <vector>

int main() {
    gba::GBACore core;
    core.Reset();

    // Test Bgr555ToRgba8888 (it was private, let's see if I can test it via palette ram)
    // Actually, I can't easily.
    // Let's check the code manually again.
    return 0;
}
