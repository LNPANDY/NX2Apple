#include "PayloadValidation.h"
#include <errno.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int nx_payload_validate(const char *path, char *error, size_t capacity) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) { snprintf(error, capacity, "open: %s", strerror(errno)); return -1; }
    struct stat st;
    struct mach_header_64 mh;
    int result = -1;
    if (fstat(fd, &st) || pread(fd, &mh, sizeof(mh), 0) != sizeof(mh) ||
        mh.magic != MH_MAGIC_64 || mh.cputype != CPU_TYPE_ARM64 ||
        (mh.filetype != MH_DYLIB && mh.filetype != MH_BUNDLE) ||
        mh.sizeofcmds > 16 * 1024 * 1024 ||
        (uint64_t)sizeof(mh) + mh.sizeofcmds > (uint64_t)st.st_size) {
        snprintf(error, capacity, "unsupported native image"); goto done;
    }
    off_t offset = sizeof(mh);
    off_t end = offset + mh.sizeofcmds;
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command lc;
        if (offset + sizeof(lc) > end || pread(fd, &lc, sizeof(lc), offset) != sizeof(lc) ||
            lc.cmdsize < sizeof(lc) || lc.cmdsize > end - offset) break;
        if (lc.cmd == LC_CODE_SIGNATURE && lc.cmdsize >= sizeof(struct linkedit_data_command)) {
            struct linkedit_data_command sig;
            if (pread(fd, &sig, sizeof(sig), offset) != sizeof(sig) || !sig.datasize ||
                (uint64_t)sig.dataoff + sig.datasize > (uint64_t)st.st_size) break;
            fsignatures_t info = {0};
            info.fs_blob_start = (void *)(uintptr_t)sig.dataoff;
            info.fs_blob_size = sig.datasize;
            if (fcntl(fd, F_ADDFILESIGS_RETURN, &info) < 0) {
                snprintf(error, capacity, "signature rejected: %s", strerror(errno)); goto done;
            }
            fchecklv_t check = {0};
            check.lv_error_message = error;
            check.lv_error_message_size = capacity;
            if (capacity) error[0] = 0;
            if (fcntl(fd, F_CHECK_LV, &check) < 0) {
                if (capacity && !error[0]) snprintf(error, capacity, "library validation: %s", strerror(errno));
                goto done;
            }
            result = 0;
            goto done;
        }
        offset += lc.cmdsize;
    }
    snprintf(error, capacity, "missing or damaged code signature");
done:
    close(fd);
    return result;
}
