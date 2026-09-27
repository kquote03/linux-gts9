// SPDX-License-Identifier: GPL-2.0-only
// Run inside a private mount namespace with a fresh binderfs mounted at argv[1].
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/android/binder.h>
#include <linux/android/binderfs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

#define CHECK(x) do { if ((x) < 0) { perror(#x); return 1; } } while (0)
static int binder_ipc(const char *path, int server)
{
    int zero = 0, status;
    CHECK(ioctl(server, BINDER_SET_CONTEXT_MGR, &zero));
    void *mapping = mmap(NULL, 1024 * 1024, PROT_READ, MAP_PRIVATE, server, 0);
    if (mapping == MAP_FAILED) return 1;
    pid_t child = fork();
    CHECK(child);
    if (!child) {
        close(server);
        int client = open(path, O_RDWR | O_CLOEXEC);
        if (client < 0) _exit(1);
        const char payload[] = "X716 Binder IPC";
        struct binder_transaction_data tx = {
            .target.handle = 0, .code = 42, .flags = TF_ONE_WAY,
            .data_size = sizeof(payload),
            .data.ptr.buffer = (uintptr_t)payload,
        };
        unsigned char command[sizeof(uint32_t) + sizeof(tx)];
        uint32_t op = BC_TRANSACTION;
        memcpy(command, &op, sizeof(op));
        memcpy(command + sizeof(op), &tx, sizeof(tx));
        struct binder_write_read wr = {
            .write_size = sizeof(command), .write_buffer = (uintptr_t)command,
        };
        _exit(ioctl(client, BINDER_WRITE_READ, &wr) < 0);
    }
    uint32_t enter = BC_ENTER_LOOPER;
    int received = 0;
    alarm(15);
    while (!received) {
        unsigned char buffer[4096];
        struct binder_write_read wr = {
            .write_size = sizeof(enter), .write_buffer = (uintptr_t)&enter,
            .read_size = sizeof(buffer), .read_buffer = (uintptr_t)buffer,
        };
        CHECK(ioctl(server, BINDER_WRITE_READ, &wr));
        for (size_t off = 0; off + sizeof(uint32_t) <= wr.read_consumed;) {
            uint32_t op;
            memcpy(&op, buffer + off, sizeof(op));
            off += sizeof(op);
            size_t size = _IOC_SIZE(op);
            if (off + size > wr.read_consumed) return 1;
            if (op == BR_TRANSACTION) {
                struct binder_transaction_data tx;
                memcpy(&tx, buffer + off, sizeof(tx));
                if (tx.code != 42 || tx.data_size != sizeof("X716 Binder IPC") ||
                    memcmp((void *)(uintptr_t)tx.data.ptr.buffer,
                           "X716 Binder IPC", sizeof("X716 Binder IPC"))) return 1;
                received = 1;
            }
            if (op == BR_FAILED_REPLY || op == BR_DEAD_REPLY || op == BR_ERROR) return 1;
            off += size;
        }
    }
    CHECK(waitpid(child, &status, 0));
    alarm(0);
    CHECK(munmap(mapping, 1024 * 1024));
    return !WIFEXITED(status) || WEXITSTATUS(status);
}

int main(int argc, char **argv)
{
    char path[4096];
    struct binderfs_device dev = { .name = "x716-smoke" };
    struct binder_version version = {0};
    if (argc != 2) return 2;
    snprintf(path, sizeof(path), "%s/binder-control", argv[1]);
    int control = open(path, O_RDWR | O_CLOEXEC);
    CHECK(control);
    CHECK(ioctl(control, BINDER_CTL_ADD, &dev));
    snprintf(path, sizeof(path), "%s/%s", argv[1], dev.name);
    int binder = open(path, O_RDWR | O_CLOEXEC);
    CHECK(binder);
    CHECK(ioctl(binder, BINDER_VERSION, &version));
    if (version.protocol_version != BINDER_CURRENT_PROTOCOL_VERSION) return 1;
    if (binder_ipc(path, binder)) return 1;
    int fd = memfd_create("waydroid-smoke", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    CHECK(fd);
    CHECK(ftruncate(fd, 4096));
    char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    memcpy(p, "memfd", 6);
    char copy[6];
    CHECK(pread(fd, copy, sizeof(copy), 0));
    if (memcmp(copy, "memfd", 6)) return 1;
    CHECK(munmap(p, 4096));
    CHECK(fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW));
    errno = 0;
    if (ftruncate(fd, 8192) != -1 || errno != EPERM) return 1;
    close(fd); close(binder); close(control);
    puts("PASS binderfs allocation, two-process Binder IPC, memfd mapping and seals");
    return 0;
}
