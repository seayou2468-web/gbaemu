#import "ViewController.h"
#import "CoreWrapper/GBAEngine.h"

@interface ViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *loadButton;
@property (nonatomic, strong) UIButton *runFrameButton;
@property (nonatomic, strong) UIView *frameBufferPlaceholder;
@property (nonatomic, strong) GBAEngine *engine;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GBA iOS26 Demo";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.engine = [[GBAEngine alloc] init];

    [self setupUI];
}

- (void)setupUI {
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"ROM未ロード";
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];

    self.frameBufferPlaceholder = [[UIView alloc] init];
    self.frameBufferPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    self.frameBufferPlaceholder.backgroundColor = UIColor.blackColor;
    self.frameBufferPlaceholder.layer.cornerRadius = 12.0;

    self.loadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadButton setTitle:@"同梱ROMをロード" forState:UIControlStateNormal];
    [self.loadButton addTarget:self action:@selector(loadBundledROM) forControlEvents:UIControlEventTouchUpInside];

    self.runFrameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runFrameButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runFrameButton setTitle:@"1フレーム実行" forState:UIControlStateNormal];
    [self.runFrameButton addTarget:self action:@selector(runOneFrame) forControlEvents:UIControlEventTouchUpInside];
    self.runFrameButton.enabled = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.frameBufferPlaceholder,
        self.statusLabel,
        self.loadButton,
        self.runFrameButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    stack.alignment = UIStackViewAlignmentFill;

    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20.0],

        [self.frameBufferPlaceholder.heightAnchor constraintEqualToAnchor:self.frameBufferPlaceholder.widthAnchor multiplier:160.0/240.0]
    ]];
}

- (void)loadBundledROM {
    NSString *romPath = [[NSBundle mainBundle] pathForResource:@"test1" ofType:@"gba"];
    if (romPath.length == 0) {
        self.statusLabel.text = @"同梱ROMが見つかりません";
        return;
    }

    NSError *error = nil;
    BOOL loaded = [self.engine loadROMAtPath:romPath error:&error];
    if (!loaded) {
        self.statusLabel.text = error.localizedDescription ?: @"ROMロード失敗";
        self.runFrameButton.enabled = NO;
        return;
    }

    [self.engine reset];
    self.statusLabel.text = @"ROMロード完了";
    self.runFrameButton.enabled = YES;
}

- (void)runOneFrame {
    [self.engine stepFrame];
    self.statusLabel.text = @"1フレーム実行しました";
}

@end
