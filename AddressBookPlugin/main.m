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

int main(int argc, char* argv[])
{
  NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];
  
  BOOL uninstall = NO;
  BOOL installGlobal = NO;
  BOOL installLocal = NO;
  BOOL authorize = NO;
  BOOL verbose = NO;
  
  char *action;
  
  // determine what to do
  for (unsigned i = 0; i < argc; i++) {
    char *str = argv[i];
    
    if (strcmp(str, "notInstalled") == 0) {
      uninstall = YES;
      action = "notInstalled";
    } else if (strcmp(str, "globalInstall") == 0) {
      installGlobal = YES;
      action = "globalInstall";
    } else if (strcmp(str, "localInstall") == 0) {
      installLocal = YES;
      action = "localInstall";
    } else if (strcmp(str, "authorize") == 0) {
      authorize = YES;
    } else if (strcmp(str, "verbose") == 0) {
      verbose = YES;
    }
  }
  
  BOOL success = YES;
  
  if (authorize == YES) {
    // obtain the external authorization ref
    NSFileHandle *fileHandle = [NSFileHandle fileHandleWithStandardInput];
    NSData *data = [fileHandle readDataOfLength:kAuthorizationExternalFormLength];
    AuthorizationExternalForm authExternalForm;
    memcpy(authExternalForm.bytes, [data bytes], kAuthorizationExternalFormLength);
    
    // create the authorization ref
    AuthorizationRef authRef;
    OSStatus result = AuthorizationCreateFromExternalForm(&authExternalForm, &authRef);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Could not open external authorization (%d)", result);
    }
    
    // determine executable path
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *executablePath = [bundle executablePath];
    const char *pathToTool = [executablePath cStringUsingEncoding:NSASCIIStringEncoding];
    
    // use action and be verbose
    const char *arguments[3];
    arguments[0] = action;
    arguments[1] = "verbose";
    arguments[2] = NULL;
    
    FILE *commPipe = NULL;
    
    // call itself using AEWP
    result = AuthorizationExecuteWithPrivileges(authRef, pathToTool, kAuthorizationFlagDefaults, (char **)arguments, &commPipe);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Error in AuthorizationExecuteWithPrivileges (%d)", result);
    }
    
    // read one line. This will block until the tool finished. The actual result is not important for now
    char buf[8];
    fgets(buf, 8, commPipe);
    
    // cleanup
    result = AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
    if (result != errAuthorizationSuccess) {
      NSLog(@"Error in Authorization Free (%d)", result);
    }
    fclose(commPipe);
  } else {
  
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL success = YES;
    
    NSString *globalPath = [NSString stringWithFormat:@"/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    NSString *localPath = [NSString stringWithFormat:@"~/Library/Address Book Plug-Ins/%@", AB_PLUGIN_NAME];
    localPath = [localPath stringByExpandingTildeInPath];
    
    // remove the global installation
    if ([fileManager fileExistsAtPath:globalPath]) {
      if (![fileManager removeFileAtPath:globalPath handler:nil]) {
        success = NO;
      }
    }
    // remove the local installation
    if ([fileManager fileExistsAtPath:localPath]) {
      if (![fileManager removeFileAtPath:localPath handler:nil]) {
        success = NO;
      }
    }
    
    if (uninstall == YES) {
      // already removed everything
    } else if (installGlobal == YES) {
      if (![fileManager copyPath:AB_PLUGIN_NAME toPath:globalPath handler:nil]) {
        success = NO;
      }
    } else if (installLocal == YES) {
      if (![fileManager copyPath:AB_PLUGIN_NAME toPath:localPath handler:nil]) {
        success = NO;
      }
    }
  }
  [autoreleasePool release];
  
  // inform the caller that the tool is done. When calling AuthorizationExecuteWithPrivileges, 
  // there seems no other way to determine whether the called tool finished or not.
  if (verbose == YES) {
    printf("done\n");
  }
  
  if (success == NO) {
    return 1;
  }
  
  return 0;
}
