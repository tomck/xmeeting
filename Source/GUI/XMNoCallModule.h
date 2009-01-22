/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_NO_CALL_MODULE_H__
#define __XM_NO_CALL_MODULE_H__

#import <Cocoa/Cocoa.h>

#import "XMMainWindowModule.h"
#import "XMDatabaseField.h"

extern NSString *XMKey_NoCallModuleSize;

@class XMLocalVideoView;

/**
 * XMNoCallModule is the main window module displayed when the
 * application is not in a call.
 **/
@interface XMNoCallModule : NSObject <XMMainWindowModule, XMDatabaseFieldDataSource> {
  
@private
  // XMMainWindowModule Outlets and variables
  IBOutlet NSView *contentView;
  
  NSSize contentViewMinSizeWithSelfViewHidden;
  NSSize contentViewMinSizeWithSelfViewShown;
  NSSize selfViewMinSize;
  NSSize contentViewSize;
  
  // GUI Outlets
  IBOutlet XMLocalVideoView *selfView;
  IBOutlet NSButton *statusButton;
  IBOutlet NSProgressIndicator *busyIndicator;
  IBOutlet NSTextField *statusField;
  IBOutlet NSPopUpButton *locationsPopUpButton;
  IBOutlet XMDatabaseField *callAddressField;
  IBOutlet NSButton *callButton;
  IBOutlet NSBox *topRowBox;
  IBOutlet NSBox *bottomRowBox;
  
  // timer to clear the call end reason
  NSTimer *callEndReasonTimer;
  
  // Optimizations for XMDatabaseField completions
  unsigned uncompletedStringLength;
  NSMutableArray *matchedAddresses;
  NSMutableArray *completions;
  
  XMCallProtocol currentCallProtocol;
  BOOL doesShowSelfView;
  BOOL isCalling;
  BOOL didBecomeInactive;
}

- (IBAction)call:(id)sender;
- (IBAction)changeActiveLocation:(id)sender;
- (IBAction)showInfoInspector:(id)sender;
- (IBAction)showTools:(id)sender;
- (IBAction)showContacts:(id)sender;
- (IBAction)toggleShowSelfView:(id)sender;


@end

#endif // __XM_NO_CALL_MODULE_H__