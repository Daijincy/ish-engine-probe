#import <XCTest/XCTest.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#import "Engine.h"

// Exported by the iSH kernel's anonymous-memory ledger (kernel/mmap.c).
extern _Atomic long anon_page_count;
extern _Atomic long anon_page_limit;

// The DSH rootfs is prepared at build time (tools/prepare-dsh-rootfs.py). This
// test boots the kernel, checks the preinstalled Node, probes which parts of
// the V8 runtime work under the gadget interpreter, then starts `dsh web` and
// fetches the printed token URL over loopback.

// --trace-exit prints who called process.exit; dsh web exits 0 silently inside
// iSH while the same tree stays up natively, so the caller is what we need.
// The --import preload reports the live handles when the loop drains, which
// distinguishes "exited on purpose" from "an await never settled".
static NSString *const DSHNodeOptions =
    @"--dns-result-order=ipv4first --trace-exit --trace-uncaught "
    @"--import=data:text/javascript,"
    @"process.on('beforeExit',()=>console.error('BEFORE_EXIT_HANDLES',"
    @"process._getActiveHandles().map(h=>h&&h.constructor&&h.constructor.name).join('|'),"
    @"'REQS',process._getActiveRequests().map(r=>r&&r.constructor&&r.constructor.name).join('|')));"
    @"process.on('unhandledRejection',e=>console.error('UNHANDLED_REJECTION',e&&e.stack||e));"
    @"process.on('exit',c=>console.error('EXIT_EVENT',c));";

static double processCPUSeconds(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return -1;
    }
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

@interface EngineTests : XCTestCase
@end

@implementation EngineTests

- (void)printResult:(NSString *)name result:(NSDictionary *)result {
    fprintf(stdout, "\nISH_PROBE_%s_BEGIN\n%s\nISH_PROBE_%s_END\n",
            name.UTF8String, result.description.UTF8String, name.UTF8String);
    fflush(stdout);
}

- (NSDictionary *)runNodeScript:(NSString *)script name:(NSString *)name timeout:(NSTimeInterval)timeout {
    // CPU time tells us whether a slow probe is computing or deadlocked.
    // Go through /bin/sh so the kernel sees a guest execve of node and applies
    // its V8 flag set; the app reaches node the same way via the dsh wrapper.
    double cpuBefore = processCPUSeconds();
    NSDate *started = [NSDate date];
    NSDictionary *result = [ISHEngine execute:@"/bin/sh"
                                    arguments:@[@"-c", script]
                                  environment:nil
                                      timeout:timeout];
    fprintf(stdout, "\nISH_PROBE_%s_ELAPSED_%lds_CPU_%.1fs\n", name.UTF8String,
            (long)-started.timeIntervalSinceNow, processCPUSeconds() - cpuBefore);
    fflush(stdout);
    [self printResult:name result:result];
    return result;
}

- (void)testDSHWebServesTheUI {
    NSString *source = [NSBundle.mainBundle pathForResource:@"alpine-rootfs" ofType:nil];
    XCTAssertNotNil(source);
    if (source == nil) {
        return;
    }

    NSString *destination = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ish-probe-rootfs"];
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:destination error:nil];
    NSError *copyError = nil;
    BOOL copied = [files copyItemAtPath:source toPath:destination error:&copyError];
    XCTAssertTrue(copied, @"rootfs copy failed: %@", copyError);
    if (!copied) {
        return;
    }

    // DSH stalled right after small mmaps started returning ENOMEM, so the
    // guest memory ledger is what this run has to report; systrace noise is off.
    // setenv("ISH_SYSTRACE", "1", 1);

    NSDate *testStart = [NSDate date];
    int bootResult = [ISHEngine bootWithRootPath:destination];
    XCTAssertEqual(bootResult, 0);
    if (bootResult < 0) {
        return;
    }

    NSDictionary *nodeResult = [ISHEngine execute:@"/usr/bin/node"
                                          arguments:@[@"--version"]
                                        environment:nil
                                            timeout:300];
    [self printResult:@"NODE_RESULT" result:nodeResult];
    XCTAssertNil(nodeResult[@"launchError"], @"node launch failed: %@", nodeResult);
    XCTAssertEqual([nodeResult[@"exitCode"] intValue], 0, @"node exit was not zero: %@", nodeResult);
    XCTAssertTrue([nodeResult[@"stdout"] hasPrefix:@"v24."], @"unexpected node version: %@", nodeResult);
    if (nodeResult[@"launchError"] != nil || [nodeResult[@"exitCode"] intValue] != 0) {
        return;
    }

    // Probe 1: synchronous write. Needs the JS engine, not libuv. A very long
    // timeout is deliberate: if V8 is merely slow, we want the real duration.
    NSDictionary *syncResult = [self runNodeScript:
        @"exec /usr/bin/node -e \"require('fs').writeSync(1,'SYNC_OK '+process.version+'\\n')\""
                                                name:@"SYNC_RESULT" timeout:1200];
    BOOL syncWorks = [syncResult[@"stdout"] containsString:@"SYNC_OK"];

    BOOL pipeWorks = NO;
    BOOL timerWorks = NO;
    if (syncWorks) {
        // Probe 2: console.log to a pipe, which goes through libuv.
        NSDictionary *pipeResult = [self runNodeScript:@"exec /usr/bin/node -e \"console.log('PIPE_OK')\""
                                                  name:@"PIPE_RESULT" timeout:120];
        pipeWorks = [pipeResult[@"stdout"] containsString:@"PIPE_OK"];

        // Probe 3: timers, which need the event loop's epoll/wakeup path.
        NSDictionary *timerResult = [self runNodeScript:
            @"exec /usr/bin/node -e \"setTimeout(()=>require('fs').writeSync(1,'TIMER_OK\\n'),1000)\""
                                                     name:@"TIMER_RESULT" timeout:120];
        timerWorks = [timerResult[@"stdout"] containsString:@"TIMER_OK"];
    }

    // Probe 4: loopback listen + connect. If the guest cannot listen on
    // 127.0.0.1, `dsh web` silently has no server socket to keep it alive.
    NSDictionary *listenResult = [self runNodeScript:
        @"exec /usr/bin/node -e \"const net=require('net');const s=net.createServer(c=>{c.end('HI')}).listen(8791,'127.0.0.1',()=>{const c=net.connect(8791,'127.0.0.1');c.on('connect',()=>console.log('LISTEN_CONNECT_OK'));c.on('data',d=>{console.log('LISTEN_DATA_'+d);c.destroy();s.close();});c.on('error',e=>{console.log('LISTEN_CLIENT_ERR_'+e.code);s.close();});});s.on('error',e=>console.log('LISTEN_SERVER_ERR_'+e.code));setTimeout(()=>{console.log('LISTEN_TIMEOUT');process.exit(3)},15000);\""
                                                name:@"LISTEN_RESULT" timeout:120];
    BOOL listenWorks = [listenResult[@"stdout"] containsString:@"LISTEN_CONNECT_OK"];

    // The composed profile tree proves that bundle resolution works without
    // actually mounting the app; empty output means the profile is broken.
    NSDictionary *dumpResult = [self runNodeScript:@"exec /usr/local/bin/dsh --profile web --dump-config"
                                              name:@"DSH_DUMP" timeout:300];
    NSString *dump = dumpResult[@"stdout"] ?: @"";
    fprintf(stdout, "\nISH_PROBE_DSH_DUMP_BEGIN\n%.*s\nISH_PROBE_DSH_DUMP_END\n",
            (int)MIN(dump.length, (NSUInteger)2000), dump.UTF8String);

    fprintf(stdout, "\nISH_PROBE_CAPS_SYNC_%d_PIPE_%d_TIMER_%d_LISTEN_%d_DUMP_%lu\n",
            syncWorks, pipeWorks, timerWorks, listenWorks,
            (unsigned long)[dumpResult[@"stdout"] length]);
    fflush(stdout);
    if (!syncWorks) {
        // Nothing else can work if V8 itself never runs. Fail loudly: running
        // out the clock silently used to make this job look green.
        XCTFail(@"V8 did not run under the interpreter: %@", syncResult);
        return;
    }

    // The launcher itself must print commander's help; if this is empty the
    // wrapper script or the JS entry point never ran at all.
    NSDictionary *helpResult = [ISHEngine execute:@"/usr/local/bin/dsh"
                                          arguments:@[@"--help"]
                                        environment:@{@"DSH_HOME": @"/root/.dsh"}
                                            timeout:120];
    [self printResult:@"DSH_HELP" result:helpResult];

    NSMutableString *tail = [NSMutableString string];
    NSLock *tailLock = [NSLock new];
    dispatch_semaphore_t tokenReady = dispatch_semaphore_create(0);

    BOOL started = [ISHEngine startProcess:@"/usr/local/bin/dsh"
                                 arguments:@[@"web", @"--host", @"127.0.0.1", @"--port", @"8791", @"--no-open"]
                               environment:@{
        @"DSH_HOME": @"/root/.dsh",
        @"UV_USE_IO_URING": @"0",
        @"NARB_DISABLE_NATIVE_CACHE": @"1",
        @"NODE_OPTIONS": DSHNodeOptions,
        @"NODE_COMPILE_CACHE": @"/root/.dsh/node-compile-cache",
    }
                                    output:^(NSString *chunk, BOOL isStderr) {
        fprintf(stdout, "%s", chunk.UTF8String);
        fflush(stdout);
        [tailLock lock];
        [tail appendString:chunk];
        [tailLock unlock];
        if ([chunk containsString:@"token="]) {
            dispatch_semaphore_signal(tokenReady);
        }
    }
                                      exit:^(int exitCode) {
        fprintf(stdout, "\nISH_PROBE_DSH_EXITED_%d\n", exitCode);
        fflush(stdout);
        dispatch_semaphore_signal(tokenReady);
    }];
    XCTAssertTrue(started, @"dsh web did not start");
    if (!started) {
        return;
    }

    // DSH prints nothing until the web server is up, so read its progress from
    // the guest filesystem, which fakefs keeps as plain host files.
    NSString *dshHome = [destination stringByAppendingPathComponent:@"data/root/.dsh"];
    // Under the gadget interpreter every JS bytecode runs several times slower
    // than on real ARM64, so give dsh's module graph plenty of room.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:900];
    long waitResult = 1;
    while ([deadline timeIntervalSinceNow] > 0) {
        NSTimeInterval slice = MIN(60, [deadline timeIntervalSinceNow]);
        double cpuBefore = processCPUSeconds();
        waitResult = dispatch_semaphore_wait(tokenReady,
                                             dispatch_time(DISPATCH_TIME_NOW,
                                                           (int64_t)(slice * NSEC_PER_SEC)));
        if (waitResult == 0) {
            break;
        }
        NSMutableArray<NSString *> *seen = [NSMutableArray array];
        for (NSString *sub in @[@"profiles/web", @"storages", @".anonymous-user-id"]) {
            if ([files fileExistsAtPath:[dshHome stringByAppendingPathComponent:sub]]) {
                [seen addObject:sub];
            }
        }
        NSString *progress = seen.count ? [seen componentsJoinedByString:@","] : @"none";
        // Guest committed pages vs. the kernel's cap: iSH charges each
        // committed 4KB guest page as a whole 16KB host page, so hitting the
        // cap shows up as tiny mmaps failing with ENOMEM.
        fprintf(stdout, "\nISH_PROBE_PROGRESS_%lds_CPU_%.1fs_ANON_%ld_OF_%ld_%s\n",
                (long)(-testStart.timeIntervalSinceNow),
                processCPUSeconds() - cpuBefore,
                (long)atomic_load(&anon_page_count),
                (long)atomic_load(&anon_page_limit),
                progress.UTF8String);
        fflush(stdout);
    }

    [tailLock lock];
    NSString *output = [tail copy];
    [tailLock unlock];
    fprintf(stdout, "\nISH_PROBE_DSH_OUTPUT_BEGIN\n%s\nISH_PROBE_DSH_OUTPUT_END\n", output.UTF8String);
    fflush(stdout);

    NSRange marker = [output rangeOfString:@"http://127.0.0.1:"];
    if (marker.location == NSNotFound) {
        // dsh booted, then exited quietly. Dump what it left in the guest home
        // (startup diagnostics land in ~/.dsh/logs) so the failure is visible.
        NSMutableArray<NSString *> *entries = [NSMutableArray array];
        for (NSString *entry in [files enumeratorAtPath:dshHome]) {
            if (entries.count >= 40) {
                break;
            }
            [entries addObject:entry];
        }
        fprintf(stdout, "\nISH_PROBE_DSH_HOME_BEGIN\n%s\nISH_PROBE_DSH_HOME_END\n",
                [entries componentsJoinedByString:@"\n"].UTF8String);
        NSString *logsDir = [dshHome stringByAppendingPathComponent:@"logs"];
        for (NSString *log in [files contentsOfDirectoryAtPath:logsDir error:nil]) {
            NSData *logData = [NSData dataWithContentsOfFile:[logsDir stringByAppendingPathComponent:log]];
            fprintf(stdout, "\nISH_PROBE_DSH_LOG_BEGIN_%s\n%.*s\nISH_PROBE_DSH_LOG_END\n",
                    log.UTF8String, (int)MIN(logData.length, (NSUInteger)8000), (const char *)logData.bytes);
        }
        fflush(stdout);
    }
    XCTAssertNotEqual(marker.location, NSNotFound, @"no web URL in dsh output after 25 minutes");
    if (marker.location == NSNotFound) {
        return;
    }
    NSString *urlText = [output substringFromIndex:marker.location];
    NSRange newline = [urlText rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (newline.location != NSNotFound) {
        urlText = [urlText substringToIndex:newline.location];
    }
    fprintf(stdout, "\nISH_PROBE_DSH_URL_%s\nISH_PROBE_DSH_STARTUP_%lds\n",
            urlText.UTF8String, (long)-[testStart timeIntervalSinceNow]);
    fflush(stdout);

    NSURL *url = [NSURL URLWithString:urlText];
    XCTAssertNotNil(url, @"bad URL: %@", urlText);
    if (url == nil) {
        return;
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"DSH UI is served"];
    __block NSInteger status = 0;
    __block NSUInteger bodyLength = 0;
    [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        status = [(NSHTTPURLResponse *)response statusCode];
        bodyLength = data.length;
        if (error != nil) {
            fprintf(stderr, "ISH_PROBE_HTTP_ERROR %s\n", error.description.UTF8String);
        }
        fprintf(stdout, "\nISH_PROBE_HTTP_STATUS_%ld_LENGTH_%lu\n", (long)status, (unsigned long)bodyLength);
        fflush(stdout);
        [expectation fulfill];
    }] resume];
    [self waitForExpectations:@[expectation] timeout:120];

    XCTAssertEqual(status, 200, @"DSH web did not serve the UI");
    XCTAssertGreaterThan(bodyLength, 100, @"DSH web returned an empty page");
}

@end
