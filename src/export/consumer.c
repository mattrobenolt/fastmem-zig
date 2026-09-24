// Keep real external calls even when the C frontend recognizes memory builtins.
#include <stddef.h>
extern void *memcpy(void *, const void *, size_t);
extern void *memmove(void *, const void *, size_t);
extern void *memset(void *, int, size_t);
void p6_c_copy(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void p6_c_move(void *d, const void *s, size_t n) { memmove(d, s, n); }
void p6_c_set(void *d, int v, size_t n) { memset(d, v, n); }
