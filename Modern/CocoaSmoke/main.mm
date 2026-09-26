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
    if (client.microphoneMuted || !client.videoTransmissionEnabled) return 18;
    client.microphoneMuted = YES;
    client.videoTransmissionEnabled = NO;
    if (!client.microphoneMuted || client.videoTransmissionEnabled) return 19;
    if (!client.fastStartEnabled || ![client setFastStartEnabled:NO error:&error] ||
        client.fastStartEnabled || ![client setFastStartEnabled:YES error:&error]) {
      std::fprintf(stderr, "Fast Start default/toggle failed\n");
      return 7;
    }
    if ([client.audioInputDevices containsObject:@"Null Audio"] ||
        [client.audioOutputDevices containsObject:@"Null Audio"]) return 8;
    BOOL defaultAudioAvailable = client.audioAvailable;
    NSString *input = client.audioInputDevice;
    NSString *output = client.audioOutputDevice;
    // Enumerating or selecting devices does not open a microphone or speaker.
    NSString *missing = @"XMeeting nonexistent device 4612D5E3-742A-4DFE-ADDB-BA344134734A";
    if ([client configureAudioInputDevice:missing outputDevice:@"" error:&error] || client.audioAvailable ||
        error.code != XMH323ClientErrorAudioUnavailable) return 9;
    if ([client configureAudioInputDevice:@"" outputDevice:missing error:&error] || client.audioAvailable)
      return 10;
    [client configureAudioInputDevice:@"" outputDevice:@"" error:&error];
    if (client.audioAvailable != defaultAudioAvailable) return 11;
    if (defaultAudioAvailable &&
        (![client configureAudioInputDevice:input outputDevice:output error:&error] ||
         ![client.audioInputDevice isEqualToString:input] || ![client.audioOutputDevice isEqualToString:output]))
      return 12;
    if (defaultAudioAvailable) {
      for (NSString *device in client.audioInputDevices) {
        if ([client.audioInputDevices filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"SELF == %@", device]].count != 1) continue;
        if (![client configureAudioInputDevice:device outputDevice:output error:&error] ||
            ![client.audioInputDevice isEqualToString:device]) return 15;
      }
      for (NSString *device in client.audioOutputDevices) {
        if ([client.audioOutputDevices filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"SELF == %@", device]].count != 1) continue;
        if (![client configureAudioInputDevice:input outputDevice:device error:&error] ||
            ![client.audioOutputDevice isEqualToString:device]) return 16;
      }
      if (![client configureAudioInputDevice:@"" outputDevice:@"" error:&error]) return 17;
    }
    if (![client startWithUserName:@"XMeetingModern" listenPort:port error:&error]) {
      std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    if ([client setFastStartEnabled:NO error:&error] || !client.fastStartEnabled) return 13;
    if (!client.microphoneMuted || client.videoTransmissionEnabled) return 20;
    client.microphoneMuted = NO;
    client.videoTransmissionEnabled = YES;
    if (client.microphoneMuted || !client.videoTransmissionEnabled) return 21;

    NSError *sipError = nil;
    if ([client callAddress:@"sip:not-supported@example.invalid" token:nil error:&sipError] ||
        sipError.code != XMH323ClientErrorInvalidArgument) {
      std::fprintf(stderr, "H.323-only address policy was not enforced\n");
      return 3;
    }

    // Video remains hidden until the application explicitly confirms that its
    // VideoToolbox encoder/decoder and renderer are ready (capture may be off).
    if (client.videoAvailable || client.videoCodecs.count != 0) {
      std::fprintf(stderr, "video was advertised before the native path was enabled\n");
      return 4;
    }

    NSError *videoError = nil;
    if (![client enableH264VideoWithError:&videoError] || !client.videoAvailable ||
        ![client.videoCodecs containsObject:@"H.264-VideoToolbox"]) {
      std::fprintf(stderr, "the native H.264 capability could not be enabled: %s\n",
                   videoError.localizedDescription.UTF8String ?: "unknown error");
      return 5;
    }
    if ([client submitH264NALUnits:@[[NSData dataWithBytes:"\x65" length:1]]]) {
      std::fprintf(stderr, "an idle H.264 frame was queued without a video channel\n");
      return 6;
    }

    std::printf("H323Plus Cocoa bridge listening on port %u\n", port);
    [client stop];
    if (![client setFastStartEnabled:NO error:&error] || client.fastStartEnabled) return 14;
    std::printf("PASS: Fast Start toggle, device enumeration, missing-device rejection, and default recovery\n");
  }
  return 0;
}
