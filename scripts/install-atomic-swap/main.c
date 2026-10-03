#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: atomic-swap <left> <right>\n");
        return 64;
    }

    if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) != 0) {
        fprintf(stderr, "atomic swap failed: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}
