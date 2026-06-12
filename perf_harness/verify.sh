#!/bin/bash
# Rebuilds, renders all scenes, and compares PNGs byte-for-byte against the
# baseline in out/baseline.
set -e
cd "$(dirname "$0")"
./build.sh > /dev/null
rm -rf out/current && mkdir -p out/current
(cd nanovg/src && ../../harness render ../../out/current > /dev/null)
fail=0
for f in out/baseline/*.png; do
  n=$(basename "$f")
  if cmp -s "out/baseline/$n" "out/current/$n"; then
    echo "IDENTICAL $n"
  else
    echo "DIFFERS   $n"
    fail=1
  fi
done
exit $fail
