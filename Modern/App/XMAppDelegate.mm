#import "XMAppDelegate.h"

#import "XMCameraCapture.h"
#import "XMH264Decoder.h"
#import "XMH264Encoder.h"
#import "XMH323Client.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include <cstdio>

namespace {

NSString *const XMLocalAliasDefaultsKey = @"XMLocalAlias";
NSString *const XMVideoResolutionDefaultsKey = @"XMVideoResolution";

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
@property(nonatomic, strong, nullable) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, strong, nullable) AVSampleBufferDisplayLayer *remoteVideoLayer;
- (void)displayRemotePixelBuffer:(CVPixelBufferRef)pixelBuffer
           presentationTimeStamp:(CMTime)presentationTimeStamp;
- (void)clearRemoteVideo;
- (void)layoutVideoLayers;
@end

@implementation XMVideoPlaceholderView

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4];
  [background addClip];
  [NSColor.blackColor setFill];
  [background fill];

  if (self.previewLayer == nil && self.remoteVideoLayer == nil) {
    [self.placeholderImage drawInRect:self.bounds
                             fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver
                             fraction:1
                       respectFlipped:YES
                                hints:nil];
  }

  [NSColor.separatorColor setStroke];
  background.lineWidth = 1;
  [background stroke];
}

- (void)setPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer {
  [_previewLayer removeFromSuperlayer];
  _previewLayer = previewLayer;
  if (_previewLayer != nil) {
    self.wantsLayer = YES;
    // Keep the same capture session and preview layer throughout the call.
    // A higher z position preserves self-view when the remote layer is added
    // later, or when a camera becomes available during a call.
    _previewLayer.zPosition = 1;
    [self.layer addSublayer:_previewLayer];
  }
  [self layoutVideoLayers];
  [self setNeedsDisplay:YES];
}

- (void)displayRemotePixelBuffer:(CVPixelBufferRef)pixelBuffer
           presentationTimeStamp:(CMTime)presentationTimeStamp {
  if (self.remoteVideoLayer == nil) {
    self.wantsLayer = YES;
    AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.frame = self.bounds;
    [self.layer addSublayer:layer];
    self.remoteVideoLayer = layer;
    [self layoutVideoLayers];
  }
  if (self.remoteVideoLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
    [self.remoteVideoLayer flush];
  }

  CMVideoFormatDescriptionRef format = nullptr;
  if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                    &format) != noErr ||
      format == nullptr) {
    return;
  }
  CMSampleTimingInfo timing = {kCMTimeInvalid, presentationTimeStamp, kCMTimeInvalid};
  CMSampleBufferRef sampleBuffer = nullptr;
  const OSStatus status = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault, pixelBuffer, true, nullptr, nullptr, format, &timing,
      &sampleBuffer);
  CFRelease(format);
  if (status != noErr || sampleBuffer == nullptr) {
    return;
  }
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
  if (attachments != nullptr && CFArrayGetCount(attachments) != 0) {
    CFMutableDictionaryRef attachment = static_cast<CFMutableDictionaryRef>(
        const_cast<void *>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately,
                         kCFBooleanTrue);
  }
  [self.remoteVideoLayer enqueueSampleBuffer:sampleBuffer];
  CFRelease(sampleBuffer);
  self.accessibilityLabel = self.previewLayer == nil
                               ? @"Remote H.323 video"
                               : @"Remote H.323 video with local camera preview";
}

- (void)clearRemoteVideo {
  [self.remoteVideoLayer flushAndRemoveImage];
  [self.remoteVideoLayer removeFromSuperlayer];
  self.remoteVideoLayer = nil;
  [self layoutVideoLayers];
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  [self layoutVideoLayers];
}

- (void)layoutVideoLayers {
  // Layer geometry changes should be immediate on connect, resize, and
  // hangup rather than using Core Animation's default implicit animations.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.remoteVideoLayer.frame = self.bounds;
  const BOOL pictureInPicture = self.remoteVideoLayer != nil && self.previewLayer != nil;
  if (pictureInPicture) {
    const CGFloat margin = 10;
    const CGFloat width = MIN(MAX(96, NSWidth(self.bounds) * 0.28),
                              MAX(0, NSWidth(self.bounds) - 2 * margin));
    const CGFloat height = MIN(width * 0.75, MAX(0, NSHeight(self.bounds) - 2 * margin));
    const CGFloat y = self.layer.geometryFlipped
                          ? NSMaxY(self.bounds) - height - margin
                          : NSMinY(self.bounds) + margin;
    // Match the original XMeeting's lower-left picture-in-picture placement.
    self.previewLayer.frame = CGRectMake(NSMinX(self.bounds) + margin,
                                         y, width, height);
    self.previewLayer.cornerRadius = 2;
    self.previewLayer.borderWidth = 1.5;
    self.previewLayer.borderColor = [NSColor colorWithWhite:1 alpha:0.8].CGColor;
    self.previewLayer.backgroundColor = NSColor.blackColor.CGColor;
    self.previewLayer.masksToBounds = YES;
  } else {
    self.previewLayer.frame = self.bounds;
    self.previewLayer.cornerRadius = 0;
    self.previewLayer.borderWidth = 0;
    self.previewLayer.masksToBounds = NO;
  }
  self.previewLayer.hidden = NO;
  self.accessibilityLabel = pictureInPicture ? @"Remote H.323 video with local camera preview"
      : self.remoteVideoLayer != nil ? @"Remote H.323 video"
      : self.previewLayer != nil ? @"Local camera preview" : @"Video unavailable";
  [CATransaction commit];
}

@end

@interface XMAppDelegate () <XMCameraCaptureDelegate,
                              XMH264DecoderDelegate,
                              XMH264EncoderDelegate,
                              XMH323ClientDelegate,
                              NSTextFieldDelegate>

@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) XMH323Client *client;
@property(nonatomic, strong) XMCameraCapture *cameraCapture;
@property(nonatomic, strong) XMH264Encoder *h264Encoder;
@property(nonatomic, strong) XMH264Decoder *h264Decoder;
@property(nonatomic, strong) NSTextField *aliasField;
@property(nonatomic, strong) NSTextField *addressField;
@property(nonatomic, strong) NSTextField *statusField;
@property(nonatomic, strong) NSImageView *statusImageView;
@property(nonatomic, strong) NSButton *callButton;
@property(nonatomic, strong) NSProgressIndicator *progressIndicator;
@property(nonatomic, strong) XMVideoPlaceholderView *videoView;
@property(nonatomic, copy, nullable) NSString *activeCallToken;
@property(nonatomic) XMApplicationCallState callState;
@property(nonatomic) BOOL microphoneAuthorized;
@property(nonatomic) BOOL microphonePermissionPending;
@property(nonatomic) BOOL h264VideoEnabled;
@property(nonatomic) XMVideoResolution videoResolution;
@property(nonatomic, strong) NSWindow *settingsWindow;
@property(nonatomic, strong) NSPopUpButton *videoResolutionPopup;
@property(nonatomic, strong) NSTextField *videoSettingsStatus;

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
  self.videoResolution = [[NSUserDefaults.standardUserDefaults stringForKey:XMVideoResolutionDefaultsKey]
                            isEqualToString:@"720p"] ? XMVideoResolution720p : XMVideoResolutionVGA;
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
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--settings-preview"])
      [self showSettings:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      if (![self writeWindowPreviewToPath:previewOutputPath]) {
        std::fprintf(stderr, "Could not write XMeeting window preview\n");
      }
      [NSApp terminate:nil];
    });
    return;
  }

  [self rebuildMediaPipeline];
  [self prepareMicrophoneAuthorization];
  [self.cameraCapture start];
  [self startListener];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  [self.cameraCapture stop];
  [self.h264Encoder stop];
  [self.client stop];
  [self.h264Decoder stop];
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
  NSMenuItem *settingsItem = [applicationMenu addItemWithTitle:@"Settings…"
      action:@selector(showSettings:) keyEquivalent:@","];
  settingsItem.target = self;
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

  self.videoView = [[XMVideoPlaceholderView alloc] initWithFrame:NSZeroRect];
  self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
  self.videoView.placeholderImage = bundleImage(@"no_video_screen");
  self.videoView.accessibilityLabel = @"Video preview unavailable";

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

  for (NSView *view in @[aliasLabel, self.aliasField, self.videoView, statusStack, callStack]) {
    [contentView addSubview:view];
  }

  [NSLayoutConstraint activateConstraints:@[
    [aliasLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:16],
    [aliasLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:18],
    [self.aliasField.centerYAnchor constraintEqualToAnchor:aliasLabel.centerYAnchor],
    [self.aliasField.leadingAnchor constraintEqualToAnchor:aliasLabel.trailingAnchor constant:10],
    [self.aliasField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-18],

    [self.videoView.topAnchor constraintEqualToAnchor:self.aliasField.bottomAnchor constant:14],
    [self.videoView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:18],
    [self.videoView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-18],
    [self.videoView.heightAnchor constraintEqualToAnchor:self.videoView.widthAnchor multiplier:0.75],

    [statusStack.topAnchor constraintEqualToAnchor:self.videoView.bottomAnchor constant:14],
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
  NSView *view = [NSProcessInfo.processInfo.arguments containsObject:@"--settings-preview"]
                    ? self.settingsWindow.contentView : self.window.contentView;
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
    self.statusField.stringValue = self.h264VideoEnabled
                                       ? @"Ready for H.323 audio and H.264 video calls"
                                       : @"Ready for H.323 audio calls";
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

- (void)showSettings:(id)sender {
  (void)sender;
  if (self.settingsWindow == nil) {
    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 450, 250)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"XMeeting Settings";
    self.settingsWindow.releasedWhenClosed = NO;
    self.settingsWindow.tabbingMode = NSWindowTabbingModeDisallowed;
    XMWindowContentView *content = [[XMWindowContentView alloc]
        initWithFrame:self.settingsWindow.contentView.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.settingsWindow.contentView = content;
    NSTextField *heading = labelWithString(@"Video");
    heading.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    NSTextField *label = labelWithString(@"Outgoing video resolution");
    self.videoResolutionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.videoResolutionPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.videoResolutionPopup addItemsWithTitles:@[@"VGA — 640 × 480", @"720p — 1280 × 720"]];
    [self.videoResolutionPopup itemAtIndex:0].tag = XMVideoResolutionVGA;
    [self.videoResolutionPopup itemAtIndex:1].tag = XMVideoResolution720p;
    self.videoResolutionPopup.target = self;
    self.videoResolutionPopup.action = @selector(changeVideoResolution:);
    self.videoResolutionPopup.accessibilityLabel = @"Outgoing video resolution";
    NSTextField *explanation = [NSTextField wrappingLabelWithString:
        @"VGA uses less bandwidth. 720p provides a wider, sharper picture and requires a compatible H.264 peer. Both modes send up to 30 frames per second. The image is fitted without stretching."];
    explanation.translatesAutoresizingMaskIntoConstraints = NO;
    explanation.textColor = NSColor.secondaryLabelColor;
    self.videoSettingsStatus = [NSTextField wrappingLabelWithString:@""];
    self.videoSettingsStatus.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoSettingsStatus.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSStackView *stack = [NSStackView stackViewWithViews:
        @[heading, label, self.videoResolutionPopup, explanation, self.videoSettingsStatus]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [self.settingsWindow.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:self.settingsWindow.contentView.leadingAnchor constant:24],
      [stack.trailingAnchor constraintEqualToAnchor:self.settingsWindow.contentView.trailingAnchor constant:-24],
      [stack.topAnchor constraintEqualToAnchor:self.settingsWindow.contentView.topAnchor constant:24],
      [explanation.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
      [self.videoSettingsStatus.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    [self.settingsWindow center];
  }
  [self.videoResolutionPopup selectItemWithTag:self.videoResolution];
  [self updateVideoSettings];
  [self.settingsWindow makeKeyAndOrderFront:nil];
  [self.settingsWindow displayIfNeeded];
}

- (void)updateVideoSettings {
  const BOOL hasCall = self.activeCallToken.length > 0 || self.client.activeCallTokens.count > 0;
  self.videoResolutionPopup.enabled = !hasCall;
  self.videoSettingsStatus.stringValue = hasCall
      ? @"Hang up before changing the video resolution."
      : @"Saved automatically. Changes apply to the next call.";
}

- (void)changeVideoResolution:(NSPopUpButton *)sender {
  const XMVideoResolution resolution = (XMVideoResolution)sender.selectedTag;
  if (self.activeCallToken.length > 0 || self.client.activeCallTokens.count > 0 ||
      !XMVideoResolutionIsValid(resolution)) {
    [sender selectItemWithTag:self.videoResolution];
    [self updateVideoSettings];
    return;
  }
  if (resolution == self.videoResolution) return;
  self.videoResolution = resolution;
  [NSUserDefaults.standardUserDefaults setObject:resolution == XMVideoResolution720p ? @"720p" : @"vga"
                                          forKey:XMVideoResolutionDefaultsKey];
  [self rebuildMediaPipeline];
  [self startListener];
  [self.cameraCapture start];
}

- (void)rebuildMediaPipeline {
  // Drain the old capture queue before replacing the encoder. Invalidate old
  // delegates and ignore already-dispatched output from a previous pipeline.
  self.cameraCapture.delegate = nil;
  [self.cameraCapture stop];
  self.h264Encoder.delegate = nil;
  [self.h264Encoder stop];
  self.client.delegate = nil;
  [self.client stop];
  self.h264Decoder.delegate = nil;
  [self.h264Decoder stop];
  [self.videoView clearRemoteVideo];
  self.videoView.previewLayer = nil;
  self.h264VideoEnabled = NO;
  self.client = [[XMH323Client alloc] initWithDelegate:self];
  self.cameraCapture = [[XMCameraCapture alloc] initWithDelegate:self resolution:self.videoResolution];
  self.h264Encoder = [[XMH264Encoder alloc] initWithDelegate:self resolution:self.videoResolution];
  self.h264Decoder = [[XMH264Decoder alloc] initWithDelegate:self];
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
  [self updateVideoSettings];
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

#pragma mark - XMCameraCaptureDelegate

- (void)cameraCapture:(XMCameraCapture *)capture
    didChangePreviewAvailability:(BOOL)available
                         message:(NSString *)message {
  if (capture != self.cameraCapture) return;
  if (available) {
    self.videoView.previewLayer = capture.previewLayer;
  } else {
    self.videoView.previewLayer = nil;
    if (self.videoView.remoteVideoLayer == nil) {
      self.videoView.accessibilityLabel = message;
    }
  }
}

- (void)cameraCapture:(XMCameraCapture *)capture
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  (void)capture;
  [self.h264Encoder encodeSampleBuffer:sampleBuffer];
}

- (void)h264Encoder:(XMH264Encoder *)encoder
    didEncodeNALUnits:(NSArray<NSData *> *)nalUnits
             keyFrame:(BOOL)keyFrame {
  (void)encoder;
  (void)keyFrame;
  NSArray<NSData *> *copiedNALUnits = [[NSArray alloc] initWithArray:nalUnits
                                                          copyItems:YES];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (encoder != self.h264Encoder) return;
    if (!self.h264VideoEnabled) {
      NSError *error = nil;
      if (![self.client enableH264VideoWithResolution:self.videoResolution error:&error]) {
        std::fprintf(stderr, "XMeeting H.264 bridge: %s\n",
                     error.localizedDescription.UTF8String);
        return;
      }
      self.h264VideoEnabled = YES;
      if (self.callState == XMApplicationCallStateReady) {
        self.statusField.stringValue = @"Ready for H.323 audio and H.264 video calls";
      }
    }
    // A false return is expected until a peer negotiates a transmit channel.
    [self.client submitH264NALUnits:copiedNALUnits];
  });
}

- (void)h264Decoder:(XMH264Decoder *)decoder
    didDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
    presentationTimeStamp:(CMTime)presentationTimeStamp {
  CVPixelBufferRetain(pixelBuffer);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.activeCallToken.length > 0 && decoder == self.h264Decoder) {
      [self.videoView displayRemotePixelBuffer:pixelBuffer
                         presentationTimeStamp:presentationTimeStamp];
    }
    CVPixelBufferRelease(pixelBuffer);
  });
}

- (void)h264Decoder:(XMH264Decoder *)decoder didFailWithMessage:(NSString *)message {
  (void)decoder;
  std::fprintf(stderr, "XMeeting H.264 decoder: %s\n", message.UTF8String);
}

- (void)h264Encoder:(XMH264Encoder *)encoder didFailWithMessage:(NSString *)message {
  (void)encoder;
  std::fprintf(stderr, "XMeeting H.264 encoder: %s\n", message.UTF8String);
}

- (void)h323Client:(XMH323Client *)client didReceiveIncomingCall:(XMH323Call *)call {
  if (self.activeCallToken.length > 0) {
    [client rejectCallWithToken:call.token error:nil];
    return;
  }
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
    didReceiveH264NALUnits:(NSArray<NSData *> *)nalUnits {
  (void)client;
  if (self.activeCallToken.length == 0) return;
  [self.h264Decoder decodeNALUnits:nalUnits
             presentationTimeStamp:CMClockGetTime(CMClockGetHostTimeClock())];
}

- (void)h323Client:(XMH323Client *)client
       didEndCall:(XMH323Call *)call
        h323Reason:(NSInteger)h323Reason
         q931Cause:(NSUInteger)q931Cause {
  (void)client;
  if (self.activeCallToken.length > 0 && ![self.activeCallToken isEqualToString:call.token]) {
    return;
  }
  BOOL wasConnected = self.callState == XMApplicationCallStateConnected;
  NSString *remote = displayNameForCall(call);
  if ([remote isEqualToString:@"remote endpoint"]) {
    NSString *enteredAddress = trimmedString(self.addressField.stringValue);
    if (enteredAddress.length > 0) {
      remote = enteredAddress;
    }
  }
  self.activeCallToken = nil;
  [self.h264Decoder stop];
  // Discard already-dispatched frames from the old decoder after hangup.
  self.h264Decoder = [[XMH264Decoder alloc] initWithDelegate:self];
  [self.videoView clearRemoteVideo];
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
