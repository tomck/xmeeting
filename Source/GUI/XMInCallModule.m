/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import "XMInCallModule.h"

#import "XMeeting.h"
#import "XMMainWindowController.h"
#import "XMPreferencesManager.h"
#import "XMOSDVideoView.h"
#import "XMNoCallModule.h";

#define VIDEO_INSET_TOP 27.0
#define VIDEO_INSET_LEFT 5.0
#define VIDEO_INSET_RIGHT 5.0
#define VIDEO_INSET_BOTTOM 25.0

#define NO_VIDEO_WIDTH 290
#define NO_VIDEO_HEIGHT 65

NSString *XMKey_VideoViewSettings = @"XMeeting_VideoViewSettings";
NSString *XMKey_InCallModuleSize = @"XMeeting_InCallModuleSize";

@interface XMInCallModule (PrivateMethods)

- (void)_didEstablishCall:(NSNotification *)notif;
- (void)_didClearCall:(NSNotification *)notif;
- (void)_updateWindowSize;

@end

@implementation XMInCallModule

- (id)init
{
  self = [super init];
  
  isFullScreen = NO;
  
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
  
  [notificationCenter addObserver:self selector:@selector(_didEstablishCall:)
                             name:XMNotification_CallManagerDidEstablishCall object:nil];
  [notificationCenter addObserver:self selector:@selector(_didClearCall:)
                             name:XMNotification_CallManagerDidClearCall object:nil];
  
  isActive = NO;
  
  return self;
}

- (void)dealloc
{  
  [super dealloc];
}

- (void)awakeFromNib
{
  contentViewMinSize = [contentView bounds].size;
  videoViewMinSize = [videoView frame].size;
  
  // adjust no video size, fix the height
  noVideoContentViewMinSize.width = NO_VIDEO_WIDTH;
  noVideoContentViewMinSize.height = (contentViewMinSize.height + NO_VIDEO_HEIGHT - videoViewMinSize.height);
  
  // the initial size equals the min size, if not specified in preferences
  contentViewSize = contentViewMinSize;
  NSString *contentViewSizeString = [[NSUserDefaults standardUserDefaults] stringForKey:XMKey_InCallModuleSize];
  if (contentViewSizeString != nil) {
    contentViewSize.width = NSSizeFromString(contentViewSizeString).width;
  }
}

- (NSString *)name
{
  return @"InCall";
}

- (NSView *)contentView
{
  if (contentView == nil) {
    [NSBundle loadNibNamed:@"InCallModule" owner:self];
  }
  
  if (isFullScreen == YES) {
    return videoView;
  }
  
  return contentView;
}

- (NSSize)contentViewSize
{
  [self contentView];
  
  if (isActive == NO) {
    [self _updateWindowSize];
  }
  
  return contentViewSize;
}

- (NSSize)contentViewMinSize
{
  [self contentView];
  
  if ([[[XMPreferencesManager sharedInstance] activeLocation] enableVideo] == YES) {
    return contentViewMinSize;
  } else {
    return noVideoContentViewMinSize;
  }
}

- (NSSize)contentViewMaxSize
{
  [self contentView];
  
  if ([[[XMPreferencesManager sharedInstance] activeLocation] enableVideo] == YES) {
    return NSMakeSize(5000, 5000);
  } else {
    return NSMakeSize(5000, noVideoContentViewMinSize.height);
  }
}

- (NSSize)adjustResizeDifference:(NSSize)resizeDifference minimumHeight:(unsigned)minimumHeight
{
  if ([[[XMPreferencesManager sharedInstance] activeLocation] enableVideo] == NO) {
    // also update the preferences
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromSize([contentView bounds].size) forKey:XMKey_InCallModuleSize];
    return resizeDifference;
  }
  
  NSSize size = [contentView bounds].size;
  
  // minimum height is height minus height of minimum picture
  unsigned usedHeight = contentViewMinSize.height - 288.0;
  
  int minimumVideoHeight = contentViewMinSize.height - usedHeight;
  int currentVideoHeight = (int)size.height - usedHeight;
  
  int availableWidth = (int)size.width + (int)resizeDifference.width - VIDEO_INSET_LEFT - VIDEO_INSET_RIGHT;
  int newHeight = currentVideoHeight + (int)resizeDifference.height;
  
  // Aspect ratios other than CIF / QCIF are handled within
  // the OSD video view
  int calculatedWidthFromHeight = (int)XMGetVideoWidthForHeight(newHeight, XMVideoSize_CIF);
  int calculatedHeightFromWidth = (int)XMGetVideoHeightForWidth(availableWidth, XMVideoSize_CIF);
  
  if (calculatedHeightFromWidth <= minimumVideoHeight) {
    // set the height to the minimum height
    resizeDifference.height = minimumVideoHeight - currentVideoHeight;
  } else {
    if (calculatedWidthFromHeight < availableWidth) {
      // the height value takes precedence
      int widthDifference = availableWidth - calculatedWidthFromHeight;
      resizeDifference.width -= widthDifference;
    } else {
      // the width value takes precedence
      int heightDifference = newHeight - calculatedHeightFromWidth;
      resizeDifference.height -= heightDifference;
    }
  }
  
  // also update the preferences
  [[NSUserDefaults standardUserDefaults] setObject:NSStringFromSize([contentView bounds].size) forKey:XMKey_InCallModuleSize];
  
  return resizeDifference;
}

- (void)becomeActiveModule
{
  [self contentView];
  
  XMPreferencesManager *preferencesManager = [XMPreferencesManager sharedInstance];
  XMLocation *activeLocation = [preferencesManager activeLocation];
  BOOL enableVideo = [activeLocation enableVideo];
  
  NSString *settings = [[NSUserDefaults standardUserDefaults] stringForKey:XMKey_VideoViewSettings];
  if (settings != nil) {
    [videoView setSettings:settings];
  }
  
  if (enableVideo == YES) {
    // Check whether QuartzExtreme is enabled or not to hide some functions
    // wich don't work well on non quartz-extreme machines
    // For simplicity, we consider only the main display
    BOOL enableComplexModes = CGDisplayUsesOpenGLAcceleration(CGMainDisplayID());
    [videoView setEnableComplexPinPModes:enableComplexModes];
    
    BOOL mirrorLocalVideo = [preferencesManager showSelfViewMirrored];
    [videoView setLocalVideoMirrored:mirrorLocalVideo];
    
    [videoView startDisplayingVideo];
  } else {
    [videoView setNoVideoImage:nil];
    [videoView startDisplayingNoVideo];
  }
  
  if ([preferencesManager automaticallyHideInCallControls] && enableVideo == YES) {
    [videoView setOSDDisplayMode:XMOSDDisplayMode_AutomaticallyHiding];
  } else {
    [videoView setOSDDisplayMode:XMOSDDisplayMode_AlwaysVisible];
  }
  
  XMInCallControlHideAndShowEffect effect = [preferencesManager inCallControlHideAndShowEffect];
  [videoView setOSDOpeningEffect:(XMOpeningEffect)effect];
  [videoView setOSDClosingEffect:(XMClosingEffect)effect];
  
  if (isFullScreen == YES && enableVideo == YES) {
    [[videoView window] makeFirstResponder:videoView];
  }
  
  [self _updateWindowSize];
  isActive = YES;
}

- (void)becomeInactiveModule
{
  [videoView setOSDDisplayMode:XMOSDDisplayMode_NoOSD];
  [videoView stopDisplayingVideo];
  
  // storing some settings of the video view
  NSString *settings = [videoView settings];
  [[NSUserDefaults standardUserDefaults] setObject:settings forKey:XMKey_VideoViewSettings];
  
  contentViewSize = [contentView bounds].size;
  [[NSUserDefaults standardUserDefaults] setObject:NSStringFromSize(contentViewSize) forKey:XMKey_InCallModuleSize];
  isActive = NO;
}

- (void)beginFullScreen
{
  isFullScreen = YES;
  
  [self contentView];
  
  [videoView removeFromSuperviewWithoutNeedingDisplay];
  [videoView setFullScreen:YES];
}

- (void)endFullScreen
{
  isFullScreen = NO;
  
  [self contentView];
  
  NSRect frame = [contentView bounds];
  
  frame.origin.x += VIDEO_INSET_LEFT;
  frame.origin.y += VIDEO_INSET_BOTTOM;
  frame.size.width -= (VIDEO_INSET_LEFT + VIDEO_INSET_RIGHT);
  frame.size.height -= (VIDEO_INSET_TOP + VIDEO_INSET_BOTTOM);
  
  [contentView addSubview:videoView];
  [videoView setFrame:frame];
  
  [videoView setFullScreen:NO];
}

#pragma mark User Interface Methods

- (void)clearCall:(id)sender
{
  if (didClearCall == YES) {
    return;
  }
  didClearCall = YES;
  [[XMCallManager sharedInstance] clearActiveCall];
}

#pragma mark Private Methods

- (void)_didEstablishCall:(NSNotification *)notif
{
  //loading the nib file if not already done
  [self contentView];
  
  NSString *remoteName = [[[XMCallManager sharedInstance] activeCall] remoteName];
  [remotePartyField setStringValue:remoteName];
}

- (void)_didClearCall:(NSNotification *)notif
{
  [remotePartyField setStringValue:@""];
  
  [videoView releaseOSD];
}

- (void)_updateWindowSize
{
  // ensure the window width is >= the width of the no call module
  NSString *noCallSizeString = [[NSUserDefaults standardUserDefaults] stringForKey:XMKey_NoCallModuleSize];
  NSSize noCallSize = NSMakeSize(0, 0);
  if (noCallSizeString != nil) {
    noCallSize = NSSizeFromString(noCallSizeString);
  }
  if (contentViewSize.width < noCallSize.width) {
    contentViewSize.width = noCallSize.width;
  }
  // calculate the corresponding height
  if ([[[XMPreferencesManager sharedInstance] activeLocation] enableVideo]) {
    int widthDifference = contentViewSize.width - contentViewMinSize.width;
    int videoWidth = videoViewMinSize.width + widthDifference;
    int videoHeight = (int)XMGetVideoHeightForWidth(videoWidth, XMVideoSize_CIF);
    int heightDifference = videoHeight - videoViewMinSize.height;
    contentViewSize.height = contentViewMinSize.height;
    contentViewSize.height += heightDifference;
  } else {
    contentViewSize.height = noVideoContentViewMinSize.height;
  }
  
  // also update the preferences
  [[NSUserDefaults standardUserDefaults] setObject:NSStringFromSize(contentViewSize) forKey:XMKey_InCallModuleSize];
}

@end
