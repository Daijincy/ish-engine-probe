#import <XCTest/XCTest.h>
#import "Engine.h"

@interface EngineTests : XCTestCase
@end

@implementation EngineTests

- (void)testAlpineUname {
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
}

@end
