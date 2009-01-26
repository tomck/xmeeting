/*
 * Copyright (c) 2006-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2006-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_ADDRESS_BOOK_PREFERENCES_MODULE_H__
#define __XM_ADDRESS_BOOK_PREFERENCES_MODULE_H__

#import <Cocoa/Cocoa.h>

#import "XMPreferencesModule.h"

@interface XMAddressBookPreferencesModule : NSObject <XMPreferencesModule> {

@private
  XMPreferencesWindowController *prefWindowController;
  
  IBOutlet NSView *contentView;
  float contentViewHeight;
  
  IBOutlet NSButton *enableABDatabaseSearchSwitch;
  IBOutlet NSButton *enableABPhoneNumbersSwitch;
  IBOutlet NSMatrix *phoneNumberProtocolMatrix;
  IBOutlet NSButton *installABPluginSwitch;
  IBOutlet NSButton *installABPluginGloballySwitch;
	
}

- (IBAction)defaultAction:(id)sender;
- (IBAction)toggleEnableABPhoneNumbers:(id)sender;
- (IBAction)toggleInstallABPlugin:(id)sender;

@end

#endif // __XM_ADDRESS_BOOK_PREFERENCES_MODULE_H__
