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
- (void)setKeysPressedMask:(uint16_t)keysPressedMask;
- (const uint32_t * _Nullable)currentFramePointerWithPixelCount:(size_t * _Nullable)pixelCount;
- (NSData * _Nullable)copyCurrentFrameData;
- (NSString *)lastErrorMessage;
@end

NS_ASSUME_NONNULL_END
