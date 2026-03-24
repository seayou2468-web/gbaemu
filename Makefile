CXX ?= g++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -pedantic

CORE_SRCS = src/core/gba_core.cpp src/core/rom_loader.cpp
LINUX_SRCS = src/platform/linux/main.cpp $(CORE_SRCS)

.PHONY: all linux_test gameplay_test run_rom_demo clean

all: linux_test

linux_test: build/linux_gba_test
	./build/linux_gba_test utils/testroms

gameplay_test: build/linux_gba_test
	./build/linux_gba_test --gameplay-test utils/testroms/AGB_CHECKER_TCHK30.gba

run_rom_demo: build/linux_gba_test
	./build/linux_gba_test --run-rom utils/testroms/AGB_CHECKER_TCHK30.gba --frames 180 --script "60:RIGHT+A,60:DOWN+B,60:LEFT"

build/linux_gba_test: $(LINUX_SRCS)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ $(LINUX_SRCS)

clean:
	rm -rf build
