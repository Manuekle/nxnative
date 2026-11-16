// The Mac's Pair iPhone… window for NX Pad phones: pad_net_panel_mac.h says what it shows. Main thread only, as the receiver (pad_net_apple.m) it drives.
#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import "pad_net_panel_mac.h"
#include "pad_net_apple.h"
// ---- Controllers > Pair iPhone… (pad_net_apple.h): the six digits and the QR code an NX Pad phone pairs with this Mac by, once for every game on it; the phones paired, each
// with Forget. Opening it listens for phones (also with Phone controllers off or no phone paired yet); closing it ends the code. It shows over the fullscreen game too ----
@interface DmPairPanel : NSObject <NSWindowDelegate>
- (void)showPanel:(id)sender;
- (void)pairEvent:(int)ev phone:(NSString *)phone;
@end
static DmPairPanel *g_pair_panel;
static DmPairPanel *pair_panel(void) { if (!g_pair_panel) g_pair_panel = [DmPairPanel new]; return g_pair_panel; }
static void pair_changed(int ev, const char *phone) { [g_pair_panel pairEvent:ev phone:phone ? @(phone) : nil]; }

// The QR code of text, black on white, scaled by whole pixels so its modules stay sharp
static NSImage *pair_qr(NSString *text, CGFloat side) {
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *img = f.outputImage; if (!img || img.extent.size.width <= 0) return nil;
    CGFloat k = MAX(1, floor(side * 2 / img.extent.size.width));   // drawn at 2x for a Retina screen
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(k, k)];
    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:img fromRect:img.extent]; if (!cg) return nil;
    NSImage *ns = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(img.extent.size.width / 2, img.extent.size.height / 2)];
    CGImageRelease(cg);
    return ns;
}
static NSTextField *pair_label(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text];
    l.font = font; l.textColor = color ?: NSColor.labelColor; l.alignment = NSTextAlignmentCenter; l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

@implementation DmPairPanel {
    NSPanel *_panel;
    NSImageView *_qr;
    NSTextField *_code, *_hint, *_info, *_status;
    NSStackView *_phones;    // a row per paired phone
    NSString *_qrFor;        // the link the QR code on screen carries
    NSString *_phonesSig;    // what the rows were built from: a change rebuilds them
    NSTimer *_timer;         // 1 s while the panel is open: the countdown and who is connected
}
- (void)makePanel {
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 620)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                          backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Pair an iPhone";
    _panel.releasedWhenClosed = NO;
    _panel.floatingPanel = YES;
    _panel.hidesOnDeactivate = NO;   // the player looks at the phone, maybe clicks elsewhere: the code stays up
    _panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.delegate = self;

    NSView *qrBack = [NSView new];   // white with a quiet zone, also in dark mode: cameras read dark on light
    qrBack.wantsLayer = YES; qrBack.layer.backgroundColor = NSColor.whiteColor.CGColor; qrBack.layer.cornerRadius = 14;
    qrBack.translatesAutoresizingMaskIntoConstraints = NO;
    _qr = [NSImageView new]; _qr.imageScaling = NSImageScaleProportionallyUpOrDown; _qr.translatesAutoresizingMaskIntoConstraints = NO;
    [qrBack addSubview:_qr];
    [NSLayoutConstraint activateConstraints:@[
        [qrBack.widthAnchor constraintEqualToConstant:236], [qrBack.heightAnchor constraintEqualToConstant:236],
        [_qr.leadingAnchor constraintEqualToAnchor:qrBack.leadingAnchor constant:18], [_qr.trailingAnchor constraintEqualToAnchor:qrBack.trailingAnchor constant:-18],
        [_qr.topAnchor constraintEqualToAnchor:qrBack.topAnchor constant:18], [_qr.bottomAnchor constraintEqualToAnchor:qrBack.bottomAnchor constant:-18]]];

    NSTextField *title = pair_label(@"Play with your iPhone as a controller", [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], nil);
    _hint = pair_label(@"Point the iPhone's camera at the code, or open NX Pad, tap Pair a Mac and type the numbers.", [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor);
    _code = pair_label(@"", [NSFont monospacedDigitSystemFontOfSize:44 weight:NSFontWeightSemibold], nil);
    _code.selectable = YES;
    _info = pair_label(@"", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
    _status = pair_label(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    NSBox *line = [NSBox new]; line.boxType = NSBoxSeparator; line.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *paired = [NSTextField labelWithString:@"iPhones paired with this Mac"]; paired.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _phones = [NSStackView new]; _phones.orientation = NSUserInterfaceLayoutOrientationVertical; _phones.alignment = NSLayoutAttributeLeading; _phones.spacing = 6;
    _phones.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(done:)]; done.keyEquivalent = @"\r";

    NSStackView *root = [NSStackView stackViewWithViews:@[title, _hint, qrBack, _code, _info, _status, line, paired, _phones, done]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical; root.alignment = NSLayoutAttributeCenterX; root.spacing = 10;
    root.edgeInsets = NSEdgeInsetsMake(20, 24, 18, 24); root.translatesAutoresizingMaskIntoConstraints = NO;
    [root setCustomSpacing:4 afterView:_code]; [root setCustomSpacing:16 afterView:_status]; [root setCustomSpacing:16 afterView:_phones];
    NSView *content = [NSView new]; [content addSubview:root]; _panel.contentView = content;
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:content.topAnchor], [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [content.widthAnchor constraintEqualToConstant:400],
        [title.widthAnchor constraintEqualToConstant:352], [_hint.widthAnchor constraintEqualToConstant:352], [_info.widthAnchor constraintEqualToConstant:352],
        [_status.widthAnchor constraintEqualToConstant:352], [line.widthAnchor constraintEqualToConstant:352], [_phones.widthAnchor constraintEqualToConstant:352],
        [paired.leadingAnchor constraintEqualToAnchor:_phones.leadingAnchor]]];
}
- (void)showPanel:(id)sender {
    (void)sender;
    if (!_panel) { [self makePanel]; [_panel center]; }
    if (!dm_netpad_pair_open(pair_changed)) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Phone controllers could not start";
        a.informativeText = @"No UDP socket could be opened for NX Pad: the game's log says why ([nxpad] lines).";
        [a runModal];
        return;
    }
    [self setStatus:@"Waiting for an iPhone…" color:NSColor.secondaryLabelColor];
    _phonesSig = nil; [self refresh];
    [_panel makeKeyAndOrderFront:nil];
    if (!_timer) _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}
- (void)setStatus:(NSString *)text color:(NSColor *)color { _status.stringValue = text; _status.textColor = color; }
- (void)tick:(NSTimer *)t { (void)t; [self refresh]; }
- (void)refresh {
    dm_netpad_pairing p; dm_netpad_pair_get(&p);
    NSString *url = @(p.url);
    if (![url isEqualToString:_qrFor ?: @""]) { _qrFor = url; _qr.image = url.length ? pair_qr(url, 200) : nil; }
    _code.stringValue = strlen(p.code) == 6 ? [NSString stringWithFormat:@"%.3s %s", p.code, p.code + 3] : @"––– –––";
    _code.textColor = p.code_locked ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    if (p.code_locked) _info.stringValue = @"Too many wrong codes: scan the QR code, or close this window and open it again for a new code.";
    else _info.stringValue = [NSString stringWithFormat:@"%@ · %@ · new code in %d:%02d", @(p.mac), @(p.game), p.seconds_left / 60, p.seconds_left % 60];   // %s would read MacRoman
    dm_netpad_phone ph[16]; int n = dm_netpad_phones(ph, 16);
    NSMutableString *sig = [NSMutableString string];
    for (int i = 0; i < n; i++) [sig appendFormat:@"%llx/%d/%d|", (unsigned long long)ph[i].client, ph[i].connected, ph[i].player];
    if ([sig isEqualToString:_phonesSig ?: @"-"]) return;
    _phonesSig = sig;
    for (NSView *v in _phones.arrangedSubviews.copy) { [_phones removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (!n) { NSTextField *none = [NSTextField labelWithString:@"None yet."]; none.textColor = NSColor.secondaryLabelColor; [_phones addArrangedSubview:none]; }
    NSDateFormatter *df = [NSDateFormatter new]; df.dateStyle = NSDateFormatterMediumStyle; df.timeStyle = NSDateFormatterNoStyle;
    for (int i = 0; i < n; i++) {
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"iphone" accessibilityDescription:nil] ?: [NSImage new]];
        icon.contentTintColor = ph[i].connected ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
        NSTextField *name = [NSTextField labelWithString:@(ph[i].name)]; name.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        NSString *when = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)ph[i].when]];
        NSString *state = !ph[i].connected ? [@"Paired " stringByAppendingString:when]
                        : ph[i].player >= 0 ? [NSString stringWithFormat:@"Playing this game: player %d", ph[i].player + 1] : @"Connected: press a button to join";
        NSTextField *detail = [NSTextField labelWithString:state]; detail.font = [NSFont systemFontOfSize:11]; detail.textColor = NSColor.secondaryLabelColor;
        NSStackView *text = [NSStackView stackViewWithViews:@[name, detail]]; text.orientation = NSUserInterfaceLayoutOrientationVertical; text.alignment = NSLayoutAttributeLeading; text.spacing = 1;
        [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *forget = [NSButton buttonWithTitle:@"Forget" target:self action:@selector(forget:)];
        forget.tag = (NSInteger)ph[i].client; forget.toolTip = @(ph[i].name); forget.controlSize = NSControlSizeSmall;
        NSView *spacer = [NSView new]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *row = [NSStackView stackViewWithViews:@[icon, text, spacer, forget]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.spacing = 8; row.translatesAutoresizingMaskIntoConstraints = NO;
        [_phones addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:_phones.widthAnchor].active = YES;
    }
}
- (void)pairEvent:(int)ev phone:(NSString *)phone {
    if (ev == DM_NETPAD_PAIR_PAIRED)
        [self setStatus:[NSString stringWithFormat:@"✓ %@ is paired. It connects to the games on this Mac by itself from now on.", phone ?: @"The iPhone"] color:NSColor.systemGreenColor];
    else if (ev == DM_NETPAD_PAIR_WRONG)
        [self setStatus:[NSString stringWithFormat:@"%@ tried a wrong code.", phone.length ? phone : @"An iPhone"] color:NSColor.systemOrangeColor];
    _phonesSig = nil;
    [self refresh];
}
- (void)forget:(NSButton *)b {
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Forget %@?", b.toolTip];
    a.informativeText = @"It stops playing the games on this Mac until it is paired again with a new code.";
    [a addButtonWithTitle:@"Forget"]; [a addButtonWithTitle:@"Cancel"];
    a.buttons[0].hasDestructiveAction = YES;
    [a beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        dm_netpad_forget((uint64_t)b.tag); self->_phonesSig = nil; [self refresh];
    }];
}
- (void)done:(id)sender { (void)sender; [_panel performClose:nil]; }
- (void)windowWillClose:(NSNotification *)n {
    (void)n; [_timer invalidate]; _timer = nil;
    dm_netpad_pair_close();
}
@end

NSMenuItem *dm_netpad_pair_menu_item(void) {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"Pair iPhone (NX Pad)…" action:@selector(showPanel:) keyEquivalent:@"p"];
    it.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift; it.target = pair_panel();
    return it;
}
void dm_netpad_panel_show(void) { [pair_panel() showPanel:nil]; }
