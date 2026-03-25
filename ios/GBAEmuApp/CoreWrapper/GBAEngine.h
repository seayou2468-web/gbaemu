#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GBAEngine : NSObject
- (BOOL)loadROMAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (void)reset;
- (void)stepFrame;
@end

NS_ASSUME_NONNULL_END
