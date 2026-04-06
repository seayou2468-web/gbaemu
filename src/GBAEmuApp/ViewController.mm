#import "./ViewController.h"

#import <dispatch/dispatch.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "./CoreWrapper/GBAEngine.h"

typedef NS_ENUM(NSInteger, GBADocumentSelectionType) {
    GBADocumentSelectionTypeROM  = 0,
    GBADocumentSelectionTypeBIOS = 1,
};

/// メモリバイト順の規約（リトルエンディアン uint32_t p）
///   b0 = p & 0xFF            … 最下位バイト / 最低アドレス
///   b1 = (p >>  8) & 0xFF
///   b2 = (p >> 16) & 0xFF
///   b3 = (p >> 24) & 0xFF    … 最上位バイト / 最高アドレス
///
/// CoreGraphics ターゲット = BGRA8888
///   メモリ [B][G][R][A]  →  uint32_t = (A<<24)|(R<<16)|(G<<8)|B
typedef NS_ENUM(uint8_t, PixelFormatType) {
    PixelFormatUnknown  = 0,
    PixelFormatRGBA8888,   // mem [R][G][B][A]  b0=R  b1=G  b2=B  b3=A
    PixelFormatARGB8888,   // mem [A][R][G][B]  b0=A  b1=R  b2=G  b3=B
    PixelFormatABGR8888,   // mem [A][B][G][R]  b0=A  b1=B  b2=G  b3=R
    PixelFormatBGRA8888,   // mem [B][G][R][A]  b0=B  b1=G  b2=R  b3=A  ← CG native
    PixelFormatRGB565,     // bits[15:11]=R [10:5]=G [4:0]=B (uint32_t 下位16bit)
};

// 検出タイムアウト・最低有効サンプル数
static const NSUInteger kPFMaxDetectFrames = 120;
static const size_t     kPFMinNonTrivial   = 64;

@interface ViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel      *statusLabel;
@property (nonatomic, strong) UILabel      *romStatusLabel;
@property (nonatomic, strong) UILabel      *biosStatusLabel;
@property (nonatomic, strong) UIButton     *loadROMButton;
@property (nonatomic, strong) UIButton     *loadBIOSButton;
@property (nonatomic, strong) UIButton     *playPauseButton;
@property (nonatomic, strong) UIImageView  *screenView;
@property (nonatomic, strong) GBAEngine   *engine;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL         romLoaded;
@property (nonatomic, assign) BOOL         biosLoaded;
@property (nonatomic, assign) CGColorSpaceRef frameColorSpace;
@property (nonatomic, strong) NSMutableData  *frameUploadBuffer;
@property (nonatomic, assign) GBADocumentSelectionType documentSelectionType;
@property (nonatomic, assign) PixelFormatType pixelFormat;
// PixelFormat 多フレーム検出用
@property (nonatomic, assign) NSUInteger   pfDetectFrameCount;
@end

@implementation ViewController

// MARK: - PixelFormat 検出 ─────────────────────────────────────────────────────
//
// 規則:
//   alphaAtB3 (RGBA/BGRA): b3=A=0xFF。b0 と b2 が RB 候補。
//     sumHi (b2) >= sumLo (b0) → b2 が R → BGRA
//     sumHi (b2)  < sumLo (b0) → b0 が R → RGBA
//
//   alphaAtB0 (ARGB/ABGR): b0=A=0xFF。b1 と b3 が RB 候補。
//     sumHi (b3) >= sumLo (b1) → b3 が R → ABGR
//     sumHi (b3)  < sumLo (b1) → b1 が R → ARGB
//
//   ヒューリスティック: ゲーム映像は暖色系が多く mean(R) >= mean(B) が成立しやすい。
//   暗すぎ/明るすぎピクセルは除外して精度を確保。
//   データ不足（暗いフレーム等）は PixelFormatUnknown を返し次フレームで再試行。
//
- (PixelFormatType)detectPixelFormat:(const uint32_t *)pixels count:(size_t)count {
    if (!pixels || count == 0) return PixelFormatUnknown;

    // ── Step 1: RGB565 判定（決定的）──────────────────────────────────────
    // RGB565 を uint32_t に格納: 上位16bitは必ず0。
    // BGRA/RGBA なら b3=A=0xFF → (p>>16) != 0 → 1ピクセル目で即終了。
    {
        BOOL couldBeRGB565 = YES;
        for (size_t i = 0; i < count; ++i) {
            if (pixels[i] >> 16u) { couldBeRGB565 = NO; break; }
        }
        if (couldBeRGB565) return PixelFormatRGB565;
    }

    // ── Step 2: 1パスで全統計収集 ─────────────────────────────────────────
    size_t cntB3FF = 0;                            // b3=0xFF → RGBA or BGRA
    size_t cntB0FF = 0;                            // b0=0xFF → ARGB or ABGR
    int64_t sumLo3 = 0, sumHi3 = 0; size_t ntB3 = 0;  // alphaAtB3 用 (b0, b2)
    int64_t sumLo0 = 0, sumHi0 = 0; size_t ntB0 = 0;  // alphaAtB0 用 (b1, b3)

    for (size_t i = 0; i < count; ++i) {
        const uint32_t p  = pixels[i];
        const uint8_t  b0 = (uint8_t)(p);
        const uint8_t  b1 = (uint8_t)(p >>  8);
        const uint8_t  b2 = (uint8_t)(p >> 16);
        const uint8_t  b3 = (uint8_t)(p >> 24);

        if (b3 == 0xFFu) cntB3FF++;
        if (b0 == 0xFFu) cntB0FF++;

        // alphaAtB3 用: b0,b2 がRB候補。どちらかが中間値ならサンプル採取
        if ((b0 > 15u || b2 > 15u) && (b0 < 240u || b2 < 240u)) {
            sumLo3 += b0; sumHi3 += b2; ntB3++;
        }
        // alphaAtB0 用: b1,b3 がRB候補
        if ((b1 > 15u || b3 > 15u) && (b1 < 240u || b3 < 240u)) {
            sumLo0 += b1; sumHi0 += b3; ntB0++;
        }
    }

    // ── Step 3: アルファ位置確定 ──────────────────────────────────────────
    const bool alphaAtB3 = (cntB3FF * 2u >= count); // RGBA or BGRA
    const bool alphaAtB0 = (cntB0FF * 2u >= count); // ARGB or ABGR
    if (!alphaAtB3 && !alphaAtB0) return PixelFormatUnknown;

    // ── Step 4: R/B チャンネル識別 ────────────────────────────────────────
    if (alphaAtB3) {
        if (ntB3 < kPFMinNonTrivial) return PixelFormatUnknown; // データ不足
        return (sumHi3 >= sumLo3) ? PixelFormatBGRA8888 : PixelFormatRGBA8888;
    } else {
        if (ntB0 < kPFMinNonTrivial) return PixelFormatUnknown;
        return (sumHi0 >= sumLo0) ? PixelFormatABGR8888 : PixelFormatARGB8888;
    }
}

- (void)resetPixelFormatState {
    self.pixelFormat       = PixelFormatUnknown;
    self.pfDetectFrameCount = 0;
}

// MARK: - ライフサイクル ───────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GBA iOS26 Demo";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.engine = [[GBAEngine alloc] init];
    [self resetPixelFormatState];
    [self setupUI];
    [self refreshPlayState];
    self.statusLabel.text  = @"ROMを選択してください（BIOSは任意）";
    self.biosStatusLabel.text = @"BIOS: 未選択（ROM直起動）";
}

- (void)dealloc {
    if (self.frameColorSpace != NULL) {
        CGColorSpaceRelease(self.frameColorSpace);
        self.frameColorSpace = NULL;
    }
    [self stopPlayback];
}

// MARK: - UI セットアップ ──────────────────────────────────────────────────────

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
    self.biosStatusLabel.text = @"BIOS: 未選択（ROM直起動）";
    self.biosStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.biosStatusLabel.numberOfLines = 0;

    self.screenView = [[UIImageView alloc] init];
    self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
    self.screenView.backgroundColor = UIColor.blackColor;
    self.screenView.layer.cornerRadius = 12.0;
    self.screenView.layer.masksToBounds = YES;
    self.screenView.contentMode = UIViewContentModeScaleAspectFit;
    self.screenView.layer.magnificationFilter = kCAFilterNearest;
    self.screenView.layer.minificationFilter  = kCAFilterNearest;

    self.loadROMButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadROMButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadROMButton setTitle:@"ROMを選択" forState:UIControlStateNormal];
    [self.loadROMButton addTarget:self action:@selector(selectROM)
                forControlEvents:UIControlEventTouchUpInside];

    self.loadBIOSButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadBIOSButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadBIOSButton setTitle:@"BIOSを選択" forState:UIControlStateNormal];
    [self.loadBIOSButton addTarget:self action:@selector(selectBIOS)
                 forControlEvents:UIControlEventTouchUpInside];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playPauseButton setTitle:@"再生" forState:UIControlStateNormal];
    [self.playPauseButton addTarget:self action:@selector(togglePlayback)
                  forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.screenView, self.statusLabel, self.romStatusLabel,
        self.biosStatusLabel, self.loadROMButton, self.loadBIOSButton,
        self.playPauseButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis      = UILayoutConstraintAxisVertical;
    stack.spacing   = 12.0;
    stack.alignment = UIStackViewAlignmentFill;

    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor  constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor  constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20.0],
        [stack.topAnchor      constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor      constant:20.0],
        [self.screenView.heightAnchor constraintEqualToAnchor:self.screenView.widthAnchor multiplier:160.0/240.0],
    ]];
}

// MARK: - ファイル選択 ─────────────────────────────────────────────────────────

- (void)selectROM  { [self presentDocumentPickerForType:GBADocumentSelectionTypeROM];  }
- (void)selectBIOS { [self presentDocumentPickerForType:GBADocumentSelectionTypeBIOS]; }

- (void)presentDocumentPickerForType:(GBADocumentSelectionType)selectionType {
    self.documentSelectionType = selectionType;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (selectionType == GBADocumentSelectionTypeROM) {
        [types addObject:UTTypeData];
        UTType *gbaType = [UTType typeWithFilenameExtension:@"gba"];
        if (gbaType) [types addObject:gbaType];
    } else {
        UTType *binType = [UTType typeWithFilenameExtension:@"bin"];
        if (binType) [types addObject:binType];
        [types addObject:UTTypeData];
    }
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.statusLabel.text = @"ファイル選択がキャンセルされました";
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) { self.statusLabel.text = @"ファイルが選択されませんでした"; return; }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;

    if (self.documentSelectionType == GBADocumentSelectionTypeBIOS) {
        BOOL ok = [self.engine loadBIOSAtPath:url.path error:&error];
        if (ok) {
            self.biosLoaded = YES;
            self.biosStatusLabel.text =
                [NSString stringWithFormat:@"BIOS: %@", url.lastPathComponent ?: @"(不明)"];
            if (self.romLoaded && ![self resetAndRenderInitialFrame]) {
                self.statusLabel.text =
                    [NSString stringWithFormat:@"初期描画失敗: %@", self.engine.lastErrorMessage];
            } else {
                self.statusLabel.text = @"BIOSを読み込みました（BIOS起動）";
            }
        } else {
            self.biosLoaded = NO;
            self.biosStatusLabel.text = @"BIOS: 読み込み失敗";
            self.statusLabel.text = error.localizedDescription ?: @"BIOSロード失敗";
        }
    } else {
        BOOL ok = [self.engine loadROMAtPath:url.path error:&error];
        if (ok) {
            self.romLoaded = YES;
            self.romStatusLabel.text =
                [NSString stringWithFormat:@"ROM: %@", url.lastPathComponent ?: @"(不明)"];
            if (![self resetAndRenderInitialFrame]) {
                self.statusLabel.text =
                    [NSString stringWithFormat:@"初期描画失敗: %@", self.engine.lastErrorMessage];
            } else if (self.biosLoaded) {
                self.statusLabel.text = @"ROMを読み込みました。再生を押してください（BIOS起動）";
            } else {
                self.statusLabel.text = @"ROMを読み込みました。再生を押してください（ROM直起動）";
            }
        } else {
            self.romLoaded = NO;
            self.romStatusLabel.text = @"ROM: 読み込み失敗";
            self.statusLabel.text = error.localizedDescription ?: @"ROMロード失敗";
            [self stopPlayback];
        }
    }

    if (scoped) [url stopAccessingSecurityScopedResource];
    [self refreshPlayState];
}

// MARK: - エミュレーション制御 ─────────────────────────────────────────────────

- (BOOL)resetAndRenderInitialFrame {
    // ROM/BIOS 入れ替え時にフォーマット検出をリセット
    [self resetPixelFormatState];
    [self.engine reset];
    [self.engine setKeysPressedMask:0x0000];

    NSString *err = self.engine.lastErrorMessage;
    if (err.length > 0 && ![err isEqualToString:@"(no error)"]) return NO;

    [self renderCurrentFrame];
    return YES;
}

- (void)togglePlayback {
    if (!self.romLoaded) {
        self.statusLabel.text = @"先にROMを選択してください";
        return;
    }
    if (self.displayLink) {
        [self stopPlayback];
        self.statusLabel.text = @"一時停止しました";
        return;
    }
    if (![self resetAndRenderInitialFrame]) {
        self.statusLabel.text =
            [NSString stringWithFormat:@"開始失敗: %@", self.engine.lastErrorMessage];
        return;
    }
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(handleDisplayLink:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.statusLabel.text = @"再生中";
    [self.playPauseButton setTitle:@"一時停止" forState:UIControlStateNormal];
}

- (void)handleDisplayLink:(CADisplayLink *)link {
    (void)link;
    const uint32_t *pixels = NULL;
    size_t pixelCount = 0;
    if (![self.engine stepFrameAndGetPointer:&pixels pixelCount:&pixelCount] ||
        !pixels || pixelCount == 0) {
        self.statusLabel.text =
            [NSString stringWithFormat:@"描画失敗: %@", self.engine.lastErrorMessage];
        [self stopPlayback];
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
    if (!self.romLoaded) [self stopPlayback];
}

- (void)renderCurrentFrame {
    size_t pixelCount = 0;
    const uint32_t *pixels = [self.engine currentFramePointerWithPixelCount:&pixelCount];
    if (!pixels || pixelCount == 0) {
        self.statusLabel.text =
            [NSString stringWithFormat:@"フレーム取得に失敗: %@", self.engine.lastErrorMessage];
        return;
    }
    [self presentFramePixels:pixels pixelCount:pixelCount];
}

// MARK: - フレーム描画（フォーマット変換付き）────────────────────────────────

- (void)presentFramePixels:(const uint32_t *)pixels pixelCount:(size_t)pixelCount {
    const size_t width  = (size_t)GBAEngine.screenWidth;
    const size_t height = (size_t)GBAEngine.screenHeight;
    if (pixelCount < width * height) return;

    // ── フォーマット自動検出（未確定の間は毎フレーム再試行）────────────────
    if (self.pixelFormat == PixelFormatUnknown) {
        self.pfDetectFrameCount++;
        PixelFormatType detected = [self detectPixelFormat:pixels count:pixelCount];
        if (detected != PixelFormatUnknown) {
            self.pixelFormat = detected;
            NSLog(@"[frappe] PixelFormat決定: %d (frame %lu)",
                  (int)detected, (unsigned long)self.pfDetectFrameCount);
        } else if (self.pfDetectFrameCount >= kPFMaxDetectFrames) {
            // タイムアウト → iOS ネイティブ BGRA にフォールバック
            self.pixelFormat = PixelFormatBGRA8888;
            NSLog(@"[frappe] PixelFormat検出タイムアウト → BGRA8888");
        }
        // まだ未確定なら描画をスキップ（最初の数フレームのみ発生しうる）
        if (self.pixelFormat == PixelFormatUnknown) return;
    }

    // ── バッファ確保 ──────────────────────────────────────────────────────
    if (self.frameColorSpace == NULL) {
        self.frameColorSpace = CGColorSpaceCreateDeviceRGB();
        if (self.frameColorSpace == NULL) return;
    }

    const size_t frameBytes = width * height * sizeof(uint32_t);
    if (!self.frameUploadBuffer || self.frameUploadBuffer.length != frameBytes) {
        self.frameUploadBuffer = [NSMutableData dataWithLength:frameBytes];
    }
    uint32_t * const dst = static_cast<uint32_t *>(self.frameUploadBuffer.mutableBytes);
    if (!dst) return;

    // ── フォーマット変換 → CoreGraphics ターゲット BGRA8888 ──────────────
    // ターゲット uint32_t = (A<<24)|(R<<16)|(G<<8)|B
    //
    // 各フォーマットの b0〜b3 定義:
    //   RGBA: b0=R  b1=G  b2=B  b3=A
    //   ARGB: b0=A  b1=R  b2=G  b3=B
    //   ABGR: b0=A  b1=B  b2=G  b3=R
    //   BGRA: b0=B  b1=G  b2=R  b3=A  ← ターゲットと同一 → memcpy

    const size_t total = width * height;

    switch (self.pixelFormat) {

        case PixelFormatRGB565:
            // RGB565: bits[15:11]=R5  [10:5]=G6  [4:0]=B5
            for (size_t i = 0; i < total; ++i) {
                const uint32_t s  = pixels[i];
                const uint32_t r5 = (s >> 11) & 0x1Fu;
                const uint32_t g6 = (s >>  5) & 0x3Fu;
                const uint32_t b5 = (s)        & 0x1Fu;
                const uint32_t r  = (r5 << 3) | (r5 >> 2);
                const uint32_t g  = (g6 << 2) | (g6 >> 4);
                const uint32_t b  = (b5 << 3) | (b5 >> 2);
                // ターゲット: (A<<24)|(R<<16)|(G<<8)|B
                dst[i] = (0xFFu << 24) | (r << 16) | (g << 8) | b;
            }
            break;

        case PixelFormatRGBA8888:
            // b0=R b1=G b2=B b3=A → (A<<24)|(R<<16)|(G<<8)|B
            for (size_t i = 0; i < total; ++i) {
                const uint32_t s = pixels[i];
                const uint32_t r = (s)        & 0xFFu; // b0
                const uint32_t g = (s >>  8)  & 0xFFu; // b1
                const uint32_t b = (s >> 16)  & 0xFFu; // b2
                const uint32_t a = (s >> 24)  & 0xFFu; // b3
                dst[i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
            break;

        case PixelFormatARGB8888:
            // b0=A b1=R b2=G b3=B → (A<<24)|(R<<16)|(G<<8)|B
            for (size_t i = 0; i < total; ++i) {
                const uint32_t s = pixels[i];
                const uint32_t a = (s)        & 0xFFu; // b0
                const uint32_t r = (s >>  8)  & 0xFFu; // b1
                const uint32_t g = (s >> 16)  & 0xFFu; // b2
                const uint32_t b = (s >> 24)  & 0xFFu; // b3
                dst[i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
            break;

        case PixelFormatABGR8888:
            // b0=A b1=B b2=G b3=R → (A<<24)|(R<<16)|(G<<8)|B
            for (size_t i = 0; i < total; ++i) {
                const uint32_t s = pixels[i];
                const uint32_t a = (s)        & 0xFFu; // b0
                const uint32_t b = (s >>  8)  & 0xFFu; // b1
                const uint32_t g = (s >> 16)  & 0xFFu; // b2
                const uint32_t r = (s >> 24)  & 0xFFu; // b3
                dst[i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
            break;

        case PixelFormatBGRA8888:
            // b0=B b1=G b2=R b3=A → ターゲットと同一
            memcpy(dst, pixels, frameBytes);
            break;

        default:
            return; // PixelFormatUnknown はここに到達しない
    }

    // ── CGImage 生成・表示 ────────────────────────────────────────────────
    const size_t bytesPerRow = width * 4;
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(NULL, dst, frameBytes, NULL);
    if (!provider) return;

    CGImageRef imageRef = CGImageCreate(
        width, height,
        8, 32, bytesPerRow,
        self.frameColorSpace,
        static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little |
                                   kCGImageAlphaPremultipliedFirst),
        provider, NULL, false, kCGRenderingIntentDefault);

    CGDataProviderRelease(provider);

    if (imageRef) {
        self.screenView.image = [UIImage imageWithCGImage:imageRef];
        CGImageRelease(imageRef);
    }
}

@end
