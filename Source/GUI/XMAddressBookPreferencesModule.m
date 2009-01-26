/*
 * Copyright (c) 2006-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2006-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import "XMAddressBookPreferencesModule.h"
#import "XMPreferencesWindowController.h"
#import "XMPreferencesManager.h"
#import "XMPluginManager.h"

@interface XMAddressBookPreferencesModule (PrivateMethods)

- (void)_validateProtocolMatrix;
- (void)_validatePluginGlobalInstallSwitch;

@end

@implementation XMAddressBookPreferencesModule

- (id)init
{
  prefWindowController = [[XMPreferencesWindowController sharedInstance] retain];
  
  return self;
}

- (void)awakeFromNib
{
  contentViewHeight = [contentView frame].size.height;
  [prefWindowController addPreferencesModule:self];
}

- (void)dealloc
{
  [prefWindowController release];
  
  [super dealloc];
}

#pragma mark -
#pragma mark XMPreferencesModule methods

- (unsigned)position
{
  return 6;
}

- (NSString *)identifier
{
  return @"XMeeting_AddressBookPreferencesModule";
}

- (NSString *)toolbarLabel
{
  return NSLocalizedString(@"XM_ADDRESS_BOOK_PREFERENCES_NAME", @"");
}

- (NSImage *)toolbarImage
{
  return [NSImage imageNamed:@"AddressBook"];
}

- (NSString *)toolTipText
{
  return NSLocalizedString(@"XM_ADDRESS_BOOK_PREFERENCES_TOOLTIP", @"");
}

- (NSView *)contentView
{
  return contentView;
}

- (float)contentViewHeight
{
  return contentViewHeight;
}

- (void)loadPreferences
{
  XMPreferencesManager *preferencesManager = [XMPreferencesManager sharedInstance];
  
  int state = ([preferencesManager searchAddressBookDatabase] == YES) ? NSOnState : NSOffState;
  [enableABDatabaseSearchSwitch setState:state];
  
  state = ([preferencesManager enableAddressBookPhoneNumbers] == YES) ? NSOnState : NSOffState;
  [enableABPhoneNumbersSwitch setState:state];
  
  XMCallProtocol callProtocol = [preferencesManager addressBookPhoneNumberProtocol];
  [phoneNumberProtocolMatrix selectCellWithTag:(int)callProtocol];
  
  XMInstallStatus pluginInstallStatus = [[XMPluginManager sharedInstance] addressBookPluginInstallStatus];
  if (pluginInstallStatus == XMInstallStatus_NotInstalled) {
    [installABPluginSwitch setState:NSOffState];
    [installABPluginGloballySwitch setState:NSOffState];
  } else {
    if ((pluginInstallStatus & XMInstallStatus_InstalledForAllUsers) != 0) {
      [installABPluginSwitch setState:NSOnState];
      [installABPluginGloballySwitch setState:NSOnState];
    } else {
      [installABPluginGloballySwitch setState:NSOffState];
    }
    // disable GUI if a newer version is installed
    if ((pluginInstallStatus & XMInstallStatus_NewerVersionInstalled) != 0) {
      [installABPluginSwitch setEnabled:NO];
    } else {
      [installABPluginSwitch setEnabled:YES];
    }
  }
  
  [self _validateProtocolMatrix];
  [self _validatePluginGlobalInstallSwitch];
}

- (void)savePreferences
{
  XMPreferencesManager *preferencesManager = [XMPreferencesManager sharedInstance];
  
  BOOL flag = ([enableABDatabaseSearchSwitch state] == NSOnState) ? YES : NO;
  [preferencesManager setSearchAddressBookDatabase:flag];
  
  flag = ([enableABPhoneNumbersSwitch state] == NSOnState) ? YES : NO;
  [preferencesManager setEnableAddressBookPhoneNumbers:flag];
  
  XMCallProtocol callProtocol = (XMCallProtocol)[[phoneNumberProtocolMatrix selectedCell] tag];
  [preferencesManager setAddressBookPhoneNumberProtocol:callProtocol];
  
  if ([installABPluginSwitch isEnabled]) {
    XMInstallStatus pluginInstallStatus = XMInstallStatus_NotInstalled;
    if ([installABPluginSwitch state] == NSOnState) {
      if ([installABPluginGloballySwitch state] == NSOnState) {
        pluginInstallStatus = XMInstallStatus_InstalledForAllUsers;
      } else {
        pluginInstallStatus = XMInstallStatus_InstalledForCurrentUser;
      }
    }
    [[XMPluginManager sharedInstance] setAddressBookPluginInstallStatus:pluginInstallStatus];
  }
}

- (void)becomeActiveModule
{
}

- (BOOL)validateData
{
  return YES;
}

#pragma mark -
#pragma mark Action Methods

- (IBAction)defaultAction:(id)sender
{
  [prefWindowController notePreferencesDidChange];
}

- (IBAction)toggleEnableABPhoneNumbers:(id)sender
{
  [self _validateProtocolMatrix];
  [self defaultAction:self];
}

- (IBAction)toggleInstallABPlugin:(id)sender
{
  [self _validatePluginGlobalInstallSwitch];
  [self defaultAction:self];
}

#pragma mark -
#pragma mark Private Methods

- (void)_validateProtocolMatrix
{
  if ([enableABPhoneNumbersSwitch state] == NSOnState) {
    [phoneNumberProtocolMatrix setEnabled:YES];
  } else {
    [phoneNumberProtocolMatrix setEnabled:NO];
  }
}
  
- (void)_validatePluginGlobalInstallSwitch
{
  if ([installABPluginSwitch state] == NSOnState && [installABPluginSwitch isEnabled]) {
    [installABPluginGloballySwitch setEnabled:YES]; 
  } else {
    [installABPluginGloballySwitch setEnabled:NO];
  } 
}

@end
