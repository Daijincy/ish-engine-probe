#import <UIKit/UIKit.h>

#import "Engine.h"

// The guest kernel keeps `current` in a thread-local variable, so booting and
// every execute: call must happen on the same thread. All probing therefore
// runs on one background queue; anything the UI needs is handed back to the
// main queue.

static BOOL gRootfsCopied = NO;

@interface ProbeViewController : UIViewController
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UIButton *runButton;
@end

@implementation ProbeViewController {
    NSMutableString *_log;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _log = [NSMutableString string];

    self.title = @"iSH ARM64 probe";

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run probe" forState:UIControlStateNormal];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton addTarget:self action:@selector(runTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.runButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.runButton.topAnchor constraintEqualToAnchor:self.textView.bottomAnchor constant:8],
        [self.runButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.runButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.runButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.runButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // XCTest launches this app as its test host. Booting the guest here would
    // race the test's own kernel (two threads driving pid 1), which crashed
    // the run, so only auto-start outside the test host.
    BOOL underXCTest = NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] != nil ||
                       NSClassFromString(@"XCTestCase") != nil;
    if (_log.length == 0 && !underXCTest) {
        [self runTapped];
    }
}

- (void)appendText:(NSString *)text {
    if (text.length == 0) {
        return;
    }
    [_log appendString:text];
    if (_log.length > 400000) {
        [_log deleteCharactersInRange:NSMakeRange(0, _log.length - 200000)];
    }
    self.textView.text = _log;
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length, 0)];
}

// Must be called on the main queue.
- (void)appendLine:(NSString *)line {
    [self appendText:[line stringByAppendingString:@"\n"]];
}

- (void)appendResult:(NSString *)title result:(NSDictionary *)result {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"\n=== %@ ===\n", title];
    if (result[@"launchError"] != nil) {
        [out appendFormat:@"launchError: %@\n", result[@"launchError"]];
        [out appendFormat:@"error: %@\n", result[@"error"] ?: @"?"];
    } else {
        NSString *stdoutText = result[@"stdout"] ?: @"";
        NSString *stderrText = result[@"stderr"] ?: @"";
        if (stdoutText.length > 0) {
            [out appendFormat:@"stdout:\n%@", stdoutText];
            if (![stdoutText hasSuffix:@"\n"]) {
                [out appendString:@"\n"];
            }
        }
        if (stderrText.length > 0) {
            [out appendFormat:@"stderr:\n%@", stderrText];
            if (![stderrText hasSuffix:@"\n"]) {
                [out appendString:@"\n"];
            }
        }
        if (stdoutText.length == 0 && stderrText.length == 0) {
            [out appendString:@"(no output)\n"];
        }
        [out appendFormat:@"exitCode: %@%@\n", result[@"exitCode"],
                          [result[@"timedOut"] boolValue] ? @" (timed out)" : @""];
    }
    [self appendText:out];
}

- (void)runTapped {
    self.runButton.enabled = NO;
    [self appendLine:@"\n--- starting ---"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *bundleRootfs = [NSBundle.mainBundle pathForResource:@"alpine-rootfs" ofType:nil];
        if (bundleRootfs == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendLine:@"alpine-rootfs is missing from the app bundle"];
                self.runButton.enabled = YES;
            });
            return;
        }

        // fakefs needs a writable copy; the bundle itself is read-only. Copy it
        // once: after boot the kernel keeps using this directory, so deleting it
        // for a second run would pull the filesystem out from under the guest.
        NSString *cacheRoot = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *destination = [cacheRoot stringByAppendingPathComponent:@"ish-probe-rootfs"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (!gRootfsCopied) {
            // A previous app launch may have left a copy behind.
            [files removeItemAtPath:destination error:nil];
            NSError *copyError = nil;
            if (![files copyItemAtPath:bundleRootfs toPath:destination error:&copyError]) {
                NSString *message = [NSString stringWithFormat:@"rootfs copy failed: %@", copyError];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self appendLine:message];
                    self.runButton.enabled = YES;
                });
                return;
            }
            gRootfsCopied = YES;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLine:@"booting guest kernel..."];
        });

        int bootResult = [ISHEngine bootWithRootPath:destination];
        if (bootResult < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendLine:[NSString stringWithFormat:@"boot failed: %d", bootResult]];
                self.runButton.enabled = YES;
            });
            return;
        }

        NSArray<NSString *> *steps = @[
            @"/bin/uname",
            @"/bin/cat /etc/alpine-release",
            @"/usr/bin/wget -q -O /dev/null https://dl-cdn.alpinelinux.org/alpine/v3.23/main/aarch64/APKINDEX.tar.gz",
            @"/sbin/apk add --no-cache nodejs npm",
            @"/usr/bin/node --version",
            @"/usr/bin/npm --version",
            @"/usr/local/bin/dsh --version",
        ];

        for (NSString *step in steps) {
            NSArray<NSString *> *parts = [step componentsSeparatedByString:@" "];
            NSString *executable = parts.firstObject;
            NSArray<NSString *> *arguments = parts.count > 1 ? [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] : @[];
            NSDictionary *result = [ISHEngine execute:executable arguments:arguments];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendResult:step result:result];
            });
            BOOL unusable = result[@"launchError"] != nil ||
                            [result[@"timedOut"] boolValue] ||
                            [result[@"exitCode"] intValue] != 0;
            if (unusable) {
                // Later steps depend on earlier ones (apk before node, node before
                // npm, npm before dsh); stop at the first real failure.
                break;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLine:@"--- done ---"];
            self.runButton.enabled = YES;
        });
    });
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:[ProbeViewController new]];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
