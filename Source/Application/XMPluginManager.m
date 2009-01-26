/*
 * Copyright (c) 2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import <Security/Security.h>

#import "XMPluginManager.h"

const int currentABPluginVersion = 1;
NSString *abManagerPath = @"AddressBookPlugin/ABPluginManager";

@interface XMPluginManager (PrivateMethods)

- (unsigned)_getBundleVersion:(NSString *)path;

@end

@implementation XMPluginManager

+ (XMPluginManager *)sharedInstance
{
  static XMPluginManager *sharedInstance = nil;
  if (sharedInstance == nil) {
    sharedInstance = [[XMPluginManager alloc] init];
  }
  return sharedInstance;
}

- (XMInstallStatus)addressBookPluginInstallStatus
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  XMInstallStatus installStatus = XMInstallStatus_NotInstalled;
  
  // check the global installation
  NSString *globalPath = [NSString stringWithFormat:@"/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
  BOOL isDirectory = NO;
  if ([fileManager fileExistsAtPath:globalPath isDirectory:&isDirectory] && isDirectory == YES) {
    installStatus |= XMInstallStatus_InstalledForAllUsers;
    
    // also check the version
    unsigned version = [self _getBundleVersion:globalPath];
    if (version > currentABPluginVersion) {
      installStatus |= XMInstallStatus_NewerVersionInstalled;
    } else if (version < currentABPluginVersion) {
      installStatus |= XMInstallStatus_OlderVersionInstalled;
    }
  }
  
  // check the local installation
  NSString *localPath = [NSString stringWithFormat:@"~/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
  localPath = [localPath stringByExpandingTildeInPath];
  if ([fileManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory == YES) {
    installStatus |= XMInstallStatus_InstalledForCurrentUser;
    
    // also check the version
    unsigned version = [self _getBundleVersion:globalPath];
    if (version > currentABPluginVersion) {
      installStatus |= XMInstallStatus_NewerVersionInstalled;
    }
  }
  
  return installStatus;
}

- (void)setAddressBookPluginInstallStatus:(XMInstallStatus)status
{
  // don't do anything if a newer version is installed
  XMInstallStatus currentStatus = [self addressBookPluginInstallStatus];
  if ((currentStatus & XMInstallStatus_NewerVersionInstalled) != 0) {
    return;
  }
  
  BOOL requiresAuthorization = NO;
  
  if ((status & XMInstallStatus_InstalledForAllUsers) != 0) {
    // global install
    if ((currentStatus & XMInstallStatus_InstalledForAllUsers) != 0 &&
        (currentStatus & XMInstallStatus_OlderVersionInstalled) == 0) {
      // no need to change anything
      return;
    }
    // global install requires authorization
    requiresAuthorization = YES;
  } else if ((status & XMInstallStatus_InstalledForCurrentUser) != 0) {
    // local install
    if ((currentStatus & XMInstallStatus_InstalledForAllUsers) != 0) {
      requiresAuthorization = YES;
    }
    // always do a local install
  } else if (status == XMInstallStatus_NotInstalled &&
             (currentStatus & XMInstallStatus_InstalledForAllUsers) != 0) {
    // need to remove the global installation
    requiresAuthorization = YES;
  }
  
  NSBundle *mainBundle = [NSBundle mainBundle];
  NSString *pluginsPath = [mainBundle builtInPlugInsPath];
  NSString *executablePath = [pluginsPath stringByAppendingPathComponent:abManagerPath];
  NSString *argument = nil;
  NSString *authorizationArgument = nil;
  NSData *authorizationData = nil;
  AuthorizationRef authRef;
  
  if (status == XMInstallStatus_InstalledForAllUsers) {
    argument = @"globalInstall";
  } else if (status == XMInstallStatus_InstalledForCurrentUser) {
    argument = @"localInstall";
  } else {
    argument = @"notInstalled";
  }
  
  int returnCode = -1;
  
  if (requiresAuthorization) {
    OSStatus result;
    
    // create an empty authorization reference
    result = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                 kAuthorizationFlagDefaults, &authRef);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Error in AuthorizationCreate: %d", result);
      return;
    }
    
    // do preauthorization
    AuthorizationItem authItems[1];
    authItems[0].name = "XMeeting.ABPluginManager";
    authItems[0].valueLength = 0;
    authItems[0].value = NULL;
    authItems[0].flags = 0;
    AuthorizationRights authRights;
    authRights.count = 1;
    authRights.items = authItems;
    AuthorizationFlags authFlags = (kAuthorizationFlagDefaults |
                                    kAuthorizationFlagExtendRights |
                                    kAuthorizationFlagInteractionAllowed |
                                    kAuthorizationFlagPreAuthorize);
    
    result = AuthorizationCopyRights(authRef, &authRights, kAuthorizationEmptyEnvironment, authFlags, NULL);
    if (result != errAuthorizationSuccess) {
      if (result != errAuthorizationCanceled && result != errAuthorizationDenied) {
        NSLog(@"Error in AuthCopyRights %d", result);
      }
      AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
      return;
    }
    
    // obtain external auth reference
    AuthorizationExternalForm authExternalForm;
    result = AuthorizationMakeExternalForm(authRef, &authExternalForm);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Error in AuthorizationMakeExternalForm %d", result);
      AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
      return;
    }
    // cause the helper tool to authorize
    authorizationArgument = @"authorize";
    authorizationData = [NSData dataWithBytes:authExternalForm.bytes length:kAuthorizationExternalFormLength];
  }
  
  // use NSTask
  NSTask *task = [[NSTask alloc] init];
  NSPipe *pipe = nil;
  [task setLaunchPath:executablePath];
  [task setCurrentDirectoryPath:[executablePath stringByDeletingLastPathComponent]];
  NSArray *arguments = [NSArray arrayWithObjects:argument, authorizationArgument, nil];
  [task setArguments:arguments];
  if (authorizationData != nil) {
    pipe = [NSPipe pipe];
    [task setStandardInput:pipe];
  }
  [task launch];
  if (authorizationData != nil) {
    [[pipe fileHandleForWriting] writeData:authorizationData];
  }
  [task waitUntilExit];
  returnCode = [task terminationStatus];
  [task release];
  
  if (requiresAuthorization) {
    OSStatus result = AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Error in AuthorizationFree %d", result);
    }
  }
}

- (unsigned)_getBundleVersion:(NSString *)path
{
  NSBundle *bundle = [NSBundle bundleWithPath:path];
  if (bundle != nil) {
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (version != nil) {
      double value = [version doubleValue];
      return (unsigned)value;
    }
  }
  return 0;
}

@end
