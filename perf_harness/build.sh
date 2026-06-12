#!/bin/bash
# Builds the offscreen harness. Third-party code (nanovg, demo.c) is compiled
# with warnings off; nanovg_mtl.m and main.m with -Wall -Wextra.
set -e
cd "$(dirname "$0")"
mkdir -p build out

if [ ! -d nanovg ]; then
  git clone --depth 1 https://github.com/memononen/nanovg
fi

CFLAGS="-O2 -g -I nanovg/src -I nanovg/example -I ../src -I shim"

clang $CFLAGS -w -c nanovg/src/nanovg.c -o build/nanovg.o
clang $CFLAGS -w -c nanovg/example/demo.c -o build/demo.o
clang $CFLAGS -Wall -Wextra -fobjc-arc -c ../src/nanovg_mtl.m -o build/nanovg_mtl.o
clang $CFLAGS -Wall -Wextra -fobjc-arc -c main.m -o build/main.o

clang build/nanovg.o build/demo.o build/nanovg_mtl.o build/main.o \
  -framework Metal -framework QuartzCore -framework Foundation \
  -framework CoreFoundation -liconv \
  -o harness

echo "built perf_harness/harness"
