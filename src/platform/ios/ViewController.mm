#import "ViewController.h"

#import <QuartzCore/QuartzCore.h>

#include <memory>
#include <string>
#include <vector>

#include "../../core/gba_core.h"
#include "../../core/rom_loader.h"

@interface ViewController ()
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation ViewController {
  std::unique_ptr<gba::GBACore> _core;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;

  self.statusLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
  self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.statusLabel.textColor = UIColor.greenColor;
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightRegular];
  self.statusLabel.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:self.statusLabel];

  _core = std::make_unique<gba::GBACore>();

  NSString *romPath = [[NSBundle mainBundle] pathForResource:@"test" ofType:@"gba"];
  if (!romPath) {
    self.statusLabel.text = @"ROM not found in app bundle.\nAdd test.gba for runtime validation.";
    return;
  }

  std::vector<uint8_t> rom;
  std::string error;
  if (!gba::LoadFile(std::string([romPath UTF8String]), &rom, &error)) {
    self.statusLabel.text = [NSString stringWithFormat:@"Load failed: %s", error.c_str()];
    return;
  }

  if (!_core->LoadROM(rom, &error)) {
    self.statusLabel.text = [NSString stringWithFormat:@"ROM invalid: %s", error.c_str()];
    return;
  }

  self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onVSync)];
  if (@available(iOS 26.0, *)) {
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60.0, 120.0, 120.0);
  } else if (@available(iOS 18.0, *)) {
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 60.0, 60.0);
  }
  [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
}

- (uint16_t)demoKeyMaskForFrame:(uint64_t)frame {
  if (frame % 180 < 60) return gba::kKeyRight | gba::kKeyA;
  if (frame % 180 < 120) return gba::kKeyDown | gba::kKeyB;
  return gba::kKeyLeft;
}

- (void)onVSync {
  if (!_core || !_core->loaded()) return;

  _core->SetKeys([self demoKeyMaskForFrame:_core->frame_count()]);
  _core->StepFrame();

  const gba::RomInfo &info = _core->GetRomInfo();
  const gba::GameplayState &state = _core->gameplay_state();
  const uint64_t hash = _core->ComputeFrameHash();

  self.statusLabel.text = [NSString
      stringWithFormat:@"GBA Core (ObjC++)\niOS18+/iOS26 main\nTitle: %s\nCode: %s\nLogo: %d HeaderChk: %d\nFrames: %llu\nCycles: %llu\nPlayer: (%d,%d)\nScore: %u\nHash: %llu", info.title.c_str(),
                       info.game_code.c_str(), info.logo_valid, info.complement_check_valid,
                       _core->frame_count(), _core->executed_cycles(), state.player_x,
                       state.player_y, state.score, hash];
}

@end
