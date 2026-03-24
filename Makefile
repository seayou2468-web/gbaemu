CXX ?= g++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -pedantic

CORE_SRCS = src/core/gba_core.cpp src/core/gba_core_cpu.cpp src/core/gba_core_memory.cpp src/core/gba_core_ppu.cpp src/core/rom_loader.cpp
LINUX_SRCS = src/platform/linux/main.cpp $(CORE_SRCS)

.PHONY: all linux_test gameplay_test backup_selftest mainline_test playthrough_test instruction_audit_test command_coverage_test run_rom_demo interactive_demo clean

all: linux_test

linux_test: build/linux_gba_test
	./build/linux_gba_test utils/testroms

gameplay_test: build/linux_gba_test
	./build/linux_gba_test --gameplay-test utils/testroms/AGB_CHECKER_TCHK30.gba

backup_selftest: build/linux_gba_test
	./build/linux_gba_test --selftest-backup

mainline_test: build/linux_gba_test
	./build/linux_gba_test --test-mainline utils/testroms

playthrough_test: build/linux_gba_test
	./build/linux_gba_test --play-mainline utils/testroms

instruction_audit_test: build/linux_gba_test
	./build/linux_gba_test --audit-instructions-mainline utils/testroms

command_coverage_test: build/linux_gba_test
	./build/linux_gba_test --command-coverage-mainline utils/testroms

run_rom_demo: build/linux_gba_test
	./build/linux_gba_test --run-rom utils/testroms/AGB_CHECKER_TCHK30.gba --frames 180 --script "60:RIGHT+A,60:DOWN+B,60:LEFT"

interactive_demo: build/linux_gba_test
	printf "d\nj\ns\nk\nu\ni\np\no\nq\n" | ./build/linux_gba_test --interactive utils/testroms/test1.gba 30

build/linux_gba_test: $(LINUX_SRCS)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ $(LINUX_SRCS)

clean:
	rm -rf build
