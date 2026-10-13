/* Force-included into every Lua source file.
 * Lua errors use the compiler's builtin setjmp/longjmp: a plain register
 * restore that never asks the OS to unwind (the CRT longjmp on Win64 does,
 * and JIT-compiled game code has no unwind tables). */
#ifndef MOSALUA_LUA_JMP_H
#define MOSALUA_LUA_JMP_H
typedef void *mosalua_jmpbuf[5];
#define luai_jmpbuf		mosalua_jmpbuf
#define LUAI_THROW(L,c)		__builtin_longjmp((c)->b, 1)
#define LUAI_TRY(L,c,a)		if (__builtin_setjmp((c)->b) == 0) { a }
#endif
