#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Receives raw output chunks from a guest process. Chunks are delivered on an
/// engine-owned thread, not the main queue.
typedef void (^ISHEngineOutputBlock)(NSString *chunk, BOOL isStderr);

@interface ISHEngine : NSObject

/// Boots the guest kernel. Safe to call from any thread; the kernel itself is
/// always driven by one dedicated engine thread.
+ (int)bootWithRootPath:(NSString *)rootPath;

/// Runs a guest process to completion and returns its stdout/stderr/exit code.
/// Blocks the calling thread. Must not be called while a long-running process
/// started with startProcess: is still running.
+ (NSDictionary *)execute:(NSString *)executable arguments:(NSArray<NSString *> *)arguments;

+ (NSDictionary *)execute:(NSString *)executable
                arguments:(NSArray<NSString *> *)arguments
              environment:(nullable NSDictionary<NSString *, NSString *> *)environment;

/// Starts a long-running guest process (for example `dsh web`). Returns
/// immediately; output and exit callbacks are delivered on an engine thread.
/// The kernel must already be booted with bootWithRootPath:.
+ (BOOL)startProcess:(NSString *)executable
           arguments:(NSArray<NSString *> *)arguments
         environment:(nullable NSDictionary<NSString *, NSString *> *)environment
              output:(nullable ISHEngineOutputBlock)output
                exit:(nullable void (^)(int exitCode))exitHandler;

@end

NS_ASSUME_NONNULL_END
