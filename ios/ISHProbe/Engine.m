#import "Engine.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/fs/fake.h"
#include "ish/fs/tty.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/fs/path.h"
#include "ish/fs/fd.h"
#include "ish/fs/real.h"
#include "ish/emu/cpu.h"

int jit_control(const char *cmd, size_t len);

static BOOL gBooted = NO;
static int gGuestPid = -1;
static int gGuestExitCode = INT_MIN;
static dispatch_semaphore_t gExitSemaphore;

static int probe_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    if (len > 0) {
        fwrite(buf, 1, len, stdout);
        fflush(stdout);
    }
    return (int)len;
}

static int probe_tty_init(struct tty *tty) {
    return 0;
}

static void probe_tty_cleanup(struct tty *tty) {
}

static struct tty_driver_ops probe_console_ops = {
    .init = probe_tty_init,
    .write = probe_tty_write,
    .cleanup = probe_tty_cleanup,
};

DEFINE_TTY_DRIVER(probe_console_driver, &probe_console_ops, TTY_CONSOLE_MAJOR, 8);

static void probe_exit_hook(struct task *task, int code) {
    if (task->pid != gGuestPid || gExitSemaphore == NULL) {
        return;
    }
    gGuestExitCode = code;
    dispatch_semaphore_signal(gExitSemaphore);
}

static void create_device_nodes(void) {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
}

static NSData *read_to_eof(int fd, dispatch_group_t readers) {
    NSMutableData *data = [NSMutableData data];
    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[4096];
        while (true) {
            ssize_t count = read(fd, buffer, sizeof(buffer));
            if (count > 0) {
                [data appendBytes:buffer length:(NSUInteger)count];
            } else if (count == 0) {
                break;
            } else if (errno != EINTR) {
                NSLog(@"ISH_PROBE pipe read failed: errno=%d", errno);
                break;
            }
        }
        close(fd);
    });
    return data;
}

@implementation ISHEngine

+ (int)bootWithRootPath:(NSString *)rootPath {
    if (gBooted) {
        return 0;
    }

    NSString *dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    int err = mount_root(&fakefs, dataPath.fileSystemRepresentation);
    NSLog(@"ISH_PROBE mount_root(%@) = %d", dataPath, err);
    if (err < 0) {
        return err;
    }

    // The AOT runtime starts enabled. This probe deliberately exercises the
    // interpreter/gadget engine only, with no JIT or executable-memory entitlement.
    err = jit_control("off", 3);
    NSLog(@"ISH_PROBE jit_control(off) = %d", err);

    err = become_first_process();
    NSLog(@"ISH_PROBE become_first_process = %d", err);
    if (err < 0) {
        return err;
    }
    current->thread = pthread_self();

    // The rootfs script writes resolv.conf after fakefsify, so the host file
    // exists without a corresponding meta.db path. Create it through the VFS.
    const char dnsConfig[] = "nameserver 8.8.8.8\nnameserver 8.8.4.4\n";
    struct fd *dnsFD = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(dnsFD)) {
        err = PTR_ERR(dnsFD);
        NSLog(@"ISH_PROBE open /etc/resolv.conf = %d", err);
        return err;
    }
    ssize_t dnsWritten = dnsFD->ops->write(dnsFD, dnsConfig, sizeof(dnsConfig) - 1);
    fd_close(dnsFD);
    if (dnsWritten != sizeof(dnsConfig) - 1) {
        NSLog(@"ISH_PROBE write /etc/resolv.conf = %zd", dnsWritten);
        return -EIO;
    }

    create_device_nodes();
    err = do_mount(&procfs, "proc", "/proc", "", 0);
    NSLog(@"ISH_PROBE mount /proc = %d", err);
    if (err < 0) {
        return err;
    }
    err = do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    NSLog(@"ISH_PROBE mount /dev/pts = %d", err);
    if (err < 0) {
        return err;
    }

    tty_drivers[TTY_CONSOLE_MAJOR] = &probe_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    NSLog(@"ISH_PROBE create_stdio = %d", err);
    if (err < 0) {
        return err;
    }

    exit_hook = probe_exit_hook;
    gBooted = YES;
    NSLog(@"ISH_PROBE kernel booted");
    return 0;
}

+ (NSDictionary *)execute:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    if (!gBooted) {
        return @{@"launchError": @(-1), @"error": @"kernel is not booted"};
    }

    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdoutPipe) != 0 || pipe(stderrPipe) != 0) {
        return @{@"launchError": @(-errno), @"error": @"pipe failed"};
    }

    struct task *savedCurrent = current;
    int err = become_new_init_child();
    NSLog(@"ISH_PROBE become_new_init_child = %d", err);
    if (err < 0) {
        current = savedCurrent;
        close(stdoutPipe[0]); close(stdoutPipe[1]);
        close(stderrPipe[0]); close(stderrPipe[1]);
        return @{@"launchError": @(err), @"error": @"become_new_init_child failed"};
    }
    struct task *task = current;

    struct fd *stdinFD = adhoc_fd_create(&realfs_fdops);
    struct fd *stdoutFD = adhoc_fd_create(&realfs_fdops);
    struct fd *stderrFD = adhoc_fd_create(&realfs_fdops);
    if (stdinFD == NULL || stdoutFD == NULL || stderrFD == NULL) {
        current = savedCurrent;
        return @{@"launchError": @(-1), @"error": @"adhoc_fd_create failed"};
    }
    stdinFD->real_fd = open("/dev/null", O_RDONLY);
    stdoutFD->real_fd = dup(stdoutPipe[1]);
    stderrFD->real_fd = dup(stderrPipe[1]);
    task->files->files[0] = stdinFD;
    task->files->files[1] = stdoutFD;
    task->files->files[2] = stderrFD;

    close(stdoutPipe[1]); stdoutPipe[1] = -1;
    close(stderrPipe[1]); stderrPipe[1] = -1;

    char argvBuffer[4096];
    size_t argvPosition = 0;
    size_t argc = 0;
    NSArray<NSString *> *allArguments = [@[executable] arrayByAddingObjectsFromArray:arguments];
    for (NSString *argument in allArguments) {
        const char *value = argument.UTF8String;
        size_t length = strlen(value) + 1;
        if (argvPosition + length >= sizeof(argvBuffer)) {
            current = savedCurrent;
            return @{@"launchError": @(-1), @"error": @"argv buffer overflow"};
        }
        memcpy(argvBuffer + argvPosition, value, length);
        argvPosition += length;
        argc++;
    }
    argvBuffer[argvPosition] = '\0';

    const char environment[] =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "LANG=C.UTF-8\0"
        "GODEBUG=asyncpreemptoff=1\0"
        "GOMAXPROCS=2\0"
        "NO_COLOR=1\0"
        "PYTHONMALLOC=malloc\0"
        "PYTHONDONTWRITEBYTECODE=1\0"
        "UV_THREADPOOL_SIZE=1\0";

    err = do_execve(executable.UTF8String, argc, argvBuffer, environment);
    NSLog(@"ISH_PROBE do_execve(%@) = %d", executable, err);
    if (err < 0) {
        current = savedCurrent;
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        return @{@"launchError": @(err), @"error": @"do_execve failed"};
    }

    gGuestExitCode = INT_MIN;
    gExitSemaphore = dispatch_semaphore_create(0);
    gGuestPid = task->pid;
    err = task_start(task);
    current = savedCurrent;
    NSLog(@"ISH_PROBE task_start(pid=%d) = %d", gGuestPid, err);
    if (err < 0) {
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        return @{@"launchError": @(err), @"error": @"task_start failed"};
    }

    dispatch_group_t readers = dispatch_group_create();
    NSData *stdoutData = read_to_eof(stdoutPipe[0], readers);
    NSData *stderrData = read_to_eof(stderrPipe[0], readers);

    long processWait = dispatch_semaphore_wait(
        gExitSemaphore, dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC));
    long readerWait = dispatch_group_wait(
        readers, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));

    NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
    int rawCode = gGuestExitCode;
    int exitCode = rawCode == INT_MIN ? -1 : (rawCode & 0xff ? 128 + (rawCode & 0xff) : rawCode >> 8);

    return @{
        @"pid": @(gGuestPid),
        @"rawExitCode": @(rawCode),
        @"exitCode": @(exitCode),
        @"stdout": stdoutText,
        @"stderr": stderrText,
        @"timedOut": @(processWait != 0 || readerWait != 0),
    };
}

@end
