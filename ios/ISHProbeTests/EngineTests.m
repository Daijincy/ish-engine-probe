#import <XCTest/XCTest.h>
#import "Engine.h"

// The DSH rootfs is prepared at build time (tools/prepare-dsh-rootfs.py), so
// this test does not install anything inside the guest. It boots the kernel,
// checks the preinstalled Node, starts `dsh web`, and finally fetches the
// printed token URL over loopback. Guest sockets are mapped to host sockets by
// iSH, so a plain NSURLSession request exercises the real HTTP server.

@interface EngineTests : XCTestCase
@end

@implementation EngineTests

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

    int bootResult = [ISHEngine bootWithRootPath:destination];
    XCTAssertEqual(bootResult, 0);
    if (bootResult < 0) {
        return;
    }

    NSDictionary *nodeResult = [ISHEngine execute:@"/usr/bin/node" arguments:@[@"--version"]];
    fprintf(stdout, "\nISH_PROBE_NODE_RESULT_BEGIN\n%s\nISH_PROBE_NODE_RESULT_END\n", nodeResult.description.UTF8String);
    fflush(stdout);
    XCTAssertNil(nodeResult[@"launchError"], @"node launch failed: %@", nodeResult);
    XCTAssertFalse([nodeResult[@"timedOut"] boolValue], @"node timed out: %@", nodeResult);
    XCTAssertEqual([nodeResult[@"exitCode"] intValue], 0, @"node exit was not zero: %@", nodeResult);
    XCTAssertTrue([nodeResult[@"stdout"] hasPrefix:@"v24."], @"unexpected node version: %@", nodeResult);
    if (nodeResult[@"launchError"] != nil || [nodeResult[@"timedOut"] boolValue] || [nodeResult[@"exitCode"] intValue] != 0) {
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
        @"NODE_OPTIONS": @"--dns-result-order=ipv4first",
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

    long tokenWait = dispatch_semaphore_wait(tokenReady,
                                             dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC));
    [tailLock lock];
    NSString *output = [tail copy];
    [tailLock unlock];
    fprintf(stdout, "\nISH_PROBE_DSH_OUTPUT_BEGIN\n%s\nISH_PROBE_DSH_OUTPUT_END\n", output.UTF8String);
    fflush(stdout);
    XCTAssertEqual(tokenWait, 0, @"dsh web did not print a token URL within 15 minutes");

    NSRange marker = [output rangeOfString:@"http://127.0.0.1:"];
    XCTAssertNotEqual(marker.location, NSNotFound, @"no web URL in dsh output");
    if (marker.location == NSNotFound) {
        return;
    }
    NSString *urlText = [output substringFromIndex:marker.location];
    NSRange newline = [urlText rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (newline.location != NSNotFound) {
        urlText = [urlText substringToIndex:newline.location];
    }
    fprintf(stdout, "\nISH_PROBE_DSH_URL_%s\n", urlText.UTF8String);
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
