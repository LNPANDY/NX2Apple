// Launcher for the Windows build: a UIKit port of dm/ios/Sources/Launcher.swift (SwiftUI), so
// the app builds with clang alone and needs no Swift toolchain.
//
// The contract is unchanged: dm_show_launcher(view_controller, done) shows the settings screen
// over the root view controller, puts every setting into the environment when Play is pressed,
// then calls done(). It returns false (and does not call done) when there is no launcher: no
// dm/launcher.json, DM_LAUNCHER=0, or a file it cannot read — front_ios.m then starts the game
// at once.
//
// The JSON comes from dm/games/settings.py, which is the same file the Swift launcher reads, so
// every field the Swift model decodes must be honoured here:
//
//   env      the environment variable the setting sets (required)
//   kind     "choice" (options [[value, label]]), "range" (min / max / step, shown as a
//            percentage) or "toggle" (on / off - the two values the variable takes; "1" / "0"
//            when absent)
//   label    the row's title (required)
//   note     the section footer explaining the setting (required, may be empty)
//   default  the shipped value (required)
//   section  the heading the row sits under; older bundles have none, then it is "Game"
//   on/off   a toggle's two values
//
// Behaviour that the Swift side has and a naive port would lose:
//   * a variable set by an env file (Documents/env.txt, the bundle's dm/env.txt; main.m lists
//     them in DM_ENV_FILE_KEYS) is shown but kept - the row is disabled and the note says so;
//   * only a value that differs from the game's default is saved, so a setting the player left
//     alone follows the defaults of a later build;
//   * "Reset to tested defaults" forgets every saved choice;
//   * rows are grouped into sections, in the order they first appear.
#import <UIKit/UIKit.h>
#import <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - model

@interface NspbSetting : NSObject
@property (copy) NSString *env, *kind, *label, *note, *def, *section;
@property (copy) NSArray<NSArray<NSString *> *> *options;   // choice: [value, label]
@property (copy) NSString *on, *off;                        // toggle values, resolved
@property double min, max, step;
@property BOOL hasMin, hasMax, hasStep;
@end

@implementation NspbSetting
- (NSString *)sectionTitle { return self.section.length ? self.section : @"Game"; }
- (NSString *)onValue { return self.on.length ? self.on : @"1"; }
- (NSString *)offValue { return self.off.length ? self.off : @"0"; }

// A range compares as numbers (a slider writes "1.00" for 1.0), as Setting.isDefault does.
- (BOOL)isDefault:(NSString *)v {
    if ([self.kind isEqualToString:@"range"]) {
        double a = v.doubleValue, b = self.def.doubleValue;
        return fabs(a - b) < 1e-6;
    }
    return [v isEqualToString:self.def] ? YES : NO;
}

// A saved value is only offered back when the game still lists it.
- (BOOL)accepts:(NSString *)v {
    if ([self.kind isEqualToString:@"choice"]) {
        for (NSArray<NSString *> *o in self.options)
            if ([o[0] isEqualToString:v]) return YES;
        return NO;
    }
    if ([self.kind isEqualToString:@"range"]) {
        if (!self.hasMin || !self.hasMax) return NO;
        double n = v.doubleValue;
        return isfinite(n) && n >= self.min && n <= self.max;
    }
    if ([self.kind isEqualToString:@"toggle"])
        return [v isEqualToString:self.onValue] || [v isEqualToString:self.offValue];
    return YES;
}
@end

static NSString *nspb_str(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

static NSArray<NspbSetting *> *nspb_load_settings(NSData *data) {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"settings"] isKindOfClass:NSArray.class])
        return nil;
    NSMutableArray<NspbSetting *> *out = [NSMutableArray array];
    for (NSDictionary *d in root[@"settings"]) {
        if (![d isKindOfClass:NSDictionary.class]) return nil;
        NspbSetting *s = [NspbSetting new];
        s.env = nspb_str(d, @"env");
        s.kind = nspb_str(d, @"kind");
        s.label = nspb_str(d, @"label");
        s.note = nspb_str(d, @"note");
        s.def = nspb_str(d, @"default");
        s.section = nspb_str(d, @"section");
        s.on = nspb_str(d, @"on");
        s.off = nspb_str(d, @"off");
        // env, kind, label, note and default are all required by the Swift Decodable
        if (!s.env || !s.kind || !s.label || !s.note || !s.def) return nil;
        if ([d[@"options"] isKindOfClass:NSArray.class]) {
            NSMutableArray<NSArray<NSString *> *> *opts = [NSMutableArray array];
            for (id o in d[@"options"]) {
                if (![o isKindOfClass:NSArray.class] || [o count] < 2 ||
                    ![o[0] isKindOfClass:NSString.class] || ![o[1] isKindOfClass:NSString.class])
                    return nil;
                [opts addObject:@[o[0], o[1]]];
            }
            s.options = opts;
        }
        if ([d[@"min"] isKindOfClass:NSNumber.class]) { s.min = [d[@"min"] doubleValue]; s.hasMin = YES; }
        if ([d[@"max"] isKindOfClass:NSNumber.class]) { s.max = [d[@"max"] doubleValue]; s.hasMax = YES; }
        if ([d[@"step"] isKindOfClass:NSNumber.class]) { s.step = [d[@"step"] doubleValue]; s.hasStep = YES; }
        [out addObject:s];
    }
    return out;
}

@interface NspbModel : NSObject
@property (strong) NSArray<NspbSetting *> *settings;
@property (strong) NSArray<NSString *> *sections;
@property (strong) NSSet<NSString *> *fromFile;   // set by an env file: shown, not changed
@property (strong) NSMutableDictionary<NSString *, NSString *> *values;
@property (strong) NSUserDefaults *defaults;
- (instancetype)initWith:(NSArray<NspbSetting *> *)settings;
- (BOOL)changed;
- (void)reset;
- (void)apply;
@end

@implementation NspbModel
- (instancetype)initWith:(NSArray<NspbSetting *> *)settings {
    if (!(self = [super init])) return nil;
    _settings = settings;
    _values = [NSMutableDictionary dictionary];
    _defaults = NSUserDefaults.standardUserDefaults;
    NSString *keys = NSProcessInfo.processInfo.environment[@"DM_ENV_FILE_KEYS"] ?: @"";
    NSMutableSet<NSString *> *ff = [NSMutableSet set];
    for (NSString *k in [keys componentsSeparatedByString:@" "])
        if (k.length) [ff addObject:k];
    _fromFile = ff;
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    for (NspbSetting *s in settings) {
        NSString *v = nil;
        NSString *envv = NSProcessInfo.processInfo.environment[s.env];
        if ([ff containsObject:s.env] && envv) {
            v = envv;
        } else {
            NSString *saved = [_defaults stringForKey:[@"launcher." stringByAppendingString:s.env]];
            v = (saved && [s accepts:saved]) ? saved : s.def;
        }
        _values[s.env] = v;
        if (![sections containsObject:s.sectionTitle]) [sections addObject:s.sectionTitle];
    }
    _sections = sections;
    return self;
}

- (NSString *)value:(NspbSetting *)s { return self.values[s.env] ?: s.def; }
- (BOOL)locked:(NspbSetting *)s { return [self.fromFile containsObject:s.env]; }

- (NSString *)noteFor:(NspbSetting *)s {
    if (![self locked:s]) return s.note;
    NSString *suffix = @"Set by an env file";
    return s.note.length ? [NSString stringWithFormat:@"%@ · %@", s.note, suffix] : suffix;
}

- (BOOL)changed {
    for (NspbSetting *s in self.settings) {
        if ([self.fromFile containsObject:s.env]) continue;
        if (![s isDefault:[self value:s]]) return YES;
    }
    return NO;
}

- (void)reset {
    for (NspbSetting *s in self.settings) {
        [self.defaults removeObjectForKey:[@"launcher." stringByAppendingString:s.env]];
        if (![self.fromFile containsObject:s.env]) self.values[s.env] = s.def;
    }
    fprintf(stderr, "launcher: settings reset to the game's defaults\n");
}

- (void)apply {
    for (NspbSetting *s in self.settings) {
        NSString *v = [self value:s];
        if ([self.fromFile containsObject:s.env]) {
            fprintf(stderr, "launcher: %s kept at %s (env file)\n", s.env.UTF8String, v.UTF8String);
            continue;
        }
        NSString *key = [@"launcher." stringByAppendingString:s.env];
        if ([s isDefault:v]) [self.defaults removeObjectForKey:key];
        else [self.defaults setObject:v forKey:key];
        setenv(s.env.UTF8String, v.UTF8String, 1);
        fprintf(stderr, "launcher: %s=%s%s\n", s.env.UTF8String, v.UTF8String,
                [s isDefault:v] ? "" : " (changed)");
    }
}
@end

#pragma mark - views

static UILabel *nspb_body(NSString *text) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

static UILabel *nspb_value(NSString *text) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.textColor = UIColor.secondaryLabelColor;
    l.font = [UIFont monospacedDigitSystemFontOfSize:
              [UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                   weight:UIFontWeightRegular];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

// A settings row: label (+ its note) on the left, the control on the right.
@interface NspbRowCell : UITableViewCell
@end

@implementation NspbRowCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse {
    return [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}
@end

@interface NspbSettingsVC : UITableViewController
@property (strong) NspbModel *m;
@property (copy) void (^onReset)(void);
@property (strong) NSTimer *timer;
@property (strong) UILabel *memory;
@end

@implementation NspbSettingsVC

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)self.m.sections.count + 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    if (sec < (NSInteger)self.m.sections.count) {
        return (NSInteger)[self rowsInSection:sec].count;
    }
    return 1;   // reset row, then the memory row
}

- (NSArray<NspbSetting *> *)rowsInSection:(NSInteger)sec {
    NSString *title = self.m.sections[(NSUInteger)sec];
    NSMutableArray<NspbSetting *> *rows = [NSMutableArray array];
    for (NspbSetting *s in self.m.settings)
        if ([s.sectionTitle isEqualToString:title]) [rows addObject:s];
    return rows;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec {
    if (sec < (NSInteger)self.m.sections.count) return self.m.sections[(NSUInteger)sec];
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)sec {
    if (sec < (NSInteger)self.m.sections.count) {
        NSArray<NspbSetting *> *rows = [self rowsInSection:sec];
        NSMutableArray<NSString *> *notes = [NSMutableArray array];
        for (NspbSetting *s in rows) {
            NSString *n = [self.m noteFor:s];
            if (n.length) [notes addObject:n];
        }
        return notes.count ? [notes componentsJoinedByString:@"\n"] : nil;
    }
    if (sec == (NSInteger)self.m.sections.count)
        return @"Brings back all settings this game was tested with.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                               reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    UIView *v = c.contentView;
    UILayoutGuide *g = v.layoutMarginsGuide;

    if (ip.section >= (NSInteger)self.m.sections.count) {
        if (ip.section == (NSInteger)self.m.sections.count) {   // Reset to tested defaults
            c.textLabel.text = @"Reset to tested defaults";
            c.textLabel.textColor = UIColor.linkColor;
            c.textLabel.enabled = [self.m changed];
            c.selectionStyle = [self.m changed] ? UITableViewCellSelectionStyleDefault
                                                : UITableViewCellSelectionStyleNone;
            return c;
        }
        UILabel *l = nspb_body(@"Memory available");   // the same live figure as Launcher.swift
        self.memory = nspb_value([NSByteCountFormatter
                                  stringFromByteCount:(long long)os_proc_available_memory()
                                  countStyle:NSByteCountFormatterCountStyleMemory]);
        [v addSubview:l]; [v addSubview:self.memory];
        [NSLayoutConstraint activateConstraints:@[
            [l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [self.memory.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [self.memory.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [v.heightAnchor constraintGreaterThanOrEqualToConstant:52]]];
        return c;
    }

    NspbSetting *s = [self rowsInSection:ip.section][(NSUInteger)ip.row];
    BOOL locked = [self.m locked:s];
    UILabel *l = nspb_body(s.label);
    [v addSubview:l];
    NSMutableArray<NSLayoutConstraint *> *cs = [@[
        [l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [v.heightAnchor constraintGreaterThanOrEqualToConstant:52]] mutableCopy];

    if ([s.kind isEqualToString:@"choice"]) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        NSString *cur = [self.m value:s];
        NSString *label = cur;
        for (NSArray<NSString *> *o in s.options)
            if ([o[0] isEqualToString:cur]) { label = o[1]; break; }
        cfg.title = label;
        cfg.baseForegroundColor = UIColor.secondaryLabelColor;
        cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"
                            withConfiguration:[UIImageSymbolConfiguration
                                                 configurationWithPointSize:12
                                                 weight:UIImageSymbolWeightSemibold]];
        cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
        cfg.imagePadding = 5;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 0);
        cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
            NSMutableDictionary *m = [a mutableCopy];
            m[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            return m;
        };
        UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
        b.showsMenuAsPrimaryAction = YES;
        b.changesSelectionAsPrimaryAction = NO;
        b.enabled = !locked;
        if (!locked) b.menu = [self menuFor:s button:b];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [v addSubview:b];
        [cs addObjectsFromArray:@[
            [b.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [b.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [b.leadingAnchor constraintGreaterThanOrEqualToAnchor:l.trailingAnchor constant:12]]];
    } else if ([s.kind isEqualToString:@"range"]) {
        UISlider *sl = [UISlider new];
        sl.translatesAutoresizingMaskIntoConstraints = NO;
        sl.minimumValue = s.hasMin ? s.min : 0;
        sl.maximumValue = s.hasMax ? s.max : 1;
        sl.value = [self.m value:s].doubleValue;
        sl.enabled = !locked;
        sl.accessibilityLabel = s.label;
        sl.tag = ip.section * 1000 + ip.row;
        [sl addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
        UILabel *pct = nspb_value([self percentage:s]);
        pct.tag = sl.tag;
        [v addSubview:sl]; [v addSubview:pct];
        [cs addObjectsFromArray:@[
            [sl.leadingAnchor constraintEqualToAnchor:l.trailingAnchor constant:12],
            [sl.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [pct.leadingAnchor constraintEqualToAnchor:sl.trailingAnchor constant:12],
            [pct.widthAnchor constraintEqualToConstant:56],
            [pct.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [pct.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [sl.widthAnchor constraintGreaterThanOrEqualToConstant:120]]];
    } else {
        UISwitch *sw = [UISwitch new];
        sw.on = [[self.m value:s] isEqualToString:[s onValue]];
        sw.enabled = !locked;
        sw.tag = ip.section * 1000 + ip.row;
        sw.translatesAutoresizingMaskIntoConstraints = NO;
        [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        [v addSubview:sw];
        [cs addObjectsFromArray:@[
            [sw.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [sw.centerYAnchor constraintEqualToAnchor:v.centerYAnchor]]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    if (locked) l.textColor = UIColor.tertiaryLabelColor;
    return c;
}

- (NspbSetting *)settingAt:(NSInteger)tag {
    NSInteger sec = tag / 1000, row = tag % 1000;
    if (sec < 0 || sec >= (NSInteger)self.m.sections.count) return nil;
    NSArray<NspbSetting *> *rows = [self rowsInSection:sec];
    if (row < 0 || row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)row];
}

- (NSString *)percentage:(NspbSetting *)s {
    return [NSString stringWithFormat:@"%ld %%", (long)lround([self.m value:s].doubleValue * 100)];
}

- (UIMenu *)menuFor:(NspbSetting *)s button:(UIButton *)b {
    NSMutableArray<UIAction *> *items = [NSMutableArray array];
    NSString *cur = [self.m value:s];
    __weak NspbSettingsVC *w = self;
    __weak UIButton *wb = b;
    for (NSArray<NSString *> *o in s.options) {
        UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil
                                        handler:^(UIAction *__unused act) {
            NspbSettingsVC *me = w;
            if (!me) return;
            me.m.values[s.env] = o[0];
            UIButtonConfiguration *cfg = wb.configuration;
            cfg.title = o[1];
            wb.configuration = cfg;
            wb.menu = [me menuFor:s button:wb];
            // the reset row becomes enabled as soon as something differs from the default
            [me.tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)me.m.sections.count]
                        withRowAnimation:UITableViewRowAnimationNone];
        }];
        a.state = [o[0] isEqualToString:cur] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil
                         options:UIMenuOptionsSingleSelection
                        children:items];
}

- (void)slid:(UISlider *)sl {
    NspbSetting *s = [self settingAt:sl.tag];
    if (!s) return;
    double step = s.hasStep ? s.step : 0.05, lo = s.hasMin ? s.min : 0;
    double v = step > 0 ? lo + round((sl.value - lo) / step) * step : sl.value;   // SwiftUI snaps the same way
    self.m.values[s.env] = [NSString stringWithFormat:@"%.2f", v];
    UILabel *pct = [sl.superview viewWithTag:sl.tag];
    pct.text = [self percentage:s];
    sl.accessibilityValue = pct.text;
    sl.value = (float)v;
}

- (void)toggled:(UISwitch *)sw {
    NspbSetting *s = [self settingAt:sw.tag];
    if (!s) return;
    self.m.values[s.env] = sw.on ? [s onValue] : [s offValue];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != (NSInteger)self.m.sections.count) return;
    if (![self.m changed]) return;
    [self.m reset];
    [tv reloadData];
    if (self.onReset) self.onReset();
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    __weak NspbSettingsVC *w = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *__unused timer) {
        NspbSettingsVC *me = w;
        if (!me) return;
        me.memory.text = [NSByteCountFormatter
                          stringFromByteCount:(long long)os_proc_available_memory()
                          countStyle:NSByteCountFormatterCountStyleMemory];
    }];
}

- (void)dealloc { [self.timer invalidate]; }
@end

// The screen: the game card on the left third, the settings list on the right two thirds -
// the geometry of Launcher.swift's HStack.
@interface NspbLauncherVC : UIViewController
@property (strong) NspbModel *m;
@property (copy) void (^play)(void);
@end

@implementation NspbLauncherVC

static id nspb_info(NSString *k) { return [NSBundle.mainBundle objectForInfoDictionaryKey:k]; }

static UIImage *nspb_app_icon(void) {
    UIImage *i = [UIImage imageNamed:@"AppIcon"];
    if (i) return i;
    NSDictionary *icons = nspb_info(@"CFBundleIcons");
    NSArray *files = [icons isKindOfClass:NSDictionary.class]
        ? icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] : nil;
    for (NSString *f in [files reverseObjectEnumerator]) {
        UIImage *im = [f isKindOfClass:NSString.class] ? [UIImage imageNamed:f] : nil;
        if (im) return im;
    }
    return [UIImage imageNamed:@"AppIcon60x60"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.blackColor;

    // ---- left: icon, name, version, Play
    UIStackView *card = [UIStackView new];
    card.axis = UILayoutConstraintAxisVertical;
    card.alignment = UIStackViewAlignmentCenter;
    card.spacing = 16;
    UIImage *icon = nspb_app_icon();
    if (icon) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
        iv.layer.cornerRadius = 22;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.clipsToBounds = YES;
        iv.isAccessibilityElement = NO;
        [iv.widthAnchor constraintEqualToConstant:96].active = YES;
        [iv.heightAnchor constraintEqualToConstant:96].active = YES;
        [card addArrangedSubview:iv];
    }
    UILabel *name = [UILabel new];
    id disp = nspb_info(@"CFBundleDisplayName");
    name.text = [disp isKindOfClass:NSString.class] ? disp : @"Game";
    name.numberOfLines = 0;
    name.textAlignment = NSTextAlignmentCenter;
    UIFontDescriptor *fd = [[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1].fontDescriptor
                            fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    name.font = [UIFont fontWithDescriptor:fd size:0];
    [card addArrangedSubview:name];
    UILabel *ver = [UILabel new];
    id verstr = nspb_info(@"CFBundleShortVersionString");
    ver.text = [NSString stringWithFormat:@"Version %@",
                [verstr isKindOfClass:NSString.class] ? verstr : @""];
    ver.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
    ver.textColor = UIColor.secondaryLabelColor;
    [card addArrangedSubview:ver];

    // iOS 26's .glassProminent, selected the way Launcher.swift does it (the API is newer than
    // the deployment target some builds use), else the filled style.
    UIButtonConfiguration *cfg = nil;
    SEL glass = NSSelectorFromString(@"prominentGlassButtonConfiguration");
    if ([UIButtonConfiguration respondsToSelector:glass]) {
        cfg = ((UIButtonConfiguration *(*)(id, SEL))
               [UIButtonConfiguration methodForSelector:glass])(UIButtonConfiguration.class, glass);
    }
    if (!cfg) cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.buttonSize = UIButtonConfigurationSizeLarge;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIFontDescriptor *pd = [[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3].fontDescriptor
                            fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    cfg.attributedTitle = [[NSAttributedString alloc]
                           initWithString:@"Play"
                               attributes:@{NSFontAttributeName:
                                                [UIFont fontWithDescriptor:pd size:0]}];
    __weak NspbLauncherVC *w = self;
    UIButton *play = [UIButton buttonWithConfiguration:cfg
                                          primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        NspbLauncherVC *me = w;
        if (me.play) me.play();
    }]];
    [play.widthAnchor constraintEqualToConstant:220].active = YES;
    [card addArrangedSubview:play];
    [card setCustomSpacing:20 afterView:ver];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    // ---- right: the settings
    NspbSettingsVC *list = [[NspbSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    list.m = self.m;
    list.onReset = ^{
        fprintf(stderr, "launcher: reset tapped\n");
    };
    [self addChildViewController:list];
    list.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:list.view];
    [list didMoveToParentViewController:self];

    UIView *v = self.view;
    // two side-by-side halves, as Launcher.swift's HStack: the list takes the right two thirds
    // and the card centres inside the left third
    UILayoutGuide *left = [UILayoutGuide new];
    [v addLayoutGuide:left];
    [NSLayoutConstraint activateConstraints:@[
        [list.view.topAnchor constraintEqualToAnchor:v.topAnchor],
        [list.view.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
        [list.view.trailingAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.trailingAnchor],
        [list.view.widthAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.widthAnchor
                                             multiplier:2.0 / 3.0],
        [left.leadingAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.leadingAnchor],
        [left.trailingAnchor constraintEqualToAnchor:list.view.leadingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:left.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:left.widthAnchor constant:-32]]];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

#pragma mark - in-game menu (GameMenu.swift port)

extern int dm_pad_layout(void);
extern bool dm_pad_layout_offered(int layout);
extern void dm_pad_layout_set(int layout);
extern bool dm_setting_live(const char *env, const char *value);
extern void *dm_quit_menu(void);

static NspbModel *g_game_menu_model;

static UIMenuElement *nspb_game_menu_row(NspbModel *m, NspbSetting *s) {
    NSString *now = [m value:s];
    BOOL fixed = [m locked:s];
    UIMenuElementAttributes attrs = fixed ? UIMenuElementAttributesDisabled : 0;
    void (^pick)(NSString *) = ^(NSString *v) {
        if (fixed || ![s accepts:v]) return;
        m.values[s.env] = v;
        NSString *key = [@"launcher." stringByAppendingString:s.env];
        if ([s isDefault:v]) [m.defaults removeObjectForKey:key];
        else [m.defaults setObject:v forKey:key];
        setenv(s.env.UTF8String, v.UTF8String, 1);
        fprintf(stderr, "launcher: %s=%s (in-game menu)\n", s.env.UTF8String, v.UTF8String);
        dm_setting_live(s.env.UTF8String, v.UTF8String);
    };
    if ([s.kind isEqualToString:@"toggle"]) {
        NSString *next = [now isEqualToString:s.onValue] ? s.offValue : s.onValue;
        UIAction *a = [UIAction actionWithTitle:s.label image:nil identifier:nil handler:^(__kindof UIAction *__unused act) {
            pick(next);
        }];
        a.attributes = attrs;
        a.state = [now isEqualToString:s.onValue] ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (fixed) a.subtitle = @"Set in env.txt";
        return a;
    }
    NSArray<NSArray<NSString *> *> *options = s.options ?: @[];
    NSString *current = now;
    NSMutableArray<UIAction *> *actions = [NSMutableArray arrayWithCapacity:options.count];
    for (NSArray<NSString *> *o in options) {
        if ([o[0] isEqualToString:now]) current = o[1];
        NSString *val = o[0];
        UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil handler:^(__kindof UIAction *__unused act) {
            pick(val);
        }];
        a.attributes = attrs;
        a.state = [val isEqualToString:now] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    UIMenu *sub = [UIMenu menuWithTitle:s.label image:nil identifier:nil options:UIMenuOptionsSingleSelection children:actions];
    if (fixed && [sub respondsToSelector:@selector(setSubtitle:)]) {
        sub.subtitle = [NSString stringWithFormat:@"%@, set in env.txt", current];
    }
    return sub;
}

static NSArray<UIMenuElement *> *nspb_game_menu_items(void) {
    NSArray<NSString *> *names = @[@"2D", @"3D", @"Tap"];
    NSMutableArray<UIAction *> *layouts = [NSMutableArray array];
    for (int l = 0; l < 3; l++) {
        if (!dm_pad_layout_offered(l)) continue;
        UIAction *a = [UIAction actionWithTitle:names[l] image:nil identifier:nil handler:^(__kindof UIAction *__unused act) {
            dm_pad_layout_set(l);
        }];
        a.state = (dm_pad_layout() == l) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layouts addObject:a];
    }
    UIMenu *layout = [UIMenu menuWithTitle:@"Controller layout" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:layouts];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    BOOL placed = NO;
    NspbModel *m = g_game_menu_model;
    if (m) {
        for (NSString *section in m.sections) {
            NSMutableArray<UIMenuElement *> *rows = [NSMutableArray array];
            if ([section isEqualToString:@"Controls"]) {
                [rows addObject:layout];
                placed = YES;
            }
            for (NspbSetting *s in m.settings) {
                if (![s.sectionTitle isEqualToString:section]) continue;
                if (([s.kind isEqualToString:@"choice"] || [s.kind isEqualToString:@"toggle"]) &&
                    dm_setting_live(s.env.UTF8String, NULL)) {
                    [rows addObject:nspb_game_menu_row(m, s)];
                }
            }
            if (rows.count) {
                [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:rows]];
            }
        }
    }
    if (!placed) {
        [items insertObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[layout]] atIndex:0];
    }
    void *quit = dm_quit_menu();
    if (quit) {
        UIMenu *qm = CFBridgingRelease(quit);
        if (qm) [items addObject:qm];
    }
    return items;
}

__attribute__((used, visibility("default")))
void *dm_game_menu(void) {
    NSString *title = g_game_menu_model ? @"More settings on the start screen" : @"";
    UIDeferredMenuElement *def = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^done)(NSArray<UIMenuElement *> *)) {
        done(nspb_game_menu_items());
    }];
    UIMenu *menu = [UIMenu menuWithTitle:title children:@[def]];
    return (void *)CFBridgingRetain(menu);
}

#ifndef DM_SHELL_FRAMEWORK
#pragma mark - entry point

// A capture IPA (the run-time shader capture done on the device instead of a Mac) sets
// DM_GLSLC_CAPTURE / DM_VK_CAPTURE / DM_GL_CAPTURE in its dm/env.txt to a folder relative to
// Documents, which is the working directory at that point. The Vulkan and GL captures write
// into the folder without creating it, so it is made here, before the game starts.
static void nspb_make_capture_folders(void) {
    static const char *const keys[] = {"DM_GLSLC_CAPTURE", "DM_VK_CAPTURE", "DM_GL_CAPTURE"};
    for (int i = 0; i < 3; i++) {
        const char *k = keys[i], *d = getenv(k);
        if (d && *d) {
            [NSFileManager.defaultManager createDirectoryAtPath:@(d)
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
            fprintf(stderr, "capture: %s → Documents/%s\n", k, d);
        }
    }
}

bool dm_show_launcher(void *view_controller, void (*done)(void)) {
    nspb_make_capture_folders();
    const char *off = getenv("DM_LAUNCHER");
    if (off && !strcmp(off, "0")) {
        fprintf(stderr, "launcher: off (DM_LAUNCHER=0)\n");
        return false;
    }
    NSString *path = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"]
                      stringByAppendingPathComponent:@"launcher.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return false;
    NSArray<NspbSetting *> *settings = nspb_load_settings(data);
    if (!settings.count) {
        fprintf(stderr, "[RED] launcher: dm/launcher.json cannot be read; starting the game\n");
        return false;
    }
    UIViewController *parent = (__bridge UIViewController *)view_controller;
    NspbModel *model = [[NspbModel alloc] initWith:settings];
    g_game_menu_model = model;
    NspbLauncherVC *vc = [NspbLauncherVC new];
    vc.m = model;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak NspbLauncherVC *wvc = vc;
    __block BOOL started = NO;
    vc.play = ^{
        NspbLauncherVC *me = wvc;
        if (started || !me) return;
        started = YES;
        [model apply];
        [me dismissViewControllerAnimated:NO completion:^{ done(); }];
    };
    [parent presentViewController:vc animated:NO completion:nil];
    fprintf(stderr, "launcher: %lu settings shown\n", (unsigned long)settings.count);
    return true;
}
#endif
