/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_IN_CALL_MODULE_H__
#define __XM_IN_CALL_MODULE_H__

#import <Cocoa/Cocoa.h>
#import "XMMainWindowModule.h"

extern NSString *XMKey_InCallModuleSize;

@class XMOSDVideoView;

@interface XMInCallModule : NSObject <XMMainWindowModule> {

@private
  IBOutlet NSView *contentView;
  NSSize contentViewMinSize;
  NSSize noVideoContentViewMinSize;
  NSSize videoViewMinSize;
  NSSize contentViewSize;
  
  IBOutlet XMOSDVideoView *videoView;
  
  IBOutlet NSTextField *remotePartyField;
  
  BOOL isFullScreen;
  
  BOOL didClearCall;
  
  BOOL isActive;
}

- (IBAction)clearCall:(id)sender;

@end

#endif // __XM_IN_CALL_MODULE_H__
