#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#import "Engine.h"

// The guest kernel keeps `current` in a thread-local variable. ISHEngine owns a
// dedicated engine thread, so booting and starting the server can happen on a
// background queue while WKWebView stays on the main queue.

static NSString *const DSHRootfsFolder = @"dsh-rootfs";
static NSString *const DSHRootfsMarker = @".dsh-rootfs-ready";
static NSString *const DSHListenPort = @"8787";

@interface DSHViewController : UIViewController <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIVisualEffectView *statusPanel;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIButton *logButton;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UITextView *logView;
@end

@implementation DSHViewController {
    NSMutableString *_log;
    NSMutableString *_outputTail;
    NSString *_tokenURL;
    BOOL _started;
    BOOL _processRunning;
    BOOL _logVisible;
    NSTimer *_statusTimer;
    NSDate *_startDate;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _log = [NSMutableString string];
    _outputTail = [NSMutableString string];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.allowsInlineMediaPlayback = YES;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.hidden = YES;
    [self.view addSubview:self.webView];

    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self buildStatusPanel];
    [self buildLogView];
}

- (void)buildStatusPanel {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.statusPanel = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.statusPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPanel.layer.cornerRadius = 18;
    self.statusPanel.clipsToBounds = YES;

    self.titleLabel = [UILabel new];
    self.titleLabel.text = @"DSH";
    self.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"正在准备本机 Linux 环境…";
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];

    self.logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.logButton setTitle:@"查看日志" forState:UIControlStateNormal];
    [self.logButton addTarget:self action:@selector(toggleLog) forControlEvents:UIControlEventTouchUpInside];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"重试" forState:UIControlStateNormal];
    [self.retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.titleLabel, self.spinner, self.statusLabel,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.logButton, self.retryButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 24;
    [stack addArrangedSubview:buttons];

    [self.statusPanel.contentView addSubview:stack];
    [self.view addSubview:self.statusPanel];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusPanel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusPanel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.statusPanel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [self.statusPanel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [self.statusPanel.widthAnchor constraintLessThanOrEqualToConstant:420],
        [stack.topAnchor constraintEqualToAnchor:self.statusPanel.contentView.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:self.statusPanel.contentView.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:self.statusPanel.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.statusPanel.contentView.trailingAnchor constant:-24],
    ]];
}

- (void)buildLogView {
    self.logView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    self.logView.textColor = UIColor.whiteColor;
    self.logView.hidden = YES;
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleLog)];
    [self.logView addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [self.logView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.logView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.55],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    BOOL underXCTest = NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] != nil ||
                       NSClassFromString(@"XCTestCase") != nil;
    if (!_started && !underXCTest) {
        _started = YES;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        [self startGuest];
    }
}

- (void)appendLog:(NSString *)line {
    if (line.length == 0) {
        return;
    }
    if (_log.length > 200000) {
        [_log deleteCharactersInRange:NSMakeRange(0, _log.length - 100000)];
    }
    [_log appendString:line];
    if (![line hasSuffix:@"\n"]) {
        [_log appendString:@"\n"];
    }
    if (_logVisible) {
        self.logView.text = _log;
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    }
}

- (void)setStatus:(NSString *)status spinner:(BOOL)spinner {
    self.statusLabel.text = status;
    if (spinner) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)toggleLog {
    _logVisible = !_logVisible;
    self.logView.hidden = !_logVisible;
    self.logView.text = _log;
    [self.logButton setTitle:_logVisible ? @"隐藏日志" : @"查看日志" forState:UIControlStateNormal];
    if (_logVisible) {
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    }
}

- (void)retryTapped {
    self.statusPanel.hidden = NO;
    self.retryButton.hidden = YES;
    if (_tokenURL.length > 0) {
        [self.webView reload];
        return;
    }
    if (!_processRunning) {
        [self startDSHWeb];
    }
}

#pragma mark - Startup

- (void)startGuest {
    _startDate = [NSDate date];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                   target:self
                                                 selector:@selector(updateElapsed)
                                                 userInfo:nil
                                                  repeats:YES];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatus:@"正在准备本机 Linux 环境…" spinner:YES];
        });

        NSString *bundleRootfs = [NSBundle.mainBundle pathForResource:@"alpine-rootfs" ofType:nil];
        if (bundleRootfs == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self failWithMessage:@"应用内缺少 alpine-rootfs。" exitCode:0];
            });
            return;
        }
        NSString *destination = [self rootfsDestination];
        NSError *prepareError = nil;
        if (![self prepareRootfsFrom:bundleRootfs to:destination error:&prepareError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self failWithMessage:[NSString stringWithFormat:@"复制 rootfs 失败：%@", prepareError.localizedDescription]
                            exitCode:0];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLog:@"[app] rootfs ready"];
            [self setStatus:@"正在启动 Linux 内核…" spinner:YES];
        });
        int bootResult = [ISHEngine bootWithRootPath:destination];
        if (bootResult < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self failWithMessage:[NSString stringWithFormat:@"内核启动失败（%d）", bootResult] exitCode:bootResult];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLog:@"[app] kernel booted"];
            [self startDSHWeb];
        });
    });
}

- (NSString *)rootfsDestination {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:DSHRootfsFolder];
}

- (nullable NSString *)bundledImageIdentifier:(NSString *)bundleRootfs {
    NSString *marker = [bundleRootfs stringByAppendingPathComponent:@"data/etc/dsh-image"];
    return [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)prepareRootfsFrom:(NSString *)source to:(NSString *)destination error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *image = [self bundledImageIdentifier:source] ?: @"unknown";
    NSString *markerPath = [destination stringByAppendingPathComponent:DSHRootfsMarker];
    NSString *existing = [NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil];
    if (existing != nil && [existing isEqualToString:image]) {
        return YES;
    }

    [files removeItemAtPath:destination error:nil];
    if (![files copyItemAtPath:source toPath:destination error:error]) {
        return NO;
    }
    [image writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

- (void)startDSHWeb {
    if (_processRunning) {
        return;
    }
    _processRunning = YES;
    self.statusPanel.hidden = NO;
    [self setStatus:@"正在启动 DSH Web 服务…\n首次启动需要在模拟器中执行 Node，可能需要几分钟。" spinner:YES];
    [self appendLog:@"[app] launching: dsh web --host 127.0.0.1 --port 8787 --no-open"];

    NSDictionary<NSString *, NSString *> *environment = @{
        @"DSH_HOME": @"/root/.dsh",
        @"UV_USE_IO_URING": @"0",
        @"NARB_DISABLE_NATIVE_CACHE": @"1",
        @"NODE_OPTIONS": @"--dns-result-order=ipv4first",
    };

    __weak typeof(self) weakSelf = self;
    BOOL started = [ISHEngine startProcess:@"/usr/local/bin/dsh"
                                 arguments:@[@"web", @"--host", @"127.0.0.1", @"--port", DSHListenPort, @"--no-open"]
                               environment:environment
                                    output:^(NSString *chunk, BOOL isStderr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleOutput:chunk isStderr:isStderr];
        });
    }
                                      exit:^(int exitCode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_processRunning = NO;
            [strongSelf appendLog:[NSString stringWithFormat:@"[app] dsh exited with code %d", exitCode]];
            if (strongSelf->_tokenURL.length == 0) {
                [strongSelf failWithMessage:[NSString stringWithFormat:@"DSH 已退出（退出码 %d）", exitCode] exitCode:exitCode];
            }
        });
    }];
    if (!started) {
        _processRunning = NO;
        [self failWithMessage:@"引擎尚未启动。" exitCode:0];
    }
}

- (void)handleOutput:(NSString *)chunk isStderr:(BOOL)isStderr {
    [_outputTail appendString:chunk];
    if (_outputTail.length > 65536) {
        [_outputTail deleteCharactersInRange:NSMakeRange(0, _outputTail.length - 32768)];
    }
    for (NSString *line in [chunk componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length > 0) {
            [self appendLog:[(isStderr ? @"[err] " : @"[out] ") stringByAppendingString:line]];
        }
    }

    if (_tokenURL.length > 0) {
        return;
    }
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:
        @"(http://127\\.0\\.0\\.1:[0-9]+/\\?token=[A-Za-z0-9_\\-]+)" options:0 error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:_outputTail
                                                          options:0
                                                            range:NSMakeRange(0, _outputTail.length)];
    if (match == nil) {
        return;
    }
    _tokenURL = [_outputTail substringWithRange:match.range];
    [self appendLog:[NSString stringWithFormat:@"[app] web url: %@", _tokenURL]];
    [self setStatus:@"DSH 已就绪，正在载入界面…" spinner:YES];
    self.webView.hidden = NO;
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:_tokenURL]]];
}

- (void)failWithMessage:(NSString *)message exitCode:(int)exitCode {
    [self appendLog:[NSString stringWithFormat:@"[app] error: %@", message]];
    [self setStatus:message spinner:NO];
    self.retryButton.hidden = NO;
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)updateElapsed {
    if (_tokenURL.length > 0) {
        return;
    }
    NSTimeInterval elapsed = -[_startDate timeIntervalSinceNow];
    NSString *base = _processRunning ? @"DSH Web 服务正在启动…" : @"正在准备本机 Linux 环境…";
    self.statusLabel.text = [NSString stringWithFormat:@"%@\n已等待 %d 秒（模拟执行，请耐心等待）", base, (int)elapsed];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self appendLog:@"[app] page loaded"];
    [_statusTimer invalidate];
    _statusTimer = nil;
    [self.spinner stopAnimating];
    self.statusPanel.hidden = YES;
    self.retryButton.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self appendLog:[NSString stringWithFormat:@"[app] navigation failed: %@", error.localizedDescription]];
    if (self.statusPanel.hidden) {
        self.statusPanel.hidden = NO;
    }
    [self setStatus:[NSString stringWithFormat:@"界面加载失败：%@\n可点击重试。", error.localizedDescription] spinner:NO];
    self.retryButton.hidden = NO;
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [DSHViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
