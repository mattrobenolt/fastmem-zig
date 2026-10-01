// The C surface of the libc probe: dlopen/dlsym/dladdr resolution of the libc
// memory functions. build.zig translates this header into the "c" module of
// the libc-probe root module.
#define _GNU_SOURCE 1
#include <dlfcn.h>
