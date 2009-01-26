/*
 * Copyright (c) 2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_PLUGIN_MANAGER_H__
#define __XM_PLUGIN_MANAGER_H__

#define AB_PLUGIN_NAME @"XMeetingABPlugin.bundle"

#import <Cocoa/Cocoa.h>

typedef enum XMInstallStatus {
  XMInstallStatus_NotInstalled            = 0x00,
  XMInstallStatus_NewerVersionInstalled   = 0x01,
  XMInstallStatus_OlderVersionInstalled   = 0x02,
  XMInstallStatus_InstalledForAllUsers    = 0x04,
  XMInstallStatus_InstalledForCurrentUser = 0x08,
} XMInstallStatus;

@interface XMPluginManager : NSObject {

}

+ (XMPluginManager *)sharedInstance;

/**
 * Returns a combination of the valid status flags
 **/
- (XMInstallStatus)addressBookPluginInstallStatus;

/**
 * Allowed values: NotInstalled, InstalledForAllUsers, InstalledForCurrentUser
 * Does nothing if a newer version is installed.
 **/
- (void)setAddressBookPluginInstallStatus:(XMInstallStatus)status;

@end

#endif // __XM_PLUGIN_MANAGER_H__