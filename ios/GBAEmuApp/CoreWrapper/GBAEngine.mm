#import "GBAEngine.h"

#import "../../../src/core/gba_core.h"
#import "../../../src/core/rom_loader.h"

@implementation GBAEngine {
    gbemu::GBACore *_core;
    std::vector<uint8_t> _romBuffer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _core = new gbemu::GBACore();
    }
    return self;
}

- (void)dealloc {
    delete _core;
    _core = nullptr;
}

- (BOOL)loadROMAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    std::string romPath(path.UTF8String ?: "");
    _romBuffer = gbemu::loadROM(romPath);
    if (_romBuffer.empty()) {
        if (error != nil) {
            NSDictionary *info = @{NSLocalizedDescriptionKey: @"ROMの読み込みに失敗しました"};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1001 userInfo:info];
        }
        return NO;
    }

    if (!_core->loadROM(_romBuffer)) {
        if (error != nil) {
            NSDictionary *info = @{NSLocalizedDescriptionKey: @"GBAコアへのROMロードに失敗しました"};
            *error = [NSError errorWithDomain:@"GBAEngine" code:1002 userInfo:info];
        }
        return NO;
    }

    return YES;
}

- (void)reset {
    if (_core != nullptr) {
        _core->reset();
    }
}

- (void)stepFrame {
    if (_core != nullptr) {
        _core->runFrame();
    }
}

@end
