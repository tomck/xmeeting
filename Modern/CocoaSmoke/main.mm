#import <Foundation/Foundation.h>

#import "XMH323Client.h"

#include <cstdio>
#include <cstdlib>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    uint16_t port = 18201;
    if (argc > 1) {
      const unsigned long requestedPort = std::strtoul(argv[1], nullptr, 10);
      if (requestedPort == 0 || requestedPort > UINT16_MAX) {
        std::fprintf(stderr, "invalid listener port\n");
        return 2;
      }
      port = static_cast<uint16_t>(requestedPort);
    }

    XMH323Client *client = [[XMH323Client alloc] init];
    NSError *error = nil;
    if (![client startWithUserName:@"XMeetingModern" listenPort:port error:&error]) {
      std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      return 1;
    }

    NSError *sipError = nil;
    if ([client callAddress:@"sip:not-supported@example.invalid" token:nil error:&sipError] ||
        sipError.code != XMH323ClientErrorInvalidArgument) {
      std::fprintf(stderr, "H.323-only address policy was not enforced\n");
      return 3;
    }

    std::printf("H323Plus Cocoa bridge listening on port %u\n", port);
    [client stop];
  }
  return 0;
}
