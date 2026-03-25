#import "./GBAEngine.h"

#include <cstdint>

#import "../../core/gba_core_c_api.h"

@implementation GBAEngine {
    GBACoreHandle *_handle;
}

+ (NSInteger)screenWidth {
    return 240;
}

+ (NSInteger)screenHeight {
    return 160;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _handle = GBA_Create();
    }
    return self;
}

- (void)dealloc {
    if (_handle != NULL) {
        GBA_Destroy(_handle);
        _handle = NULL;
    }
}

- (BOOL)loadROMAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    if (_handle == NULL) {
        if (error != nil) {
            NSDictionary *info = @{NSLocalizedDescriptionKey: @"GBAコアの初期化に失敗しました"};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1000 userInfo:info];
        }
        return NO;
    }

    const char *romPath = path.UTF8String;
    BOOL ok = GBA_LoadROMFromPath(_handle, romPath);
    if (!ok) {
        if (error != nil) {
            const char *lastError = GBA_GetLastError(_handle);
            NSString *message = (lastError != NULL && lastError[0] != '\0')
                ? [NSString stringWithUTF8String:lastError]
                : @"ROMの読み込みに失敗しました";
            NSDictionary *info = @{NSLocalizedDescriptionKey: message};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1001 userInfo:info];
        }
        return NO;
    }

    return YES;
}

- (BOOL)loadBIOSAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    if (_handle == NULL) {
        if (error != nil) {
            NSDictionary *info = @{NSLocalizedDescriptionKey: @"GBAコアの初期化に失敗しました"};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1000 userInfo:info];
        }
        return NO;
    }

    const char *biosPath = path.UTF8String;
    BOOL ok = GBA_LoadBIOSFromPath(_handle, biosPath);
    if (!ok) {
        if (error != nil) {
            const char *lastError = GBA_GetLastError(_handle);
            NSString *message = (lastError != NULL && lastError[0] != '\0')
                ? [NSString stringWithUTF8String:lastError]
                : @"BIOSの読み込みに失敗しました";
            NSDictionary *info = @{NSLocalizedDescriptionKey: message};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1002 userInfo:info];
        }
        return NO;
    }

    return YES;
}

- (void)loadBuiltInBIOS {
    if (_handle != NULL) {
        GBA_LoadBuiltInBIOS(_handle);
    }
}

- (void)reset {
    if (_handle != NULL) {
        GBA_Reset(_handle);
    }
}

- (void)stepFrame {
    if (_handle != NULL) {
        GBA_StepFrame(_handle);
    }
}

- (void)setKeysPressedMask:(uint16_t)keysPressedMask {
    if (_handle != NULL) {
        GBA_SetKeys(_handle, keysPressedMask);
    }
}

- (NSData * _Nullable)copyCurrentFrameData {
    if (_handle == NULL) {
        return nil;
    }

    size_t pixels = GBA_GetFrameBufferSize(_handle);
    if (pixels == 0) {
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:pixels * sizeof(uint32_t)];
    uint32_t *pixelBuffer = static_cast<uint32_t *>(data.mutableBytes);
    if (!GBA_CopyFrameBufferRGBA(_handle, pixelBuffer, pixels)) {
        return nil;
    }
    return data;
}

- (NSString *)lastErrorMessage {
    if (_handle == NULL) {
        return @"core handle is null";
    }
    const char *lastError = GBA_GetLastError(_handle);
    if (lastError == NULL || lastError[0] == '\0') {
        return @"(no error)";
    }
    return [NSString stringWithUTF8String:lastError];
}

@end
