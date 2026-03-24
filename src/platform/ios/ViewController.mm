#import "ViewController.h"

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <memory>
#include <string>
#include <vector>

#include "../../core/gba_core.h"
#include "../../core/rom_loader.h"

namespace {
constexpr CGFloat kHUDHeight = 152.0;
constexpr CGFloat kButtonSize = 64.0;
constexpr CGFloat kButtonGap = 10.0;
constexpr CGFloat kDPadInset = 24.0;
constexpr CGFloat kActionInset = 30.0;
constexpr CGFloat kStartButtonWidth = 84.0;
constexpr CGFloat kStartButtonHeight = 40.0;
}

@interface VirtualKeyButton : UIButton
@property(nonatomic, assign) uint16_t keyMask;
@end

@implementation VirtualKeyButton
@end

@interface ViewController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIImageView *screenView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *hudLabel;
@property(nonatomic, strong) UILabel *biosLabel;
@property(nonatomic, strong) UISegmentedControl *biosModeControl;
@property(nonatomic, strong) UIButton *pickBiosButton;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) NSMutableArray<VirtualKeyButton *> *allButtons;
@property(nonatomic, strong) NSMapTable<UITouch *, VirtualKeyButton *> *activeTouches;
@property(nonatomic, strong) NSData *externalBiosData;
@property(nonatomic, assign) CFTimeInterval lastTick;
@property(nonatomic, assign) BOOL paused;
@end

@implementation ViewController {
  std::unique_ptr<gba::GBACore> _core;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;
  self.allButtons = [NSMutableArray array];
  self.activeTouches = [NSMapTable weakToWeakObjectsMapTable];
  self.paused = NO;

  [self buildLayout];

  _core = std::make_unique<gba::GBACore>();
  if (![self applyBIOSSelection]) {
    return;
  }
  if (![self loadROMFromBundle]) {
    return;
  }

  self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onVSync:)];
  if (@available(iOS 26.0, *)) {
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60.0, 120.0, 60.0);
  } else if (@available(iOS 18.0, *)) {
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 60.0, 60.0);
  }
  [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
}

- (void)buildLayout {
  CGRect bounds = self.view.bounds;

  self.screenView = [[UIImageView alloc] initWithFrame:CGRectZero];
  self.screenView.backgroundColor = UIColor.blackColor;
  self.screenView.contentMode = UIViewContentModeScaleAspectFit;
  self.screenView.layer.magnificationFilter = kCAFilterNearest;
  self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.screenView];

  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.statusLabel.textColor = [UIColor colorWithRed:0.42 green:1.0 blue:0.45 alpha:1.0];
  self.statusLabel.numberOfLines = 3;
  self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
  self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.statusLabel];

  self.hudLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.hudLabel.textColor = UIColor.whiteColor;
  self.hudLabel.numberOfLines = 5;
  self.hudLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
  self.hudLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.hudLabel];

  self.biosModeControl = [[UISegmentedControl alloc] initWithItems:@[@"Built-in BIOS", @"BIOS file"]];
  self.biosModeControl.selectedSegmentIndex = 0;
  self.biosModeControl.translatesAutoresizingMaskIntoConstraints = NO;
  [self.biosModeControl addTarget:self action:@selector(onBiosModeChanged) forControlEvents:UIControlEventValueChanged];
  [self.view addSubview:self.biosModeControl];

  self.pickBiosButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.pickBiosButton setTitle:@"Pick BIOS" forState:UIControlStateNormal];
  self.pickBiosButton.translatesAutoresizingMaskIntoConstraints = NO;
  [self.pickBiosButton addTarget:self action:@selector(onPickBios) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.pickBiosButton];

  self.biosLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.biosLabel.text = @"BIOS: built-in";
  self.biosLabel.numberOfLines = 2;
  self.biosLabel.textColor = UIColor.lightGrayColor;
  self.biosLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
  self.biosLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.biosLabel];

  [NSLayoutConstraint activateConstraints:@[
    [self.screenView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
    [self.screenView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
    [self.screenView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:42.0],
    [self.screenView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-(kHUDHeight + 8.0)],

    [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
    [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
    [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.screenView.bottomAnchor constant:-8.0],

    [self.hudLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
    [self.hudLabel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
    [self.hudLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6.0],

    [self.biosModeControl.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
    [self.biosModeControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6.0],
    [self.pickBiosButton.leadingAnchor constraintEqualToAnchor:self.biosModeControl.trailingAnchor constant:8.0],
    [self.pickBiosButton.centerYAnchor constraintEqualToAnchor:self.biosModeControl.centerYAnchor],
    [self.biosLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
    [self.biosLabel.topAnchor constraintEqualToAnchor:self.biosModeControl.bottomAnchor constant:2.0],
  ]];

  [self buildVirtualPadInRect:bounds];
}

- (VirtualKeyButton *)makeButtonWithTitle:(NSString *)title key:(uint16_t)key {
  VirtualKeyButton *button = [VirtualKeyButton buttonWithType:UIButtonTypeSystem];
  button.keyMask = key;
  button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.8];
  button.layer.cornerRadius = kButtonSize * 0.35;
  button.layer.borderWidth = 1.0;
  button.layer.borderColor = UIColor.whiteColor.CGColor;
  button.tintColor = UIColor.whiteColor;
  button.titleLabel.font = [UIFont monospacedSystemFontOfSize:16.0 weight:UIFontWeightBold];
  [button setTitle:title forState:UIControlStateNormal];
  [self.view addSubview:button];
  [self.allButtons addObject:button];
  return button;
}

- (void)buildVirtualPadInRect:(CGRect)bounds {
  const CGFloat bottomY = CGRectGetMaxY(bounds) - kButtonSize - 20.0;
  const CGFloat dpadX = kDPadInset + kButtonSize;

  VirtualKeyButton *up = [self makeButtonWithTitle:@"↑" key:gba::kKeyUp];
  VirtualKeyButton *down = [self makeButtonWithTitle:@"↓" key:gba::kKeyDown];
  VirtualKeyButton *left = [self makeButtonWithTitle:@"←" key:gba::kKeyLeft];
  VirtualKeyButton *right = [self makeButtonWithTitle:@"→" key:gba::kKeyRight];

  up.frame = CGRectMake(dpadX, bottomY - kButtonSize - kButtonGap, kButtonSize, kButtonSize);
  down.frame = CGRectMake(dpadX, bottomY, kButtonSize, kButtonSize);
  left.frame = CGRectMake(dpadX - kButtonSize - kButtonGap, bottomY, kButtonSize, kButtonSize);
  right.frame = CGRectMake(dpadX + kButtonSize + kButtonGap, bottomY, kButtonSize, kButtonSize);

  const CGFloat actionX = CGRectGetMaxX(bounds) - kActionInset - (kButtonSize * 2.0) - kButtonGap;
  VirtualKeyButton *a = [self makeButtonWithTitle:@"A" key:gba::kKeyA];
  VirtualKeyButton *b = [self makeButtonWithTitle:@"B" key:gba::kKeyB];
  a.frame = CGRectMake(actionX + kButtonSize + kButtonGap, bottomY - 18.0, kButtonSize, kButtonSize);
  b.frame = CGRectMake(actionX, bottomY + 16.0, kButtonSize, kButtonSize);

  VirtualKeyButton *l = [self makeButtonWithTitle:@"L" key:gba::kKeyL];
  VirtualKeyButton *r = [self makeButtonWithTitle:@"R" key:gba::kKeyR];
  l.frame = CGRectMake(14.0, CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame) + 6.0, 58.0, 32.0);
  r.frame = CGRectMake(CGRectGetMaxX(bounds) - 72.0, CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame) + 6.0, 58.0, 32.0);

  for (VirtualKeyButton *btn in @[l, r]) {
    btn.layer.cornerRadius = 8.0;
    btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightHeavy];
  }

  VirtualKeyButton *start = [self makeButtonWithTitle:@"START" key:gba::kKeyStart];
  VirtualKeyButton *select = [self makeButtonWithTitle:@"SELECT" key:gba::kKeySelect];
  const CGFloat centerX = CGRectGetMidX(bounds);
  start.frame = CGRectMake(centerX + 8.0, bottomY + kButtonSize - 5.0, kStartButtonWidth, kStartButtonHeight);
  select.frame = CGRectMake(centerX - kStartButtonWidth - 8.0, bottomY + kButtonSize - 5.0, kStartButtonWidth, kStartButtonHeight);
  start.layer.cornerRadius = 10.0;
  select.layer.cornerRadius = 10.0;
  start.titleLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightBold];
  select.titleLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightBold];

  UIButton *pauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
  pauseButton.frame = CGRectMake(centerX - 50.0, bottomY - 46.0, 100.0, 34.0);
  pauseButton.layer.cornerRadius = 8.0;
  pauseButton.backgroundColor = [UIColor colorWithRed:0.22 green:0.22 blue:0.28 alpha:0.9];
  [pauseButton setTitle:@"Pause/Resume" forState:UIControlStateNormal];
  pauseButton.titleLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
  [pauseButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  [pauseButton addTarget:self action:@selector(togglePause) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:pauseButton];
}

- (BOOL)applyBIOSSelection {
  if (self.biosModeControl.selectedSegmentIndex == 0) {
    _core->LoadBuiltInBIOS();
    self.biosLabel.text = @"BIOS: built-in";
    return YES;
  }
  if (self.externalBiosData.length == 0) {
    self.statusLabel.text = @"Select BIOS file first (16KB).";
    return NO;
  }
  std::vector<uint8_t> bios(self.externalBiosData.length);
  [self.externalBiosData getBytes:bios.data() length:self.externalBiosData.length];
  std::string error;
  if (!_core->LoadBIOS(bios, &error)) {
    self.statusLabel.text = [NSString stringWithFormat:@"BIOS load failed: %s", error.c_str()];
    return NO;
  }
  self.biosLabel.text = [NSString stringWithFormat:@"BIOS: file (%lu bytes)", (unsigned long)self.externalBiosData.length];
  return YES;
}

- (void)onBiosModeChanged {
  if ([self applyBIOSSelection]) {
    self.statusLabel.text = @"BIOS mode changed.";
  }
}

- (void)onPickBios {
  UIDocumentPickerViewController *picker = nil;
  if (@available(iOS 14.0, *)) {
    picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]];
  } else {
    picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport];
  }
  picker.delegate = self;
  picker.allowsMultipleSelection = NO;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  (void)controller;
  NSURL *url = urls.firstObject;
  if (!url) return;
  NSError *err = nil;
  NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&err];
  if (!data || err) {
    self.statusLabel.text = [NSString stringWithFormat:@"BIOS read failed: %@", err.localizedDescription ?: @"unknown"];
    return;
  }
  self.externalBiosData = data;
  self.biosLabel.text = [NSString stringWithFormat:@"BIOS file selected: %@ (%lu bytes)", url.lastPathComponent, (unsigned long)data.length];
  [self applyBIOSSelection];
}

- (BOOL)loadROMFromBundle {
  NSString *romPath = [[NSBundle mainBundle] pathForResource:@"test" ofType:@"gba"];
  if (!romPath) {
    self.statusLabel.text = @"ROM not found in app bundle. Add test.gba";
    return NO;
  }

  std::vector<uint8_t> rom;
  std::string error;
  if (!gba::LoadFile(std::string([romPath UTF8String]), &rom, &error)) {
    self.statusLabel.text = [NSString stringWithFormat:@"Load failed: %s", error.c_str()];
    return NO;
  }

  if (!_core->LoadROM(rom, &error)) {
    self.statusLabel.text = [NSString stringWithFormat:@"ROM invalid: %s", error.c_str()];
    return NO;
  }

  self.statusLabel.text = @"ROM loaded. Multi-touch virtual pad enabled.";
  return YES;
}

- (void)togglePause {
  self.paused = !self.paused;
}

- (void)rebuildKeyMaskFromTouches {
  uint16_t mask = 0;
  for (UITouch *touch in self.activeTouches.keyEnumerator) {
    VirtualKeyButton *btn = [self.activeTouches objectForKey:touch];
    if (btn) {
      mask |= btn.keyMask;
      btn.alpha = 1.0;
      btn.backgroundColor = [UIColor colorWithRed:0.31 green:0.45 blue:0.95 alpha:0.95];
    }
  }
  for (VirtualKeyButton *button in self.allButtons) {
    BOOL active = NO;
    for (UITouch *touch in self.activeTouches.keyEnumerator) {
      if ([self.activeTouches objectForKey:touch] == button) {
        active = YES;
        break;
      }
    }
    if (!active) {
      button.alpha = 0.8;
      button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.8];
    }
  }
  _core->SetKeys(mask);
}

- (VirtualKeyButton *)buttonAtPoint:(CGPoint)point {
  for (VirtualKeyButton *button in self.allButtons) {
    if (CGRectContainsPoint(button.frame, point)) {
      return button;
    }
  }
  return nil;
}

- (void)trackTouches:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    const CGPoint location = [touch locationInView:self.view];
    VirtualKeyButton *button = [self buttonAtPoint:location];
    if (button) {
      [self.activeTouches setObject:button forKey:touch];
    } else {
      [self.activeTouches removeObjectForKey:touch];
    }
  }
  [self rebuildKeyMaskFromTouches];
}

- (void)clearTouches:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    [self.activeTouches removeObjectForKey:touch];
  }
  [self rebuildKeyMaskFromTouches];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  [self trackTouches:touches];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  [self trackTouches:touches];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  [self clearTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  [self clearTouches:touches];
}

- (void)onVSync:(CADisplayLink *)sender {
  if (!_core || !_core->loaded()) return;

  if (self.paused) {
    self.hudLabel.text = [NSString stringWithFormat:@"PAUSED\nframe=%llu\nkeys=0x%03X",
                          _core->frame_count(), _core->GetKeys()];
    return;
  }

  const CFTimeInterval now = sender.timestamp;
  if (self.lastTick == 0) {
    self.lastTick = now;
  }
  CFTimeInterval dt = now - self.lastTick;
  self.lastTick = now;
  if (dt < 0) dt = 0;

  int steps = 1;
  if (dt > (1.0 / 55.0)) steps = 2;
  if (dt > (1.0 / 30.0)) steps = 3;

  for (int i = 0; i < steps; ++i) {
    _core->StepFrame();
  }

  [self presentFrameBuffer];
  [self updateHUDWithFrameDelta:dt frameSteps:steps];
}

- (void)presentFrameBuffer {
  const std::vector<uint32_t> &fb = _core->GetFrameBuffer();
  if (fb.empty()) return;

  const size_t width = gba::GBACore::kScreenWidth;
  const size_t height = gba::GBACore::kScreenHeight;
  const size_t bytesPerRow = width * sizeof(uint32_t);

  CGDataProviderRef provider =
      CGDataProviderCreateWithData(nullptr, fb.data(), fb.size() * sizeof(uint32_t), nullptr);

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace,
                                   kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                   provider, nullptr, false, kCGRenderingIntentDefault);

  self.screenView.image = [UIImage imageWithCGImage:image scale:1.0 orientation:UIImageOrientationUp];

  CGImageRelease(image);
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(provider);
}

- (void)updateHUDWithFrameDelta:(CFTimeInterval)dt frameSteps:(int)steps {
  const gba::RomInfo &info = _core->GetRomInfo();
  const gba::GameplayState &state = _core->gameplay_state();
  const uint64_t hash = _core->ComputeFrameHash();

  self.statusLabel.text = [NSString
      stringWithFormat:@"GBA iOS ObjC++ frontend\nTitle=%s Code=%s\nLogo=%d HeaderChk=%d",
                       info.title.c_str(), info.game_code.c_str(), info.logo_valid,
                       info.complement_check_valid];

  self.hudLabel.text = [NSString
      stringWithFormat:@"frame=%llu cycles=%llu\nkeys=0x%03X dt=%.2fms steps=%d\nplayer=(%d,%d) score=%u\ncheckpoints=0x%X clear=%d\nhash=%llu",
                       _core->frame_count(), _core->executed_cycles(), _core->GetKeys(), dt * 1000.0,
                       steps, state.player_x, state.player_y, state.score,
                       static_cast<unsigned>(state.checkpoints), state.cleared, hash];
}

@end
