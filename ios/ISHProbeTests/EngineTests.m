#import <XCTest/XCTest.h>
#include <stdio.h>
#include <sys/resource.h>
#import "Engine.h"

// The DSH rootfs is prepared at build time (tools/prepare-dsh-rootfs.py). This
// test boots the kernel, checks the preinstalled Node, probes which parts of
// the V8 runtime work under the gadget interpreter, then starts `dsh web` and
// fetches the printed token URL over loopback.

static NSString *const DSHNodeOptions = @"--dns-result-order=ipv4first";

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

    fprintf(stdout, "\nISH_PROBE_CAPS_SYNC_%d_PIPE_%d_TIMER_%d\n",
            syncWorks, pipeWorks, timerWorks);
    fflush(stdout);
    if (!syncWorks) {
        // Nothing else can work if V8 itself never runs.
        return;
    }

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
        fprintf(stdout, "\nISH_PROBE_PROGRESS_%lds_CPU_%.1fs_%s\n",
                (long)(-testStart.timeIntervalSinceNow),
                processCPUSeconds() - cpuBefore, progress.UTF8String);
        fflush(stdout);
    }

    [tailLock lock];
    NSString *output = [tail copy];
    [tailLock unlock];
    fprintf(stdout, "\nISH_PROBE_DSH_OUTPUT_BEGIN\n%s\nISH_PROBE_DSH_OUTPUT_END\n", output.UTF8String);
    fflush(stdout);

    NSRange marker = [output rangeOfString:@"http://127.0.0.1:"];
    XCTAssertNotEqual(marker.location, NSNotFound, @"no web URL in dsh output after 15 minutes");
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
