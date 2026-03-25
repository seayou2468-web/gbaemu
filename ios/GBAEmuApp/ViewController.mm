#import "ViewController.h"

#import <dispatch/dispatch.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "CoreWrapper/GBAEngine.h"

@interface ViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *biosStatusLabel;
@property (nonatomic, strong) UILabel *romStatusLabel;
@property (nonatomic, strong) UIButton *loadBIOSButton;
@property (nonatomic, strong) UIButton *loadROMButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIImageView *screenView;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) GBAEngine *engine;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, strong) NSData *lastFrameData;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, assign) BOOL romLoaded;
@property (nonatomic, assign) BOOL selectingBIOS;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GBA iOS26 Demo";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.engine = [[GBAEngine alloc] init];
    self.logBuffer = [NSMutableString string];
    [self.engine loadBuiltInBIOS];

    [self setupUI];
    [self refreshPlayState];
    [self appendLog:@"起動: 内蔵BIOSを初期化しました"];
}

- (void)dealloc {
    [self stopPlayback];
}

- (void)setupUI {
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"BIOS/ROMを選択してください";
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.numberOfLines = 0;

    self.biosStatusLabel = [[UILabel alloc] init];
    self.biosStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.biosStatusLabel.text = @"BIOS: 内蔵BIOS使用中";
    self.biosStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.biosStatusLabel.numberOfLines = 0;

    self.romStatusLabel = [[UILabel alloc] init];
    self.romStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.romStatusLabel.text = @"ROM: 未選択";
    self.romStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.romStatusLabel.numberOfLines = 0;

    self.screenView = [[UIImageView alloc] init];
    self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
    self.screenView.backgroundColor = UIColor.blackColor;
    self.screenView.layer.cornerRadius = 12.0;
    self.screenView.layer.masksToBounds = YES;
    self.screenView.contentMode = UIViewContentModeScaleAspectFit;

    self.loadBIOSButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadBIOSButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadBIOSButton setTitle:@"BIOSを選択" forState:UIControlStateNormal];
    [self.loadBIOSButton addTarget:self action:@selector(selectBIOS) forControlEvents:UIControlEventTouchUpInside];

    self.loadROMButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadROMButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadROMButton setTitle:@"ROMを選択" forState:UIControlStateNormal];
    [self.loadROMButton addTarget:self action:@selector(selectROM) forControlEvents:UIControlEventTouchUpInside];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playPauseButton setTitle:@"再生" forState:UIControlStateNormal];
    [self.playPauseButton addTarget:self action:@selector(togglePlayback) forControlEvents:UIControlEventTouchUpInside];

    self.logView = [[UITextView alloc] init];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    self.logView.layer.cornerRadius = 8.0;
    self.logView.layer.masksToBounds = YES;
    self.logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.logView.text = @"[log] ready\n";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.screenView,
        self.statusLabel,
        self.biosStatusLabel,
        self.romStatusLabel,
        self.loadBIOSButton,
        self.loadROMButton,
        self.playPauseButton,
        self.logView
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.alignment = UIStackViewAlignmentFill;

    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20.0],

        [self.screenView.heightAnchor constraintEqualToAnchor:self.screenView.widthAnchor multiplier:160.0/240.0],
        [self.logView.heightAnchor constraintEqualToConstant:140.0]
    ]];
}

- (void)appendLog:(NSString *)message {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
    });
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    [self.logBuffer appendFormat:@"[%@] %@\n", stamp, message];
    self.logView.text = self.logBuffer;
    NSRange bottom = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:bottom];
}

- (void)selectBIOS {
    self.selectingBIOS = YES;
    [self presentDocumentPicker];
}

- (void)selectROM {
    self.selectingBIOS = NO;
    [self presentDocumentPicker];
}

- (void)presentDocumentPicker {
    NSArray<UTType *> *types = @[UTTypeData];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.statusLabel.text = @"ファイル選択がキャンセルされました";
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url == nil) {
        self.statusLabel.text = @"ファイルが選択されませんでした";
        return;
    }

    NSError *error = nil;
    BOOL loaded = NO;
    if (self.selectingBIOS) {
        loaded = [self.engine loadBIOSAtPath:url.path error:&error];
        if (loaded) {
            self.biosStatusLabel.text = [NSString stringWithFormat:@"BIOS: %@", url.lastPathComponent ?: @"(不明)"];
            self.statusLabel.text = @"BIOSを読み込みました";
            [self appendLog:[NSString stringWithFormat:@"BIOS load ok: %@", url.lastPathComponent ?: @"(unknown)"]];
        } else {
            self.biosStatusLabel.text = @"BIOS: 読み込み失敗（内蔵BIOS継続）";
            self.statusLabel.text = error.localizedDescription ?: @"BIOSロード失敗";
            [self appendLog:[NSString stringWithFormat:@"BIOS load fail: %@", [self.engine lastErrorMessage]]];
        }
    } else {
        loaded = [self.engine loadROMAtPath:url.path error:&error];
        if (loaded) {
            self.romLoaded = YES;
            self.romStatusLabel.text = [NSString stringWithFormat:@"ROM: %@", url.lastPathComponent ?: @"(不明)"];
            [self.engine reset];
            // Some titles do not present a visible frame immediately after reset.
            [self.engine stepFrame];
            [self.engine stepFrame];
            [self renderCurrentFrame];
            self.statusLabel.text = @"ROMを読み込みました";
            [self appendLog:[NSString stringWithFormat:@"ROM load ok: %@", url.lastPathComponent ?: @"(unknown)"]];
        } else {
            self.romLoaded = NO;
            self.romStatusLabel.text = @"ROM: 読み込み失敗";
            self.statusLabel.text = error.localizedDescription ?: @"ROMロード失敗";
            [self appendLog:[NSString stringWithFormat:@"ROM load fail: %@", [self.engine lastErrorMessage]]];
            [self stopPlayback];
        }
    }

    [self refreshPlayState];
}

- (void)togglePlayback {
    if (!self.romLoaded) {
        self.statusLabel.text = @"先にROMを選択してください";
        [self appendLog:@"再生要求: ROM未選択"];
        return;
    }

    if (self.displayLink != nil) {
        [self stopPlayback];
        self.statusLabel.text = @"一時停止しました";
        [self appendLog:@"再生停止"];
        return;
    }

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.statusLabel.text = @"再生中";
    [self.playPauseButton setTitle:@"一時停止" forState:UIControlStateNormal];
    [self appendLog:@"再生開始"];
}

- (void)handleDisplayLink:(CADisplayLink *)link {
    (void)link;
    [self.engine stepFrame];
    [self renderCurrentFrame];
}

- (void)stopPlayback {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self.playPauseButton setTitle:@"再生" forState:UIControlStateNormal];
}

- (void)refreshPlayState {
    self.playPauseButton.enabled = self.romLoaded;
    if (!self.romLoaded) {
        [self stopPlayback];
    }
}

- (void)renderCurrentFrame {
    NSData *frameData = [self.engine copyCurrentFrameData];
    if (frameData.length == 0) {
        // Retry once after advancing one frame to avoid startup black screen.
        [self.engine stepFrame];
        frameData = [self.engine copyCurrentFrameData];
        if (frameData.length == 0) {
            self.statusLabel.text = @"フレーム取得に失敗しました（ROM/BIOS状態を確認）";
            [self appendLog:[NSString stringWithFormat:@"frame copy fail: %@", [self.engine lastErrorMessage]]];
            return;
        }
    }
    self.lastFrameData = frameData;

    const size_t width = (size_t)GBAEngine.screenWidth;
    const size_t height = (size_t)GBAEngine.screenHeight;
    const size_t bytesPerRow = width * 4;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        return;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, self.lastFrameData.bytes, self.lastFrameData.length, NULL);
    if (provider == NULL) {
        CGColorSpaceRelease(colorSpace);
        return;
    }

    CGImageRef imageRef = CGImageCreate(width,
                                        height,
                                        8,
                                        32,
                                        bytesPerRow,
                                        colorSpace,
                                        static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little |
                                                                  static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst)),
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    if (imageRef != NULL) {
        self.screenView.image = [UIImage imageWithCGImage:imageRef];
        CGImageRelease(imageRef);
    }

    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

@end
