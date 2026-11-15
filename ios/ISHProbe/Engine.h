#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISHEngine : NSObject

+ (int)bootWithRootPath:(NSString *)rootPath;
+ (NSDictionary *)execute:(NSString *)executable arguments:(NSArray<NSString *> *)arguments;

@end

NS_ASSUME_NONNULL_END
