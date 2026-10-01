// The C surface of the measurement binary: dlopen/dlsym resolution of the
// libc kernels and their link map. build.zig translates this header into the
// "c" module of the bench-fastmem root module.
#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <link.h>
