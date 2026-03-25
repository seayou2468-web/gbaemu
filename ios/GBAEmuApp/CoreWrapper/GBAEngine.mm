#import "GBAEngine.h"

#import "../../../src/core/gba_core.h"
#import "../../../src/core/rom_loader.h"

@implementation GBAEngine {
    gba::GBACore *_core;
    std::vector<uint8_t> _romBuffer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _core = new gba::GBACore();
    }
    return self;
}

- (void)dealloc {
    delete _core;
    _core = nullptr;
}

- (BOOL)loadROMAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    std::string romPath(path.UTF8String ?: "");
    std::string loadError;

    if (!gba::LoadFile(romPath, &_romBuffer, &loadError) || _romBuffer.empty()) {
        if (error != nil) {
            NSString *message = loadError.empty()
                ? @"ROMの読み込みに失敗しました"
                : [NSString stringWithUTF8String:loadError.c_str()];
            NSDictionary *info = @{NSLocalizedDescriptionKey: message};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1001 userInfo:info];
        }
        return NO;
    }

    loadError.clear();
    if (!_core->LoadROM(_romBuffer, &loadError)) {
        if (error != nil) {
            NSString *message = loadError.empty()
                ? @"GBAコアへのROMロードに失敗しました"
                : [NSString stringWithUTF8String:loadError.c_str()];
            NSDictionary *info = @{NSLocalizedDescriptionKey: message};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1002 userInfo:info];
        }
        return NO;
    }

    return YES;
}

- (void)reset {
    if (_core != nullptr) {
        _core->Reset();
    }
}

- (void)stepFrame {
    if (_core != nullptr) {
        _core->StepFrame();
    }
}

@end
