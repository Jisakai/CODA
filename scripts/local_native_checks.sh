#!/usr/bin/env bash
# Run the real portable production suites; never create outputs in the checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
out="${1:?Pass an absolute Linux scratch output directory}"
case "$out" in /*) ;; *) echo 'Output must be absolute' >&2; exit 2;; esac
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
case "$out/" in "$root/"*) echo 'Output must be outside the checkout' >&2; exit 2;; esac
cd "$root"
clang++ --version
for mode in optimized sanitized; do
  set -- -std=c++20 -Wall -Wextra -pthread -I CodaDSP/include
  if [[ "$mode" == optimized ]]; then
    set -- "$@" -O2
  else
    set -- "$@" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
  fi
  clang++ "$@" CodaDSP/src/coda_dsp.cpp CodaDSP/tests/dsp_tests.cpp -o "$out/dsp-$mode"
  ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
    python3 scripts/run_native_test.py "$out/dsp-$mode" | tee "$out/dsp-$mode.txt"
  clang++ "$@" -I Sources/CodaTransport/include -I Sources/CodaTransport \
    CodaDSP/src/coda_dsp.cpp Sources/CodaTransport/coda_transport.cpp \
    Tests/CodaTransportTests/transport_tests.cpp -o "$out/transport-$mode"
  ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
    python3 scripts/run_native_test.py "$out/transport-$mode" | tee "$out/transport-$mode.txt"
done
echo 'Linux portable suites passed; Apple dyld/unfair-lock and AVFoundation gates require macOS.'
