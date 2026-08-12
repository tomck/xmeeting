#import <AppKit/AppKit.h>

#import "XMH323Client.h"
#import "XMAppDelegate.h"

#include <cstdio>
#include <cstring>

namespace {

int runSmokeTest() {
  NSBundle *bundle = NSBundle.mainBundle;
  NSString *identifier = bundle.bundleIdentifier;
  NSString *iconPath = [bundle pathForResource:@"XMeeting" ofType:@"icns"];
  NSString *callImagePath = [bundle pathForResource:@"Call_24" ofType:@"png"];
  XMH323Client *client = [[XMH323Client alloc] init];

  if (![identifier isEqualToString:@"net.sourceforge.xmeeting.XMeeting"] ||
      iconPath.length == 0 || callImagePath.length == 0 || client == nil) {
    std::fprintf(stderr, "XMeeting application bundle smoke test failed\n");
    return 1;
  }

  std::printf("XMeeting application bundle smoke test passed\n");
  return 0;
}

}  // namespace

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    for (int index = 1; index < argc; ++index) {
      if (std::strcmp(argv[index], "--smoke-test") == 0) {
        return runSmokeTest();
      }
    }

    NSApplication *application = NSApplication.sharedApplication;
    XMAppDelegate *delegate = [[XMAppDelegate alloc] init];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}
