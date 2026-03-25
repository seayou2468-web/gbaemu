#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GBAEngine : NSObject
@property (class, nonatomic, readonly) NSInteger screenWidth;
@property (class, nonatomic, readonly) NSInteger screenHeight;

- (BOOL)loadBIOSAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (void)loadBuiltInBIOS;
- (BOOL)loadROMAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (void)reset;
- (void)stepFrame;
- (NSData * _Nullable)copyCurrentFrameData;
@end

NS_ASSUME_NONNULL_END
