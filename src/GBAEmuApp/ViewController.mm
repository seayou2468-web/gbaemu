#import "./ViewController.h"

#import <dispatch/dispatch.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "./CoreWrapper/GBAEngine.h"

typedef NS_ENUM(NSInteger, GBADocumentSelectionType) {
    GBADocumentSelectionTypeROM = 0,
    GBADocumentSelectionTypeBIOS = 1,
};

@interface ViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *romStatusLabel;
@property (nonatomic, strong) UILabel *biosStatusLabel;
@property (nonatomic, strong) UIButton *loadROMButton;
@property (nonatomic, strong) UIButton *loadBIOSButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIImageView *screenView;
@property (nonatomic, strong) GBAEngine *engine;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL romLoaded;
@property (nonatomic, assign) CGColorSpaceRef frameColorSpace;
@property (nonatomic, assign) GBADocumentSelectionType documentSelectionType;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GBA iOS26 Demo";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.engine = [[GBAEngine alloc] init];
    [self.engine loadBuiltInBIOS];

    [self setupUI];
    [self refreshPlayState];
    self.statusLabel.text = @"ROMを選択してください";
    self.biosStatusLabel.text = @"BIOS: 内蔵BIOS";
}

- (void)dealloc {
    if (self.frameColorSpace != NULL) {
        CGColorSpaceRelease(self.frameColorSpace);
        self.frameColorSpace = NULL;
    }
    [self stopPlayback];
}

- (void)setupUI {
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"ROMを選択してください";
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.numberOfLines = 0;

    self.romStatusLabel = [[UILabel alloc] init];
    self.romStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.romStatusLabel.text = @"ROM: 未選択";
    self.romStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.romStatusLabel.numberOfLines = 0;

    self.biosStatusLabel = [[UILabel alloc] init];
    self.biosStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.biosStatusLabel.text = @"BIOS: 内蔵BIOS";
    self.biosStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.biosStatusLabel.numberOfLines = 0;

    self.screenView = [[UIImageView alloc] init];
    self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
    self.screenView.backgroundColor = UIColor.blackColor;
    self.screenView.layer.cornerRadius = 12.0;
    self.screenView.layer.masksToBounds = YES;
    self.screenView.contentMode = UIViewContentModeScaleAspectFit;
    self.screenView.layer.magnificationFilter = kCAFilterNearest;
    self.screenView.layer.minificationFilter = kCAFilterNearest;

    self.loadROMButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadROMButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadROMButton setTitle:@"ROMを選択" forState:UIControlStateNormal];
    [self.loadROMButton addTarget:self action:@selector(selectROM) forControlEvents:UIControlEventTouchUpInside];

    self.loadBIOSButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadBIOSButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadBIOSButton setTitle:@"BIOSを選択" forState:UIControlStateNormal];
    [self.loadBIOSButton addTarget:self action:@selector(selectBIOS) forControlEvents:UIControlEventTouchUpInside];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playPauseButton setTitle:@"再生" forState:UIControlStateNormal];
    [self.playPauseButton addTarget:self action:@selector(togglePlayback) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.screenView,
        self.statusLabel,
        self.romStatusLabel,
        self.biosStatusLabel,
        self.loadROMButton,
        self.loadBIOSButton,
        self.playPauseButton
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

        [self.screenView.heightAnchor constraintEqualToAnchor:self.screenView.widthAnchor multiplier:160.0/240.0]
    ]];
}

- (void)selectROM {
    [self presentDocumentPickerForType:GBADocumentSelectionTypeROM];
}

- (void)selectBIOS {
    [self presentDocumentPickerForType:GBADocumentSelectionTypeBIOS];
}

- (void)presentDocumentPickerForType:(GBADocumentSelectionType)selectionType {
    self.documentSelectionType = selectionType;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (selectionType == GBADocumentSelectionTypeROM) {
        [types addObject:UTTypeData];
        UTType *gbaType = [UTType typeWithFilenameExtension:@"gba"];
        if (gbaType != nil) {
            [types addObject:gbaType];
        }
    } else {
        UTType *binType = [UTType typeWithFilenameExtension:@"bin"];
        if (binType != nil) {
            [types addObject:binType];
        }
        [types addObject:UTTypeData];
    }
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

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    (void)controller;
    BOOL isBIOSSelection = (self.documentSelectionType == GBADocumentSelectionTypeBIOS);
    if (isBIOSSelection) {
        BOOL biosLoaded = [self.engine loadBIOSAtPath:url.path error:&error];
        if (biosLoaded) {
            self.biosStatusLabel.text = [NSString stringWithFormat:@"BIOS: %@", url.lastPathComponent ?: @"(不明)"];
            self.statusLabel.text = @"BIOSを読み込みました";
            if (self.romLoaded) {
                [self.engine reset];
                [self.engine setKeysPressedMask:0x0000];
                [self renderCurrentFrame];
            }
        } else {
            self.biosStatusLabel.text = @"BIOS: 読み込み失敗";
            self.statusLabel.text = error.localizedDescription ?: @"BIOSロード失敗";
        }
    } else {
        BOOL loaded = [self.engine loadROMAtPath:url.path error:&error];
        if (loaded) {
            self.romLoaded = YES;
            self.romStatusLabel.text = [NSString stringWithFormat:@"ROM: %@", url.lastPathComponent ?: @"(不明)"];
            [self.engine reset];
            [self.engine setKeysPressedMask:0x0000];
            [self renderCurrentFrame];
            if (self.displayLink == nil) {
                [self togglePlayback];
            }
            self.statusLabel.text = @"ROMを読み込みました";
        } else {
            self.romLoaded = NO;
            self.romStatusLabel.text = @"ROM: 読み込み失敗";
            self.statusLabel.text = error.localizedDescription ?: @"ROMロード失敗";
            [self stopPlayback];
        }
    }

    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }
    [self refreshPlayState];
}

- (void)togglePlayback {
    if (!self.romLoaded) {
        self.statusLabel.text = @"先にROMを選択してください";
        return;
    }

    if (self.displayLink != nil) {
        [self stopPlayback];
        self.statusLabel.text = @"一時停止しました";
        return;
    }

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.statusLabel.text = @"再生中";
    [self.playPauseButton setTitle:@"一時停止" forState:UIControlStateNormal];
}

- (void)handleDisplayLink:(CADisplayLink *)link {
    (void)link;
    const uint32_t *pixels = NULL;
    size_t pixelCount = 0;
    if (![self.engine stepFrameAndGetPointer:&pixels pixelCount:&pixelCount] ||
        pixels == NULL || pixelCount == 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"描画失敗: %@", self.engine.lastErrorMessage];
        return;
    }
    [self presentFramePixels:pixels pixelCount:pixelCount];
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
    // Always advance at least one frame before first present to avoid initial black frame.
    [self.engine stepFrame];

    size_t pixelCount = 0;
    const uint32_t *pixels = [self.engine currentFramePointerWithPixelCount:&pixelCount];
    if (pixels == NULL || pixelCount == 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"フレーム取得に失敗: %@", self.engine.lastErrorMessage];
        return;
    }
    [self presentFramePixels:pixels pixelCount:pixelCount];
}

- (void)presentFramePixels:(const uint32_t *)pixels pixelCount:(size_t)pixelCount {
    const size_t width = (size_t)GBAEngine.screenWidth;
    const size_t height = (size_t)GBAEngine.screenHeight;
    if (pixelCount < width * height) {
        return;
    }
    const size_t bytesPerRow = width * 4;
    if (self.frameColorSpace == NULL) {
        self.frameColorSpace = CGColorSpaceCreateDeviceRGB();
    }
    if (self.frameColorSpace == NULL) {
        return;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, width * height * sizeof(uint32_t), NULL);
    if (provider == NULL) {
        return;
    }

    CGImageRef imageRef = CGImageCreate(width,
                                        height,
                                        8,
                                        32,
                                        bytesPerRow,
                                        self.frameColorSpace,
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
}

@end
