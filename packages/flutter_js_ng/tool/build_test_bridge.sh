#!/usr/bin/env bash
# Builds the Windows QuickJS bridge the Dart tests load.
#
# `flutter test` cannot load a Flutter plugin's Windows DLL: the plugin needs
# the engine's symbol table, which a plain VM test has no equivalent of. The
# suite therefore loads a standalone DLL exporting the same C functions, which
# `lib/quickjs/ffi.dart` looks for at `build/quickjs/quickjs_c_bridge.dll`
# (or `$QUICKJS_C_BRIDGE_TEST_PATH`, or on PATH).
#
# The sources are this package's own: four files from quickjs-ng plus the
# runtime C++ shim. `windows/flutter_js_plugin.cpp` is deliberately excluded -
# it is the Flutter binding and needs engine headers; the bridge does not.
#
# Nothing in a normal test run rebuilds this. Run it after changing anything
# under cxx/, or on a fresh checkout that has a test/cache but no build/.
#
# Requirements: a MinGW-w64 gcc/g++ on PATH, or an install in one of the usual
# places (the script adds it). MSVC is not supported: this script is bash.
#
# Usage:
#   packages/flutter_js_ng/tool/build_test_bridge.sh [--out DIR]
#   OUT_DIR=... packages/flutter_js_ng/tool/build_test_bridge.sh
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PKG_DIR/cxx"

# The tests that load this DLL run from the Flutter project root, so that is
# where build/quickjs lives: the repo root when this package is vendored in
# one, the package itself when it is checked out alone.
ROOT="$PKG_DIR"
probe="$PKG_DIR"
while [ "$probe" != "/" ] && [ "$probe" != "." ]; do
  if [ -e "$probe/.git" ]; then
    ROOT="$probe"
    break
  fi
  probe="$(dirname "$probe")"
done

OUT="${OUT_DIR:-$ROOT/build/quickjs}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
  for dir in /c/msys64/mingw64/bin /mingw64/bin /c/mingw64/bin /c/ProgramData/mingw64/mingw64/bin; do
    if [ -x "$dir/gcc.exe" ] && [ -x "$dir/g++.exe" ]; then
      export PATH="$dir:$PATH"
      break
    fi
  done
fi
if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
  echo "error: no MinGW-w64 gcc/g++ found on PATH (tried the usual install locations)." >&2
  echo "       Install MSYS2's mingw-w64-gcc, or set PATH to its bin directory." >&2
  exit 1
fi

for f in quickjs/quickjs.c quickjs/libregexp.c quickjs/libunicode.c quickjs/dtoa.c \
         libfastdev_quickjs_runtime.cpp; do
  if [ ! -f "$SRC/$f" ]; then
    echo "error: missing $SRC/$f" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Same defines as windows/CMakeLists.txt. The C files are C11 (quickjs-ng uses
# _Atomic); the runtime shim is C++17. Both are compiled separately so the
# driver never mistakes one for the other. NOCRYPT skips <wincrypt.h>, which
# quickjs does not use and a headers-only MinGW install may not ship.
# -fno-use-linker-plugin because a partial MinGW install can carry the LTO
# import library without the plugin DLL, which otherwise fails every link.
DEFS=(-O2 -DCONFIG_VERSION=\"2024-01-01\" -DQUICKJS -D_GNU_SOURCE -DNOCRYPT
      -D_WIN32_WINNT=0x0600 -fno-use-linker-plugin)
INC=(-I"$SRC/quickjs")

echo "compiling quickjs-ng + runtime shim (this takes a minute)"
for f in quickjs/quickjs quickjs/libregexp quickjs/libunicode quickjs/dtoa; do
  name="$(basename "$f")"
  gcc "${DEFS[@]}" "${INC[@]}" -std=gnu11 -c "$SRC/$f.c" -o "$TMP/$name.o"
done
g++ "${DEFS[@]}" "${INC[@]}" -std=gnu++17 -c \
  "$SRC/libfastdev_quickjs_runtime.cpp" -o "$TMP/libfastdev_quickjs_runtime.o"

# Static libgcc/libstdc++ so the DLL needs no second compiler runtime. pthread
# still ships as libwinpthread-1.dll next to it; see below.
g++ -shared -fno-use-linker-plugin -o "$TMP/quickjs_c_bridge.dll" "$TMP"/*.o \
  -static-libgcc -static-libstdc++ -Wl,--no-undefined -lm

# The bridge exports jsThrow, JS_NewRuntimeDartBridge, doReturnOne and the rest
# of the shim. A missing export is the failure mode a stale DLL produces at
# runtime as "Failed to lookup symbol", so it is cheap to catch here.
if command -v objdump >/dev/null 2>&1; then
  for sym in jsThrow JS_NewRuntimeDartBridge doReturnOne; do
    if ! objdump -p "$TMP/quickjs_c_bridge.dll" | grep -q " $sym\$"; then
      echo "error: built DLL does not export $sym" >&2
      exit 1
    fi
  done
fi

mkdir -p "$OUT"
cp -f "$TMP/quickjs_c_bridge.dll" "$OUT/quickjs_c_bridge.dll"

PTHREAD="$(gcc -print-file-name=libwinpthread-1.dll)"
if [ -f "$PTHREAD" ]; then
  cp -f "$PTHREAD" "$OUT/libwinpthread-1.dll"
elif [ ! -f "$OUT/libwinpthread-1.dll" ]; then
  echo "warning: libwinpthread-1.dll not found beside gcc; the DLL may fail to load." >&2
fi

rm -rf "$TMP"
trap - EXIT
echo "wrote $OUT/quickjs_c_bridge.dll"
echo "run tests from $ROOT so build/quickjs resolves"
