#import <XCTest/XCTest.h>
#include <stdio.h>
#import "Engine.h"

// The DSH rootfs is prepared at build time (tools/prepare-dsh-rootfs.py), so
// this test does not install anything inside the guest. It boots the kernel,
// checks the preinstalled Node, measures how fast V8 interprets code, starts
// `dsh web`, and finally fetches the printed token URL over loopback. Guest
// sockets map to host sockets in iSH, so the HTTP request exercises the real
// server.

// V8 cannot request host-executable pages on an unentitled iOS build, so the
// guest runs with --jitless. That also avoids compiling every module on this
// interpreted (gadget-only) CPU.
static NSString *const DSHNodeOptions = @"--jitless --dns-result-order=ipv4first";

@interface EngineTests : XCTestCase
@end

@implementation EngineTests

- (void)printResult:(NSString *)name result:(NSDictionary *)result {
    fprintf(stdout, "\nISH_PROBE_%@_BEGIN\n%s\nISH_PROBE_%@_END\n",
            name.UTF8String, result.description.UTF8String, name.UTF8String);
    fflush(stdout);
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

    NSDictionary *nodeResult = [ISHEngine execute:@"/usr/bin/node" arguments:@[@"--version"] timeout:300];
    [self printResult:@"NODE_RESULT" result:nodeResult];
    XCTAssertNil(nodeResult[@"launchError"], @"node launch failed: %@", nodeResult);
    XCTAssertEqual([nodeResult[@"exitCode"] intValue], 0, @"node exit was not zero: %@", nodeResult);
    XCTAssertTrue([nodeResult[@"stdout"] hasPrefix:@"v24."], @"unexpected node version: %@", nodeResult);
    if (nodeResult[@"launchError"] != nil || [nodeResult[@"exitCode"] intValue] != 0) {
        return;
    }

    // First prove that V8 can at least execute a script in this CPU mode.
    NSDictionary *scriptResult = [ISHEngine execute:@"/usr/bin/node"
                                          arguments:@[@"--jitless", @"-e", @"console.log('JITLESS_OK')"]
                                        environment:nil
                                            timeout:300];
    [self printResult:@"SCRIPT_RESULT" result:scriptResult];
    XCTAssertNil(scriptResult[@"launchError"], @"script launch failed: %@", scriptResult);
    XCTAssertTrue([scriptResult[@"stdout"] containsString:@"JITLESS_OK"],
                  @"V8 could not run a script: %@", scriptResult);
    if (![scriptResult[@"stdout"] containsString:@"JITLESS_OK"]) {
        return;
    }

    // Rough calibration: how expensive is plain guest code under this CPU?
    NSDictionary *benchResult = [ISHEngine execute:@"/usr/bin/node"
                                         arguments:@[@"--jitless", @"-e",
                                                     @"let t=Date.now(),s=0;for(let i=0;i<2000000;i++)s+=i;"
                                                     @"console.log('BENCH_MS',Date.now()-t,s)"]
                                       environment:nil
                                           timeout:600];
    [self printResult:@"BENCH_RESULT" result:benchResult];

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
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3000];
    long waitResult = 1;
    while ([deadline timeIntervalSinceNow] > 0) {
        NSTimeInterval slice = MIN(60, [deadline timeIntervalSinceNow]);
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
        fprintf(stdout, "\nISH_PROBE_PROGRESS_%lds_%s\n",
                (long)(-testStart.timeIntervalSinceNow), progress.UTF8String);
        fflush(stdout);
    }

    [tailLock lock];
    NSString *output = [tail copy];
    [tailLock unlock];
    fprintf(stdout, "\nISH_PROBE_DSH_OUTPUT_BEGIN\n%s\nISH_PROBE_DSH_OUTPUT_END\n", output.UTF8String);
    fflush(stdout);

    NSRange marker = [output rangeOfString:@"http://127.0.0.1:"];
    XCTAssertNotEqual(marker.location, NSNotFound, @"no web URL in dsh output after 50 minutes");
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
    [self waitForExpectations:@[expectation] timeout:60];

    XCTAssertEqual(status, 200, @"DSH web did not serve the UI");
    XCTAssertGreaterThan(bodyLength, 100, @"DSH web returned an empty page");
}

@end
