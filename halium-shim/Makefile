# halium-shim/Makefile
# ============================================================
# Builds libhom_shim.so — the LD_PRELOAD interceptor.
#
# Targets:
#   make              — build for the host architecture (debug use)
#   make android      — cross-compile for Android aarch64 (NDK)
#   make android-arm  — cross-compile for 32-bit Android ARM
#   make clean
#
# Requirements for Android build:
#   NDK_ROOT must point to an Android NDK installation, e.g.:
#     export NDK_ROOT=$HOME/android-ndk-r26c
# ============================================================

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -fPIC -shared
LDFLAGS ?= -ldl -lpthread

TARGET  = libhom_shim.so
SRC     = shim.c

# --- Host build (x86-64 Linux) --------------------------------
$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "Built $@ for host"

# --- Android aarch64 (arm64-v8a) ------------------------------
NDK_ROOT   ?= $(HOME)/android-ndk-r26c
API_LEVEL  ?= 29
TOOLCHAIN  = $(NDK_ROOT)/toolchains/llvm/prebuilt/linux-x86_64
NDK_CC_A64 = $(TOOLCHAIN)/bin/aarch64-linux-android$(API_LEVEL)-clang
NDK_FLAGS  = -O2 -Wall -fPIC -shared -fvisibility=default

android:
	@[ -x "$(NDK_CC_A64)" ] || (echo "ERROR: NDK clang not found: $(NDK_CC_A64)" && exit 1)
	$(NDK_CC_A64) $(NDK_FLAGS) -o libhom_shim.arm64.so $(SRC) -ldl -llog
	@echo "Built libhom_shim.arm64.so"

# --- Android armeabi-v7a (32-bit fallback) --------------------
NDK_CC_A32 = $(TOOLCHAIN)/bin/armv7a-linux-androideabi$(API_LEVEL)-clang

android-arm:
	@[ -x "$(NDK_CC_A32)" ] || (echo "ERROR: NDK clang not found: $(NDK_CC_A32)" && exit 1)
	$(NDK_CC_A32) $(NDK_FLAGS) -o libhom_shim.arm.so $(SRC) -ldl -llog
	@echo "Built libhom_shim.arm.so"

clean:
	rm -f $(TARGET) libhom_shim.arm64.so libhom_shim.arm.so

.PHONY: android android-arm clean
