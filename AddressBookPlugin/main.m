/*
 * Copyright (c) 2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "XMPluginManager.h"

@interface XMFileManagerHandler : NSObject {
}

- (BOOL)fileManager:(NSFileManager *)fileManager willProcessPath:(NSString *)path;
- (BOOL)fileManager:(NSFileManager *)fileManager shouldProceedAfterError:(NSDictionary *)errorInfo;

@end

@implementation XMFileManagerHandler

- (BOOL)fileManager:(NSFileManager *)fileManager willProcessPath:(NSString *)path
{
  return YES;
}

- (BOOL)fileManager:(NSFileManager *)fileManager shouldProceedAfterError:(NSDictionary *)errorInfo
{
  NSLog(@"Error while processing path %@", errorInfo);
  return NO;
}

@end

int main(int argc, char* argv[])
{
  NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];
  
  BOOL uninstall = NO;
  BOOL installGlobal = NO;
  BOOL installLocal = NO;
  BOOL authorize = NO;
  
  for (unsigned i = 0; i < argc; i++) {
    char *str = argv[i];
    
    if (strcmp(str, "notInstalled") == 0) {
      uninstall = YES;
    } else if (strcmp(str, "globalInstall") == 0) {
      installGlobal = YES;
    } else if (strcmp(str, "localInstall") == 0) {
      installLocal = YES;
    } else if (strcmp(str, "authorize") == 0) {
      authorize = YES;
    }
  }
  
  if (authorize == YES) {
    // obtain the authorization ref
    NSFileHandle *fileHandle = [NSFileHandle fileHandleWithStandardInput];
    NSData *data = [fileHandle readDataOfLength:kAuthorizationExternalFormLength];
    
    AuthorizationExternalForm authExternalForm;
    memcpy(authExternalForm.bytes, [data bytes], kAuthorizationExternalFormLength);
    
    AuthorizationRef authRef;
    OSStatus result = AuthorizationCreateFromExternalForm(&authExternalForm, &authRef);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Could not open external authorization %d", result);
    }
  }
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  XMFileManagerHandler *handler = [[XMFileManagerHandler alloc] init];
  BOOL success = YES;
  
  if (uninstall == YES) {
    NSString *globalPath = [NSString stringWithFormat:@"/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    if ([fileManager fileExistsAtPath:globalPath]) {
      if(![fileManager removeFileAtPath:globalPath handler:handler]) {
        success = NO;
      }
    }
    NSString *localPath = [NSString stringWithFormat:@"~/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    localPath = [localPath stringByExpandingTildeInPath];
    if ([fileManager fileExistsAtPath:localPath]) {
      if(![fileManager removeFileAtPath:localPath handler:handler]) {
        success = NO;
      }
    }
  } else if (installGlobal == YES) {
    NSString *globalPath = [NSString stringWithFormat:@"/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    if (![fileManager copyPath:AB_PLUGIN_NAME toPath:globalPath handler:handler]) {
      success = NO;
    }
    
    // remove the local installation if present
    NSString *localPath = [NSString stringWithFormat:@"~/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    localPath = [localPath stringByExpandingTildeInPath];
    if ([fileManager fileExistsAtPath:localPath]) {
      if(![fileManager removeFileAtPath:localPath handler:handler]) {
        success = NO;
      }
    }
  } else if (installLocal == YES) {
    NSString *localPath = [NSString stringWithFormat:@"~/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    localPath = [localPath stringByExpandingTildeInPath];
    if (![fileManager copyPath:AB_PLUGIN_NAME toPath:localPath handler:handler]) {
      success = NO;
    }
    
    // remove the global installation if present
    NSString *globalPath = [NSString stringWithFormat:@"/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    if ([fileManager fileExistsAtPath:globalPath]) {
      if(![fileManager removeFileAtPath:globalPath handler:handler]) {
        success = NO;
      }
    }
  }
  
  [handler release];
  [autoreleasePool release];
  
  if (success == NO) {
    return 1;
  }
  
  return 2;
}
