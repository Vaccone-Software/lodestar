#include "LodestarInflate.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

// ZIP method 8 is raw deflate: no zlib header and no adler32 trailer.
// Lengths are pointer-sized so they match Swift Int on this 64-bit target.
int lodestar_raw_inflate(const uint8_t *src, size_t srcLen,
                         uint8_t *dst, size_t dstLen) {
    if (dstLen == 0) return srcLen == 0 ? 0 : -1;
    if (src == NULL || dst == NULL) return -1;
    if (srcLen > UINT32_MAX || dstLen > UINT32_MAX) return -1;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -1;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)srcLen;
    stream.next_out = dst;
    stream.avail_out = (uInt)dstLen;
    int status = inflate(&stream, Z_FINISH);
    unsigned long produced = stream.total_out;
    inflateEnd(&stream);
    if (status != Z_STREAM_END || produced != dstLen) return -1;
    return 0;
}

int lodestar_open_dir(const char *path) {
    if (path == NULL) return -1;
    return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

// The child is a real directory, never a symlink. -1 if it is not.
int lodestar_mkdir_dir(int parent, const char *name) {
    if (name == NULL) return -1;
    if (mkdirat(parent, name, 0755) != 0 && errno != EEXIST) return -1;
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fchmod(fd, 0755) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// A new file. O_NOFOLLOW | O_EXCL: an existing link is not opened and not replaced.
int lodestar_write_new_file(int parent, const char *name, const uint8_t *bytes, size_t len, int mode) {
    if (name == NULL || (len > 0 && bytes == NULL)) return -1;
    if (len > UINT32_MAX) return -1;
    mode_t perm = (mode_t)(mode & 0777);
    int fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, perm);
    if (fd < 0) return -1;
    size_t sent = 0;
    while (sent < len) {
        ssize_t wrote = write(fd, bytes + sent, len - sent);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (wrote == 0) {
            close(fd);
            return -1;
        }
        sent += (size_t)wrote;
    }
    if (fchmod(fd, perm) != 0) {
        close(fd);
        return -1;
    }
    if (close(fd) != 0) return -1;
    return 0;
}

int lodestar_make_symlink(int parent, const char *name, const char *target) {
    if (name == NULL || target == NULL) return -1;
    return symlinkat(target, parent, name);
}
