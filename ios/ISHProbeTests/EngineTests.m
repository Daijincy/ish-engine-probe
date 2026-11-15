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

    NSDictionary *configResult = [ISHEngine execute:@"/bin/cat"
                                          arguments:@[@"/etc/resolv.conf", @"/etc/apk/repositories"]];
    fprintf(stdout, "\nISH_PROBE_CONFIG_RESULT_BEGIN\n%s\nISH_PROBE_CONFIG_RESULT_END\n", configResult.description.UTF8String);
    fflush(stdout);

    NSDictionary *dnsResult = [ISHEngine execute:@"/usr/bin/nslookup"
                                       arguments:@[@"dl-cdn.alpinelinux.org"]];
    fprintf(stdout, "\nISH_PROBE_DNS_RESULT_BEGIN\n%s\nISH_PROBE_DNS_RESULT_END\n", dnsResult.description.UTF8String);
    fflush(stdout);

    NSDictionary *httpsResult = [ISHEngine execute:@"/usr/bin/wget"
                                        arguments:@[@"-S", @"-O", @"/dev/null", @"https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/APKINDEX.tar.gz"]];
    fprintf(stdout, "\nISH_PROBE_HTTPS_RESULT_BEGIN\n%s\nISH_PROBE_HTTPS_RESULT_END\n", httpsResult.description.UTF8String);
    fflush(stdout);

    NSDictionary *installResult = [ISHEngine execute:@"/sbin/apk"
                                           arguments:@[@"add", @"--no-cache", @"nodejs", @"npm"]];
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
    XCTAssertTrue([nodeResult[@"stdout"] hasPrefix:@"v24."], @"unexpected node version: %@", nodeResult);
    if (nodeResult[@"launchError"] != nil || [nodeResult[@"timedOut"] boolValue] || [nodeResult[@"exitCode"] intValue] != 0) {
        return;
    }

    NSDictionary *npmVersionResult = [ISHEngine execute:@"/usr/bin/npm" arguments:@[@"--version"]];
    fprintf(stdout, "\nISH_PROBE_NPM_VERSION_RESULT_BEGIN\n%s\nISH_PROBE_NPM_VERSION_RESULT_END\n", npmVersionResult.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(npmVersionResult[@"launchError"], @"npm --version launch failed: %@", npmVersionResult);
    XCTAssertFalse([npmVersionResult[@"timedOut"] boolValue], @"npm --version timed out: %@", npmVersionResult);
    XCTAssertEqual([npmVersionResult[@"exitCode"] intValue], 0, @"npm --version failed: %@", npmVersionResult);
    if (npmVersionResult[@"launchError"] != nil || [npmVersionResult[@"timedOut"] boolValue] || [npmVersionResult[@"exitCode"] intValue] != 0) {
        return;
    }

    NSDictionary *npmPingResult = [ISHEngine execute:@"/usr/bin/timeout"
                                           arguments:@[@"60", @"/usr/bin/npm", @"ping", @"--loglevel=verbose"]];
    fprintf(stdout, "\nISH_PROBE_NPM_PING_RESULT_BEGIN\n%s\nISH_PROBE_NPM_PING_RESULT_END\n", npmPingResult.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(npmPingResult[@"launchError"], @"npm ping launch failed: %@", npmPingResult);
    XCTAssertFalse([npmPingResult[@"timedOut"] boolValue], @"npm ping timed out: %@", npmPingResult);
    XCTAssertEqual([npmPingResult[@"exitCode"] intValue], 0, @"npm ping failed: %@", npmPingResult);
    if (npmPingResult[@"launchError"] != nil || [npmPingResult[@"timedOut"] boolValue] || [npmPingResult[@"exitCode"] intValue] != 0) {
        return;
    }

    NSDictionary *npmResult = [ISHEngine execute:@"/usr/bin/timeout"
                                       arguments:@[
                                           @"600",
                                           @"/usr/bin/npm",
                                           @"install",
                                           @"--global",
                                           @"--ignore-scripts",
                                           @"--no-audit",
                                           @"--no-fund",
                                           @"--loglevel=verbose",
                                           @"@deepseek-ai/dsh@0.2.2-rc.1",
                                           @"debug@4.4.3",
                                           @"ms@2.1.3",
                                           @"zod@4.4.3"
                                       ]];
    fprintf(stdout, "\nISH_PROBE_NPM_RESULT_BEGIN\n%s\nISH_PROBE_NPM_RESULT_END\n", npmResult.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(npmResult[@"launchError"], @"npm launch failed: %@", npmResult);
    XCTAssertFalse([npmResult[@"timedOut"] boolValue], @"npm timed out: %@", npmResult);
    XCTAssertEqual([npmResult[@"exitCode"] intValue], 0, @"npm install failed: %@", npmResult);
    if (npmResult[@"launchError"] != nil || [npmResult[@"timedOut"] boolValue] || [npmResult[@"exitCode"] intValue] != 0) {
        return;
    }

    NSDictionary *dshResult = [ISHEngine execute:@"/usr/local/bin/dsh" arguments:@[@"--version"]];
    fprintf(stdout, "\nISH_PROBE_DSH_RESULT_BEGIN\n%s\nISH_PROBE_DSH_RESULT_END\n", dshResult.description.UTF8String);
    fflush(stdout);

    XCTAssertNil(dshResult[@"launchError"], @"dsh launch failed: %@", dshResult);
    XCTAssertFalse([dshResult[@"timedOut"] boolValue], @"dsh timed out: %@", dshResult);
    XCTAssertEqual([dshResult[@"exitCode"] intValue], 0, @"dsh exit was not zero: %@", dshResult);
    NSString *versionOutput = [dshResult[@"stdout"] stringByAppendingString:dshResult[@"stderr"]];
    XCTAssertTrue([versionOutput containsString:@"0.2.2-rc.1"], @"unexpected dsh version: %@", dshResult);
}

@end
