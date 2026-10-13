#!/bin/bash
# Builds mosalua.hdll for Linux (used by the test suite) and for Windows x64 (what ships).
#   LUA_SRC  Lua 5.4 source directory        HL_SRC  HashLink source directory (headers + libhl.so)
#   HL_WIN   directory holding a Windows libhl.dll to link against
set -e
cd "$(dirname "$0")"
LUA_SRC=${LUA_SRC:-$HOME/lua}
HL_SRC=${HL_SRC:-$HOME/hashlink}
HL_WIN=${HL_WIN:?set HL_WIN to a folder containing libhl.dll}
mkdir -p build/linux build/win build/gen

python3 - <<'PY'
src = open("lua/mosa.lua", "rb").read()
with open("build/gen/mosa_lua.h", "w") as f:
    f.write("/* generated from lua/mosa.lua */\nstatic const unsigned char mosa_lua_src[] = {\n")
    for i in range(0, len(src), 20):
        f.write(",".join(str(b) for b in src[i:i + 20]) + ",\n")
    f.write("0};\nstatic const unsigned int mosa_lua_len = %d;\n" % len(src))
PY

LUA_FILES=$(ls $LUA_SRC/*.c | grep -v -E '/(lua|luac|onelua|ltests)\.c$')
CFLAGS="-O2 -Wall -Wno-unused-function -I$HL_SRC/src -I$LUA_SRC -Ibuild/gen"

if [ "$1" != "win" ]; then
  gcc -shared -fPIC $CFLAGS -DLUA_USE_POSIX -include src/lua_jmp.h $LUA_FILES src/mosalua.c \
      -o build/linux/mosalua.hdll -L$HL_SRC -lhl -lm
  echo "built build/linux/mosalua.hdll"
fi

if [ "$1" != "linux" ]; then
  MG=x86_64-w64-mingw32
  rm -rf build/win/obj && mkdir -p build/win/obj
  for f in $LUA_FILES src/mosalua.c; do
    $MG-gcc -c $CFLAGS -include src/lua_jmp.h "$f" -o build/win/obj/$(basename "$f" .c).o
  done
  # import library for libhl.dll, generated from exactly the symbols we use
  { echo "LIBRARY libhl.dll"; echo "EXPORTS";
    $MG-nm build/win/obj/mosalua.o | awk '$1=="U" && $2 ~ /^__imp_hl/ {s=substr($2,7); if (s ~ /^hlt_/) print s " DATA"; else print s}' | sort -u; } > build/win/libhl.def
  $MG-dlltool -d build/win/libhl.def -l build/win/libhl.a
  $MG-gcc -shared -static-libgcc -o build/win/mosalua.hdll build/win/obj/*.o build/win/libhl.a -Wl,--exclude-all-symbols -s
  echo "built build/win/mosalua.hdll"
fi
