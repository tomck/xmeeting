#import "XMAppDelegate.h"

#import "XMH323Client.h"

#import <AVFoundation/AVFoundation.h>

#include <cstdio>

namespace {

NSString *const XMLocalAliasDefaultsKey = @"XMLocalAlias";

typedef NS_ENUM(NSInteger, XMApplicationCallState) {
  XMApplicationCallStateStarting,
  XMApplicationCallStateReady,
  XMApplicationCallStateCalling,
  XMApplicationCallStateIncoming,
  XMApplicationCallStateConnected,
  XMApplicationCallStateError,
};

NSString *trimmedString(NSString *value) {
  return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *displayNameForCall(XMH323Call *call) {
  if (call.remoteName.length > 0) {
    return call.remoteName;
  }
  if (call.remoteNumber.length > 0) {
    return call.remoteNumber;
  }
  if (call.remoteAddress.length > 0) {
    return call.remoteAddress;
  }
  return @"remote endpoint";
}

NSString *callEndStatus(NSString *remote,
                        NSInteger h323Reason,
                        NSUInteger q931Cause,
                        BOOL wasConnected) {
  switch (h323Reason) {
    case 0:  // EndedByLocalUser
      return @"Call ended";
    case 1:  // EndedByNoAccept
      return @"Incoming call was not accepted";
    case 2:  // EndedByAnswerDenied
      return @"Incoming call declined";
    case 3:  // EndedByRemoteUser
    case 6:  // EndedByCallerAbort
      return @"Call ended by the remote endpoint";
    case 4:  // EndedByRefusal
      return [NSString stringWithFormat:@"%@ refused the call", remote];
    case 5:  // EndedByNoAnswer
      return [NSString stringWithFormat:@"No answer from %@", remote];
    case 7:  // EndedByTransportFail
    case 8:  // EndedByConnectFail
      return wasConnected
                 ? @"The H.323 connection was lost"
                 : [NSString stringWithFormat:@"Could not establish an H.323 connection to %@",
                                                     remote];
    case 9:  // EndedByGatekeeper
      return @"The gatekeeper ended the call";
    case 10:  // EndedByNoUser
      return [NSString stringWithFormat:@"The H.323 user at %@ was not found", remote];
    case 11:  // EndedByNoBandwidth
      return @"The call could not obtain enough network bandwidth";
    case 12:  // EndedByCapabilityExchange
      return @"The endpoints could not agree on a compatible audio format";
    case 13:  // EndedByCallForwarded
      return @"The call was forwarded by the remote endpoint";
    case 14:  // EndedBySecurityDenial
      return @"The remote endpoint rejected the call for security reasons";
    case 15:  // EndedByLocalBusy
      return @"Incoming call declined because XMeeting was busy";
    case 16:  // EndedByLocalCongestion
      return @"XMeeting could not accept the incoming call";
    case 17:  // EndedByRemoteBusy
      return [NSString stringWithFormat:@"%@ is busy", remote];
    case 18:  // EndedByRemoteCongestion
      return @"The remote H.323 service is congested";
    case 19:  // EndedByUnreachable
    case 21:  // EndedByHostOffline
      return [NSString stringWithFormat:@"Could not reach %@", remote];
    case 20:  // EndedByNoEndPoint
      return [NSString stringWithFormat:
                           @"No H.323 endpoint is listening at %@ on TCP port 1720", remote];
    case 22:  // EndedByTemporaryFailure
      return @"The remote H.323 service is temporarily unavailable";
    case 23:  // EndedByQ931Cause
      if (q931Cause < 128) {
        return [NSString stringWithFormat:@"The remote endpoint ended the call (Q.931 cause %lu)",
                                          (unsigned long)q931Cause];
      }
      break;
    case 24:  // EndedByDurationLimit
      return @"Call ended after reaching its duration limit";
    case 25:  // EndedByInvalidConferenceID
      return @"The conference address is not valid";
    case 26:  // EndedByOSPRefusal
      return @"The remote H.323 service refused to route the call";
    default:
      break;
  }
  return wasConnected ? @"Call disconnected" : @"The H.323 call could not be completed";
}

BOOL callEndReasonIsFailure(NSInteger h323Reason) {
  switch (h323Reason) {
    case 0:   // EndedByLocalUser
    case 1:   // EndedByNoAccept
    case 2:   // EndedByAnswerDenied
    case 3:   // EndedByRemoteUser
    case 6:   // EndedByCallerAbort
    case 13:  // EndedByCallForwarded
    case 15:  // EndedByLocalBusy
    case 24:  // EndedByDurationLimit
      return NO;
    default:
      return YES;
  }
}

NSImage *bundleImage(NSString *name) {
  NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
  return path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:path];
}

NSTextField *labelWithString(NSString *value) {
  NSTextField *label = [NSTextField labelWithString:value];
  label.translatesAutoresizingMaskIntoConstraints = NO;
  return label;
}

}  // namespace

@interface XMWindowContentView : NSView
@end

@implementation XMWindowContentView

- (BOOL)isOpaque {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  [NSColor.windowBackgroundColor setFill];
  NSRectFill(dirtyRect);
}

@end

@interface XMVideoPlaceholderView : NSView
@property(nonatomic, strong, nullable) NSImage *placeholderImage;
@end

@implementation XMVideoPlaceholderView

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4];
  [background addClip];
  [NSColor.blackColor setFill];
  [background fill];

  [self.placeholderImage drawInRect:self.bounds
                           fromRect:NSZeroRect
                          operation:NSCompositingOperationSourceOver
                           fraction:1
                     respectFlipped:YES
                              hints:nil];

  [NSColor.separatorColor setStroke];
  background.lineWidth = 1;
  [background stroke];
}

@end

@interface XMAppDelegate () <XMH323ClientDelegate, NSTextFieldDelegate>

@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) XMH323Client *client;
@property(nonatomic, strong) NSTextField *aliasField;
@property(nonatomic, strong) NSTextField *addressField;
@property(nonatomic, strong) NSTextField *statusField;
@property(nonatomic, strong) NSImageView *statusImageView;
@property(nonatomic, strong) NSButton *callButton;
@property(nonatomic, strong) NSProgressIndicator *progressIndicator;
@property(nonatomic, copy, nullable) NSString *activeCallToken;
@property(nonatomic) XMApplicationCallState callState;
@property(nonatomic) BOOL microphoneAuthorized;
@property(nonatomic) BOOL microphonePermissionPending;

- (void)placeOrEndCall:(id)sender;
- (void)restartListener:(id)sender;
- (void)prepareMicrophoneAuthorization;
- (void)refreshReadyStatus;
- (nullable NSString *)previewOutputPath;
- (BOOL)writeWindowPreviewToPath:(NSString *)path;

@end

@implementation XMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  if ([NSProcessInfo.processInfo.arguments containsObject:@"--dark-preview"]) {
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  }
  [self buildApplicationMenu];
  [self buildMainWindow];
  [self.window makeFirstResponder:self.addressField];

  NSString *previewOutputPath = [self previewOutputPath];
  if (previewOutputPath != nil) {
    self.callState = XMApplicationCallStateReady;
    self.statusField.stringValue = @"Ready for H.323 calls";
    [self updateInterface];
    self.callButton.enabled = YES;
    [self.window makeKeyAndOrderFront:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self writeWindowPreviewToPath:previewOutputPath]) {
        std::fprintf(stderr, "Could not write XMeeting window preview\n");
      }
      [NSApp terminate:nil];
    });
    return;
  }

  self.client = [[XMH323Client alloc] initWithDelegate:self];
  [self prepareMicrophoneAuthorization];
  [self startListener];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  [self.client stop];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
  (void)sender;
  if (!hasVisibleWindows) {
    [self.window makeKeyAndOrderFront:nil];
  }
  return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  (void)application;
  NSURL *url = urls.firstObject;
  if (url == nil) {
    return;
  }

  NSString *address = url.absoluteString;
  NSRange separator = [address rangeOfString:@":"];
  if (separator.location != NSNotFound) {
    address = [address substringFromIndex:separator.location + 1];
  }
  while ([address hasPrefix:@"//"]) {
    address = [address substringFromIndex:2];
  }
  self.addressField.stringValue = address.stringByRemovingPercentEncoding ?: address;
  [self.window makeKeyAndOrderFront:nil];
  [self placeOrEndCall:nil];
}

- (void)buildApplicationMenu {
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
  NSMenuItem *applicationMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                               action:nil
                                                        keyEquivalent:@""];
  [mainMenu addItem:applicationMenuItem];

  NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"XMeeting"];
  [applicationMenu addItemWithTitle:@"About XMeeting"
                             action:@selector(orderFrontStandardAboutPanel:)
                      keyEquivalent:@""];
  [applicationMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *showWindowItem = [[NSMenuItem alloc] initWithTitle:@"Show XMeeting"
                                                          action:@selector(showMainWindow:)
                                                   keyEquivalent:@"1"];
  showWindowItem.target = self;
  [applicationMenu addItem:showWindowItem];
  [applicationMenu addItem:NSMenuItem.separatorItem];
  [applicationMenu addItemWithTitle:@"Quit XMeeting"
                             action:@selector(terminate:)
                      keyEquivalent:@"q"];
  applicationMenuItem.submenu = applicationMenu;

  NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                        action:nil
                                                 keyEquivalent:@""];
  [mainMenu addItem:editMenuItem];
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [editMenu addItem:NSMenuItem.separatorItem];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editMenuItem.submenu = editMenu;

  NSMenuItem *callMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                        action:nil
                                                 keyEquivalent:@""];
  [mainMenu addItem:callMenuItem];
  NSMenu *callMenu = [[NSMenu alloc] initWithTitle:@"Call"];
  NSMenuItem *placeCallItem = [[NSMenuItem alloc] initWithTitle:@"Call or Hang Up"
                                                         action:@selector(placeOrEndCall:)
                                                  keyEquivalent:@""];
  placeCallItem.target = self;
  [callMenu addItem:placeCallItem];
  callMenuItem.submenu = callMenu;

  NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                          action:nil
                                                   keyEquivalent:@""];
  [mainMenu addItem:windowMenuItem];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize"
                        action:@selector(performMiniaturize:)
                 keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [windowMenu addItem:NSMenuItem.separatorItem];
  [windowMenu addItemWithTitle:@"Bring All to Front"
                        action:@selector(arrangeInFront:)
                 keyEquivalent:@""];
  windowMenuItem.submenu = windowMenu;

  NSApp.mainMenu = mainMenu;
  NSApp.windowsMenu = windowMenu;
}

- (void)buildMainWindow {
  NSRect frame = NSMakeRect(0, 0, 360, 470);
  self.window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.title = @"XMeeting";
  self.window.releasedWhenClosed = NO;
  self.window.tabbingMode = NSWindowTabbingModeDisallowed;
  XMWindowContentView *newContentView =
      [[XMWindowContentView alloc] initWithFrame:self.window.contentView.bounds];
  newContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.window.contentView = newContentView;
  [self.window center];

  NSView *contentView = self.window.contentView;

  NSTextField *aliasLabel = labelWithString(@"Local alias");
  aliasLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];

  self.aliasField = [NSTextField textFieldWithString:[self savedAlias]];
  self.aliasField.translatesAutoresizingMaskIntoConstraints = NO;
  self.aliasField.delegate = self;
  self.aliasField.toolTip = @"The H.323 alias advertised to other endpoints";
  self.aliasField.accessibilityLabel = @"Local H.323 alias";

  XMVideoPlaceholderView *videoBox = [[XMVideoPlaceholderView alloc] initWithFrame:NSZeroRect];
  videoBox.translatesAutoresizingMaskIntoConstraints = NO;
  videoBox.placeholderImage = bundleImage(@"no_video_screen");
  videoBox.accessibilityLabel = @"Video preview unavailable";

  self.statusImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
  self.statusImageView.translatesAutoresizingMaskIntoConstraints = NO;
  self.statusImageView.imageScaling = NSImageScaleProportionallyDown;

  self.statusField = labelWithString(@"Starting H.323…");
  self.statusField.lineBreakMode = NSLineBreakByTruncatingTail;
  self.statusField.accessibilityLabel = @"Call status";

  self.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
  self.progressIndicator.translatesAutoresizingMaskIntoConstraints = NO;
  self.progressIndicator.style = NSProgressIndicatorStyleSpinning;
  self.progressIndicator.controlSize = NSControlSizeSmall;
  self.progressIndicator.displayedWhenStopped = NO;

  NSStackView *statusStack = [NSStackView stackViewWithViews:@[
    self.statusImageView, self.statusField, self.progressIndicator
  ]];
  statusStack.translatesAutoresizingMaskIntoConstraints = NO;
  statusStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  statusStack.alignment = NSLayoutAttributeCenterY;
  statusStack.spacing = 8;

  self.addressField = [NSTextField textFieldWithString:@""];
  self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
  self.addressField.placeholderString = @"H.323 address or alias@host";
  self.addressField.target = self;
  self.addressField.action = @selector(placeOrEndCall:);
  self.addressField.accessibilityLabel = @"Remote H.323 address";

  self.callButton = [NSButton buttonWithTitle:@"Call"
                                      target:self
                                      action:@selector(placeOrEndCall:)];
  self.callButton.translatesAutoresizingMaskIntoConstraints = NO;
  self.callButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.callButton.image = bundleImage(@"Call_24");
  self.callButton.imagePosition = NSImageLeading;
  self.callButton.keyEquivalent = @"\r";
  self.callButton.toolTip = @"Place an H.323 call";
  self.callButton.accessibilityLabel = @"Call";

  NSStackView *callStack = [NSStackView stackViewWithViews:@[self.addressField, self.callButton]];
  callStack.translatesAutoresizingMaskIntoConstraints = NO;
  callStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  callStack.alignment = NSLayoutAttributeCenterY;
  callStack.spacing = 8;

  for (NSView *view in @[aliasLabel, self.aliasField, videoBox, statusStack, callStack]) {
    [contentView addSubview:view];
  }

  [NSLayoutConstraint activateConstraints:@[
    [aliasLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:16],
    [aliasLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:18],
    [self.aliasField.centerYAnchor constraintEqualToAnchor:aliasLabel.centerYAnchor],
    [self.aliasField.leadingAnchor constraintEqualToAnchor:aliasLabel.trailingAnchor constant:10],
    [self.aliasField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-18],

    [videoBox.topAnchor constraintEqualToAnchor:self.aliasField.bottomAnchor constant:14],
    [videoBox.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:18],
    [videoBox.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-18],
    [videoBox.heightAnchor constraintEqualToAnchor:videoBox.widthAnchor multiplier:0.75],

    [statusStack.topAnchor constraintEqualToAnchor:videoBox.bottomAnchor constant:14],
    [statusStack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [statusStack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
    [self.statusImageView.widthAnchor constraintEqualToConstant:14],
    [self.statusImageView.heightAnchor constraintEqualToConstant:14],
    [self.progressIndicator.widthAnchor constraintEqualToConstant:16],
    [self.progressIndicator.heightAnchor constraintEqualToConstant:16],

    [callStack.topAnchor constraintEqualToAnchor:statusStack.bottomAnchor constant:14],
    [callStack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:18],
    [callStack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-18],
    [callStack.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-18],
    [self.callButton.widthAnchor constraintGreaterThanOrEqualToConstant:92],
  ]];

  self.callState = XMApplicationCallStateStarting;
  [self updateInterface];
}

- (nullable NSString *)previewOutputPath {
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  NSUInteger index = [arguments indexOfObject:@"--render-preview"];
  if (index == NSNotFound || index + 1 >= arguments.count) {
    return nil;
  }
  return arguments[index + 1];
}

- (BOOL)writeWindowPreviewToPath:(NSString *)path {
  NSView *view = self.window.contentView;
  [view layoutSubtreeIfNeeded];
  NSBitmapImageRep *representation = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
  if (representation == nil) {
    return NO;
  }
  [view cacheDisplayInRect:view.bounds toBitmapImageRep:representation];
  NSData *data = [representation representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  BOOL wroteData = [data writeToFile:path atomically:YES];
  if (wroteData) {
    std::printf("Wrote XMeeting window preview to %s\n", path.fileSystemRepresentation);
  }
  return wroteData;
}

- (NSString *)savedAlias {
  NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:XMLocalAliasDefaultsKey];
  if (saved.length > 0) {
    return saved;
  }
  NSString *fullName = trimmedString(NSFullUserName());
  return fullName.length > 0 ? fullName : @"XMeeting";
}

- (void)startListener {
  NSString *alias = trimmedString(self.aliasField.stringValue);
  if (alias.length == 0) {
    alias = @"XMeeting";
    self.aliasField.stringValue = alias;
  }
  [NSUserDefaults.standardUserDefaults setObject:alias forKey:XMLocalAliasDefaultsKey];

  NSError *error = nil;
  if (![self.client startWithUserName:alias listenPort:1720 error:&error]) {
    self.callState = XMApplicationCallStateError;
    self.statusField.stringValue = error.localizedDescription ?: @"Could not start H.323";
  } else {
    [self refreshReadyStatus];
  }
  [self updateInterface];
}

- (void)prepareMicrophoneAuthorization {
  AVAuthorizationStatus status =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
  self.microphoneAuthorized = status == AVAuthorizationStatusAuthorized;
  self.microphonePermissionPending = status == AVAuthorizationStatusNotDetermined;

  if (status == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.microphonePermissionPending = NO;
        self.microphoneAuthorized = granted;
        [self refreshReadyStatus];
        [self updateInterface];
      });
    }];
  }
}

- (void)refreshReadyStatus {
  if (!self.client.isStarted) {
    return;
  }
  if (!self.client.isAudioAvailable) {
    self.callState = XMApplicationCallStateError;
    self.statusField.stringValue = @"No microphone or audio output device is available";
  } else if (self.microphonePermissionPending) {
    self.callState = XMApplicationCallStateStarting;
    self.statusField.stringValue = @"Waiting for microphone access…";
  } else if (!self.microphoneAuthorized) {
    self.callState = XMApplicationCallStateError;
    self.statusField.stringValue = @"Microphone access is required for calls";
  } else {
    self.callState = XMApplicationCallStateReady;
    self.statusField.stringValue = @"Ready for H.323 audio calls";
  }
}

- (void)restartListener:(id)sender {
  (void)sender;
  if (self.activeCallToken.length > 0) {
    NSBeep();
    return;
  }
  [self.client stop];
  [self startListener];
}

- (void)showMainWindow:(id)sender {
  (void)sender;
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)placeOrEndCall:(id)sender {
  (void)sender;
  if (self.activeCallToken.length > 0) {
    NSError *error = nil;
    if (![self.client hangUpCallWithToken:self.activeCallToken error:&error]) {
      [self presentError:error];
    }
    return;
  }

  NSString *address = trimmedString(self.addressField.stringValue);
  if (!self.client.isAudioAvailable || !self.microphoneAuthorized) {
    NSBeep();
    [self refreshReadyStatus];
    [self updateInterface];
    return;
  }
  if (address.length == 0) {
    NSBeep();
    [self.window makeFirstResponder:self.addressField];
    return;
  }

  NSError *error = nil;
  NSString *token = nil;
  if (![self.client callAddress:address token:&token error:&error]) {
    [self presentError:error];
    return;
  }

  self.activeCallToken = token;
  self.callState = XMApplicationCallStateCalling;
  self.statusField.stringValue = [NSString stringWithFormat:@"Calling %@…", address];
  [self updateInterface];
}

- (void)presentError:(NSError *)error {
  self.callState = XMApplicationCallStateError;
  self.statusField.stringValue = error.localizedDescription ?: @"The H.323 operation failed";
  [self updateInterface];
}

- (void)updateInterface {
  BOOL busy = self.callState == XMApplicationCallStateStarting ||
              self.callState == XMApplicationCallStateCalling ||
              self.callState == XMApplicationCallStateIncoming;
  BOOL hasCall = self.activeCallToken.length > 0;

  if (busy) {
    [self.progressIndicator startAnimation:nil];
  } else {
    [self.progressIndicator stopAnimation:nil];
  }

  NSString *statusImageName = @"status_green";
  if (self.callState == XMApplicationCallStateStarting ||
      self.callState == XMApplicationCallStateCalling ||
      self.callState == XMApplicationCallStateIncoming) {
    statusImageName = @"status_yellow";
  } else if (self.callState == XMApplicationCallStateError) {
    statusImageName = @"status_red";
  }
  self.statusImageView.image = bundleImage(statusImageName);

  self.aliasField.enabled = !hasCall;
  self.addressField.enabled = !hasCall;
  self.callButton.title = hasCall ? @"Hang Up" : @"Call";
  self.callButton.image = bundleImage(hasCall ? @"hangup_24" : @"Call_24");
  self.callButton.toolTip = hasCall ? @"End the active H.323 call" : @"Place an H.323 call";
  self.callButton.accessibilityLabel = hasCall ? @"Hang up" : @"Call";
  BOOL canStartCall = self.client.isStarted && self.client.isAudioAvailable &&
                      self.microphoneAuthorized && !self.microphonePermissionPending;
  self.callButton.enabled = canStartCall || hasCall;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  if (notification.object == self.aliasField) {
    [self restartListener:self.aliasField];
  }
}

#pragma mark - XMH323ClientDelegate

- (void)h323Client:(XMH323Client *)client didReceiveIncomingCall:(XMH323Call *)call {
  if (!client.isAudioAvailable || !self.microphoneAuthorized) {
    NSError *error = nil;
    [client rejectCallWithToken:call.token error:&error];
    self.activeCallToken = nil;
    [self refreshReadyStatus];
    [self updateInterface];
    return;
  }
  self.activeCallToken = call.token;
  self.callState = XMApplicationCallStateIncoming;
  self.statusField.stringValue = [NSString stringWithFormat:@"Incoming call from %@", displayNameForCall(call)];
  [self updateInterface];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Incoming H.323 Call";
  alert.informativeText = [NSString stringWithFormat:@"%@ is calling.", displayNameForCall(call)];
  [alert addButtonWithTitle:@"Accept"];
  [alert addButtonWithTitle:@"Reject"];
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    NSError *error = nil;
    if (response == NSAlertFirstButtonReturn) {
      if (![self.client answerCallWithToken:call.token error:&error]) {
        [self presentError:error];
      } else {
        self.statusField.stringValue = [NSString stringWithFormat:@"Answering %@…", displayNameForCall(call)];
      }
    } else if (![self.client rejectCallWithToken:call.token error:&error]) {
      [self presentError:error];
    }
  }];
}

- (void)h323Client:(XMH323Client *)client didEstablishCall:(XMH323Call *)call {
  (void)client;
  self.activeCallToken = call.token;
  self.callState = XMApplicationCallStateConnected;
  self.statusField.stringValue = [NSString stringWithFormat:@"Connected to %@", displayNameForCall(call)];
  [self updateInterface];
}

- (void)h323Client:(XMH323Client *)client
       didEndCall:(XMH323Call *)call
        h323Reason:(NSInteger)h323Reason
         q931Cause:(NSUInteger)q931Cause {
  (void)client;
  BOOL wasConnected = self.callState == XMApplicationCallStateConnected;
  NSString *remote = displayNameForCall(call);
  if ([remote isEqualToString:@"remote endpoint"]) {
    NSString *enteredAddress = trimmedString(self.addressField.stringValue);
    if (enteredAddress.length > 0) {
      remote = enteredAddress;
    }
  }
  self.activeCallToken = nil;
  [self refreshReadyStatus];
  if (self.callState == XMApplicationCallStateReady) {
    self.callState = callEndReasonIsFailure(h323Reason)
                         ? XMApplicationCallStateError
                         : XMApplicationCallStateReady;
    self.statusField.stringValue = callEndStatus(remote, h323Reason, q931Cause, wasConnected);
  }
  [self updateInterface];
}

- (void)h323Client:(XMH323Client *)client didEncounterError:(NSString *)message {
  (void)client;
  self.callState = XMApplicationCallStateError;
  self.statusField.stringValue = message;
  [self updateInterface];
}

@end
