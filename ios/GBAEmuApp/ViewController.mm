#import "ViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "CoreWrapper/GBAEngine.h"

@interface ViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *biosStatusLabel;
@property (nonatomic, strong) UILabel *romStatusLabel;
@property (nonatomic, strong) UIButton *loadBIOSButton;
@property (nonatomic, strong) UIButton *loadROMButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIView *frameBufferPlaceholder;
@property (nonatomic, strong) GBAEngine *engine;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL romLoaded;
@property (nonatomic, assign) BOOL selectingBIOS;
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

    self.frameBufferPlaceholder = [[UIView alloc] init];
    self.frameBufferPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    self.frameBufferPlaceholder.backgroundColor = UIColor.blackColor;
    self.frameBufferPlaceholder.layer.cornerRadius = 12.0;

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

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.frameBufferPlaceholder,
        self.statusLabel,
        self.biosStatusLabel,
        self.romStatusLabel,
        self.loadBIOSButton,
        self.loadROMButton,
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

        [self.frameBufferPlaceholder.heightAnchor constraintEqualToAnchor:self.frameBufferPlaceholder.widthAnchor multiplier:160.0/240.0]
    ]];
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
        } else {
            self.biosStatusLabel.text = @"BIOS: 読み込み失敗（内蔵BIOS継続）";
            self.statusLabel.text = error.localizedDescription ?: @"BIOSロード失敗";
        }
    } else {
        loaded = [self.engine loadROMAtPath:url.path error:&error];
        if (loaded) {
            self.romLoaded = YES;
            self.romStatusLabel.text = [NSString stringWithFormat:@"ROM: %@", url.lastPathComponent ?: @"(不明)"];
            [self.engine reset];
            self.statusLabel.text = @"ROMを読み込みました";
        } else {
            self.romLoaded = NO;
            self.romStatusLabel.text = @"ROM: 読み込み失敗";
            self.statusLabel.text = error.localizedDescription ?: @"ROMロード失敗";
            [self stopPlayback];
        }
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
    [self.engine stepFrame];
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

@end
