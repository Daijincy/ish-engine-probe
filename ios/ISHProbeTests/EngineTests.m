#import <XCTest/XCTest.h>
#import "Engine.h"

@interface EngineTests : XCTestCase
@end

@implementation EngineTests

- (void)testAlpineUnameAndNode {
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

    NSDictionary *result = [ISHEngine execute:@"/bin/uname" arguments:@[@"-a"]];
    fprintf(stdout, "\nISH_PROBE_RESULT_BEGIN\n%s\nISH_PROBE_RESULT_END\n", result.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(result[@"launchError"], @"launch failed: %@", result);
    XCTAssertFalse([result[@"timedOut"] boolValue], @"guest process timed out: %@", result);
    XCTAssertEqual([result[@"exitCode"] intValue], 0, @"guest exit was not zero: %@", result);
    XCTAssertTrue([result[@"stdout"] containsString:@"Linux"], @"unexpected uname output: %@", result);
    if (result[@"launchError"] != nil || [result[@"timedOut"] boolValue] || [result[@"exitCode"] intValue] != 0) {
        return;
    }

    NSDictionary *installResult = [ISHEngine execute:@"/sbin/apk"
                                           arguments:@[@"add", @"--no-cache", @"--quiet", @"nodejs", @"npm"]];
    fprintf(stdout, "\nISH_PROBE_APK_RESULT_BEGIN\n%s\nISH_PROBE_APK_RESULT_END\n", installResult.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(installResult[@"launchError"], @"apk launch failed: %@", installResult);
    XCTAssertFalse([installResult[@"timedOut"] boolValue], @"apk timed out: %@", installResult);
    XCTAssertEqual([installResult[@"exitCode"] intValue], 0, @"apk install failed: %@", installResult);
    if (installResult[@"launchError"] != nil || [installResult[@"timedOut"] boolValue] || [installResult[@"exitCode"] intValue] != 0) {
        return;
    }

    NSDictionary *nodeResult = [ISHEngine execute:@"/usr/bin/node" arguments:@[@"--version"]];
    fprintf(stdout, "\nISH_PROBE_NODE_RESULT_BEGIN\n%s\nISH_PROBE_NODE_RESULT_END\n", nodeResult.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(nodeResult[@"launchError"], @"node launch failed: %@", nodeResult);
    XCTAssertFalse([nodeResult[@"timedOut"] boolValue], @"node timed out: %@", nodeResult);
    XCTAssertEqual([nodeResult[@"exitCode"] intValue], 0, @"node exit was not zero: %@", nodeResult);
    XCTAssertTrue([nodeResult[@"stdout"] hasPrefix:@"v"], @"unexpected node version: %@", nodeResult);
}

@end
