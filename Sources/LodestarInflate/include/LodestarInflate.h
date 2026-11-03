#ifndef LODESTAR_INFLATE_H
#define LODESTAR_INFLATE_H

#include <stddef.h>
#include <stdint.h>

// ZIP method 8 is raw deflate. The directory writes live here too: openat
// takes a mode, and a Swift target cannot hold the C that calls it.
int lodestar_raw_inflate(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen);
int lodestar_open_dir(const char *path);
int lodestar_mkdir_dir(int parent, const char *name);
int lodestar_write_new_file(int parent, const char *name, const uint8_t *bytes, size_t len, int mode);
int lodestar_make_symlink(int parent, const char *name, const char *target);

#endif
