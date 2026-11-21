#import "Engine.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "ish/kernel/init.h"
#include "ish/kernel/mm.h"
#include "ish/kernel/task.h"
#include "ish/kernel/resource.h"
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

// `current` lives in a thread-local, so every guest entry point has to run on
// the same thread for the whole lifetime of the kernel. All kernel work is
// funnelled through one dedicated NSThread with a tiny job queue.
static NSThread *gEngineThread = nil;
static NSCondition *gEngineCondition = nil;
static NSMutableArray<dispatch_block_t> *gEngineJobs = nil;

static BOOL gBooted = NO;
static int gGuestPid = -1;
static int gGuestExitCode = INT_MIN;
static dispatch_semaphore_t gExitSemaphore;

static void engine_thread_main(void) {
    @autoreleasepool {
        [gEngineCondition lock];
        while (true) {
            while (gEngineJobs.count == 0) {
                [gEngineCondition wait];
            }
            dispatch_block_t job = gEngineJobs.firstObject;
            [gEngineJobs removeObjectAtIndex:0];
            [gEngineCondition unlock];
            @autoreleasepool {
                job();
            }
            [gEngineCondition lock];
        }
    }
}

static void enqueue_engine_job(dispatch_block_t job) {
    [gEngineCondition lock];
    [gEngineJobs addObject:[job copy]];
    [gEngineCondition signal];
    [gEngineCondition unlock];
}

static void ensure_engine_thread(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gEngineCondition = [NSCondition new];
        gEngineJobs = [NSMutableArray array];
        gEngineThread = [[NSThread alloc] initWithBlock:^{
            engine_thread_main();
        }];
        gEngineThread.name = @"ish-engine";
        gEngineThread.qualityOfService = NSQualityOfServiceUserInitiated;
        [gEngineThread start];
    });
}

static BOOL on_engine_thread(void) {
    return [NSThread currentThread] == gEngineThread;
}

// Runs `block` on the engine thread and waits for it. Must not be called from a
// thread that is already waiting on a long-running guest process.
static void run_on_engine_thread_sync(dispatch_block_t block) {
    ensure_engine_thread();
    if (on_engine_thread()) {
        block();
        return;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    enqueue_engine_job(^{
        block();
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

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

static void pipe_reader(int fd, BOOL isStderr, NSMutableData *accumulator,
                        ISHEngineOutputBlock output, dispatch_group_t readers) {
    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[4096];
        while (true) {
            ssize_t count = read(fd, buffer, sizeof(buffer));
            if (count > 0) {
                @autoreleasepool {
                    if (accumulator != nil) {
                        [accumulator appendBytes:buffer length:(NSUInteger)count];
                    }
                    if (output != nil) {
                        NSString *chunk = [[NSString alloc] initWithBytes:buffer
                                                                   length:(NSUInteger)count
                                                                 encoding:NSUTF8StringEncoding];
                        if (chunk == nil) {
                            // Guest stderr is not always valid UTF-8 (V8 prints
                            // raw bytes); keep the bytes visible instead of
                            // dropping the only diagnostic we get.
                            chunk = [[NSString alloc] initWithBytes:buffer
                                                             length:(NSUInteger)count
                                                           encoding:NSISOLatin1StringEncoding];
                        }
                        if (chunk != nil) {
                            output(chunk, isStderr);
                        }
                    }
                }
            } else if (count == 0) {
                break;
            } else if (errno != EINTR) {
                NSLog(@"ISH_ENGINE pipe read failed: errno=%d", errno);
                break;
            }
        }
        close(fd);
    });
}

static NSData *build_environment(NSDictionary<NSString *, NSString *> *overrides) {
    NSMutableDictionary<NSString *, NSString *> *environment = [@{
        @"TERM": @"xterm-256color",
        @"HOME": @"/root",
        @"PATH": @"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"LANG": @"C.UTF-8",
        @"GODEBUG": @"asyncpreemptoff=1",
        @"GOMAXPROCS": @"2",
        @"NO_COLOR": @"1",
        @"PYTHONMALLOC": @"malloc",
        @"PYTHONDONTWRITEBYTECODE": @"1",
        @"UV_THREADPOOL_SIZE": @"1",
    } mutableCopy];
    [environment addEntriesFromDictionary:overrides ?: @{}];

    NSMutableData *data = [NSMutableData data];
    NSArray<NSString *> *keys = [environment.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        NSString *line = [NSString stringWithFormat:@"%@=%@", key, environment[key]];
        const char *bytes = line.UTF8String;
        [data appendBytes:bytes length:strlen(bytes) + 1];
    }
    const char terminator = '\0';
    [data appendBytes:&terminator length:1];
    return data;
}

static int boot_locked(NSString *rootPath) {
    if (gBooted) {
        return 0;
    }

    // ANON_MMAP_LIMIT_PAGES is only a ceiling. The kernel counts committed
    // anonymous pages in host-page units (16KB on iOS), so derive the real
    // budget from what the OS says we may use: a fixed 2GB ceiling would be
    // jetsam on an older iPhone, while 512MB is too little for dsh's V8 heap
    // and worklists.
    long available = (long)os_proc_available_memory();
    if (available > 0) {
        ish_set_anon_page_limit((long)(available * 0.7 / getpagesize()));
        NSLog(@"ISH_ENGINE anon limit = %ld pages (available %ld MB)",
              (long)atomic_load(&anon_page_limit), available / (1024 * 1024));
    }

    NSString *dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    int err = mount_root(&fakefs, dataPath.fileSystemRepresentation);
    NSLog(@"ISH_ENGINE mount_root(%@) = %d", dataPath, err);
    if (err < 0) {
        return err;
    }

    // This build is AOT-only: it translates nothing at run time and never asks
    // for executable pages. AOT images are what make guest code fast, so make
    // sure they are enabled (jit_control("off") would disable them, leaving the
    // gadget interpreter for every instruction).
    err = jit_control("on", 2);
    NSLog(@"ISH_ENGINE jit_control(on) = %d", err);

    err = become_first_process();
    NSLog(@"ISH_ENGINE become_first_process = %d", err);
    if (err < 0) {
        return err;
    }
    current->thread = pthread_self();

    // The rootfs is fakefsified with resolv.conf already present, but keep this
    // write so a rootfs prepared the old way still gets a usable resolver.
    const char dnsConfig[] = "nameserver 8.8.8.8\nnameserver 8.8.4.4\n";
    struct fd *dnsFD = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(dnsFD)) {
        err = PTR_ERR(dnsFD);
        NSLog(@"ISH_ENGINE open /etc/resolv.conf = %d", err);
        return err;
    }
    ssize_t dnsWritten = dnsFD->ops->write(dnsFD, dnsConfig, sizeof(dnsConfig) - 1);
    fd_close(dnsFD);
    if (dnsWritten != sizeof(dnsConfig) - 1) {
        NSLog(@"ISH_ENGINE write /etc/resolv.conf = %zd", dnsWritten);
        return -EIO;
    }

    create_device_nodes();
    err = do_mount(&procfs, "proc", "/proc", "", 0);
    NSLog(@"ISH_ENGINE mount /proc = %d", err);
    if (err < 0) {
        return err;
    }
    err = do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    NSLog(@"ISH_ENGINE mount /dev/pts = %d", err);
    if (err < 0) {
        return err;
    }

    struct fd *jitfd = generic_open("/proc/ish/jit", O_RDONLY_, 0);
    if (!IS_ERR(jitfd)) {
        char jitbuf[2048];
        // procfs only provides pread; calling a NULL ops->read jumps to 0.
        ssize_t jitlen = -1;
        if (jitfd->ops->read)
            jitlen = jitfd->ops->read(jitfd, jitbuf, sizeof(jitbuf) - 1);
        else if (jitfd->ops->pread)
            jitlen = jitfd->ops->pread(jitfd, jitbuf, sizeof(jitbuf) - 1, 0);
        fd_close(jitfd);
        if (jitlen > 0) {
            jitbuf[jitlen] = '\0';
            NSLog(@"ISH_ENGINE /proc/ish/jit:\n%s", jitbuf);
        }
    }

    tty_drivers[TTY_CONSOLE_MAJOR] = &probe_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    NSLog(@"ISH_ENGINE create_stdio = %d", err);
    if (err < 0) {
        return err;
    }

    exit_hook = probe_exit_hook;
    gBooted = YES;
    NSLog(@"ISH_ENGINE kernel booted");
    return 0;
}

// libuv calls fstat() on stdio to decide whether it is a TTY, a pipe or a file.
// A zeroed stat makes node treat the stream as unusable and console.log then
// silently produces nothing, so mirror what iSH does for piped stdio.
static void fill_stat_from_host_fd(struct fd *fd, int hostFD) {
    struct stat hostStat;
    if (fstat(hostFD, &hostStat) != 0) {
        return;
    }
    fd->stat.mode = hostStat.st_mode;
    fd->stat.rdev = dev_fake_from_real(hostStat.st_rdev);
    fd->stat.inode = hostStat.st_ino;
    fd->stat.size = hostStat.st_size;
    if (S_ISSOCK(fd->stat.mode) || isatty(hostFD)) {
        fd->stat.mode = S_IFCHR | 0620;
        fd->stat.rdev = dev_make(TTY_PSEUDO_SLAVE_MAJOR, 0);
    }
}

// Must be called on the engine thread with the kernel booted.
static NSDictionary *run_guest_process(NSString *executable,
                                       NSArray<NSString *> *arguments,
                                       NSDictionary<NSString *, NSString *> *environment,
                                       ISHEngineOutputBlock output,
                                       NSTimeInterval timeout) {
    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdoutPipe) != 0 || pipe(stderrPipe) != 0) {
        return @{@"launchError": @(-errno), @"error": @"pipe failed"};
    }

    struct task *savedCurrent = current;
    int err = become_new_init_child();
    NSLog(@"ISH_ENGINE become_new_init_child = %d", err);
    if (err < 0) {
        current = savedCurrent;
        close(stdoutPipe[0]); close(stdoutPipe[1]);
        close(stderrPipe[0]); close(stderrPipe[1]);
        return @{@"launchError": @(err), @"error": @"become_new_init_child failed"};
    }
    struct task *task = current;

    // glibc sizes new thread stacks from RLIMIT_STACK, and iSH's 128MB default
    // makes each Node worker reserve a 128MB stack. iSH caps committed
    // anonymous pages at 512MB, so the third thread's mprotect fails with
    // ENOMEM and Node then parks every thread on a futex (0.5s CPU, no
    // output). 8MB is the usual Linux default and leaves plenty of headroom.
    task->group->limits[RLIMIT_STACK_] = (struct rlimit_){8 * 1024 * 1024, RLIM_INFINITY_};

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
    fill_stat_from_host_fd(stdinFD, stdinFD->real_fd);
    fill_stat_from_host_fd(stdoutFD, stdoutFD->real_fd);
    fill_stat_from_host_fd(stderrFD, stderrFD->real_fd);
    task->files->files[0] = stdinFD;
    task->files->files[1] = stdoutFD;
    task->files->files[2] = stderrFD;

    close(stdoutPipe[1]); stdoutPipe[1] = -1;
    close(stderrPipe[1]); stderrPipe[1] = -1;

    char argvBuffer[8192];
    size_t argvPosition = 0;
    size_t argc = 0;
    NSArray<NSString *> *allArguments = [@[executable] arrayByAddingObjectsFromArray:arguments];
    for (NSString *argument in allArguments) {
        const char *value = argument.UTF8String;
        size_t length = strlen(value) + 1;
        if (argvPosition + length >= sizeof(argvBuffer)) {
            current = savedCurrent;
            close(stdoutPipe[0]);
            close(stderrPipe[0]);
            return @{@"launchError": @(-1), @"error": @"argv buffer overflow"};
        }
        memcpy(argvBuffer + argvPosition, value, length);
        argvPosition += length;
        argc++;
    }
    argvBuffer[argvPosition] = '\0';

    NSData *environmentData = build_environment(environment);

    err = do_execve(executable.UTF8String, argc, argvBuffer, environmentData.bytes);
    NSLog(@"ISH_ENGINE do_execve(%@) = %d", executable, err);
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
    NSLog(@"ISH_ENGINE task_start(pid=%d) = %d", gGuestPid, err);
    if (err < 0) {
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        return @{@"launchError": @(err), @"error": @"task_start failed"};
    }

    dispatch_group_t readers = dispatch_group_create();
    NSMutableData *stdoutData = [NSMutableData data];
    NSMutableData *stderrData = [NSMutableData data];
    pipe_reader(stdoutPipe[0], NO, stdoutData, output, readers);
    pipe_reader(stderrPipe[0], YES, stderrData, output, readers);

    dispatch_time_t deadline = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    long processWait = dispatch_semaphore_wait(gExitSemaphore, deadline);
    // Once the process is gone its fds are closed, so the pipe readers hit EOF.
    // A timed-out process may still hold them; don't block the engine forever.
    long readerWait = dispatch_group_wait(readers, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));

    NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
    int rawCode = gGuestExitCode;
    int exitCode = rawCode == INT_MIN ? -1 : (rawCode & 0xff ? 128 + (rawCode & 0xff) : rawCode >> 8);
    gExitSemaphore = nil;

    return @{
        @"pid": @(gGuestPid),
        @"rawExitCode": @(rawCode),
        @"exitCode": @(exitCode),
        @"stdout": stdoutText,
        @"stderr": stderrText,
        @"timedOut": @(processWait != 0 || readerWait != 0),
    };
}

@implementation ISHEngine

+ (int)bootWithRootPath:(NSString *)rootPath {
    __block int result = -1;
    run_on_engine_thread_sync(^{
        result = boot_locked(rootPath);
    });
    return result;
}

+ (NSDictionary *)execute:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    return [self execute:executable arguments:arguments environment:nil];
}

+ (NSDictionary *)execute:(NSString *)executable
                arguments:(NSArray<NSString *> *)arguments
              environment:(NSDictionary<NSString *, NSString *> *)environment {
    return [self execute:executable arguments:arguments environment:environment timeout:900];
}

+ (NSDictionary *)execute:(NSString *)executable
                arguments:(NSArray<NSString *> *)arguments
              environment:(NSDictionary<NSString *, NSString *> *)environment
                  timeout:(NSTimeInterval)timeout {
    __block NSDictionary *result = nil;
    run_on_engine_thread_sync(^{
        if (!gBooted) {
            result = @{@"launchError": @(-1), @"error": @"kernel is not booted"};
            return;
        }
        result = run_guest_process(executable, arguments, environment, nil, timeout);
    });
    return result;
}

+ (BOOL)startProcess:(NSString *)executable
           arguments:(NSArray<NSString *> *)arguments
         environment:(NSDictionary<NSString *, NSString *> *)environment
              output:(ISHEngineOutputBlock)output
                exit:(void (^)(int))exitHandler {
    if (!gBooted) {
        return NO;
    }
    enqueue_engine_job(^{
        NSDictionary *result = run_guest_process(executable, arguments, environment, output, 0);
        if (exitHandler != nil) {
            exitHandler([result[@"exitCode"] intValue]);
        }
    });
    return YES;
}

@end
