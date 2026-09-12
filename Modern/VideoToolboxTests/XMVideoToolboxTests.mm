#import "XMH264Decoder.h"
#import "XMH264Encoder.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstring>

@interface XMVideoToolboxTestHarness : NSObject <XMH264DecoderDelegate, XMH264EncoderDelegate>
@property(nonatomic, strong) XMH264Encoder *encoder;
@property(nonatomic, strong) XMH264Decoder *decoder;
@property(nonatomic) dispatch_semaphore_t completion;
@property(nonatomic, copy, nullable) NSString *failure;
@property(nonatomic) XMVideoResolution resolution;
@end

@implementation XMVideoToolboxTestHarness

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _completion = dispatch_semaphore_create(0);
    _encoder = [[XMH264Encoder alloc] initWithDelegate:self];
    _decoder = [[XMH264Decoder alloc] initWithDelegate:self];
  }
  return self;
}

- (void)h264Encoder:(XMH264Encoder *)encoder
    didEncodeNALUnits:(NSArray<NSData *> *)nalUnits
             keyFrame:(BOOL)keyFrame {
  (void)encoder;
  if (!keyFrame) {
    self.failure = @"The first synthetic H.264 frame was not a key frame";
    dispatch_semaphore_signal(self.completion);
    return;
  }
  BOOL validSPS = NO;
  const auto profile = XMVideoProfileForResolution(self.resolution);
  for (NSData *nal in nalUnits) {
    const auto *bytes = static_cast<const uint8_t *>(nal.bytes);
    if (nal.length >= 4 && (bytes[0] & 31) == 7)
      validSPS = bytes[1] == 66 && bytes[3] == profile.levelIDC;
  }
  if (!validSPS) {
    self.failure = @"The encoded SPS does not match the selected Baseline level";
    dispatch_semaphore_signal(self.completion);
    return;
  }
  [self.decoder decodeNALUnits:nalUnits presentationTimeStamp:CMTimeMake(1, 30)];
}

- (void)h264Encoder:(XMH264Encoder *)encoder didFailWithMessage:(NSString *)message {
  (void)encoder;
  self.failure = message;
  dispatch_semaphore_signal(self.completion);
}

- (void)h264Decoder:(XMH264Decoder *)decoder
    didDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
    presentationTimeStamp:(CMTime)presentationTimeStamp {
  (void)decoder;
  (void)presentationTimeStamp;
  const auto profile = XMVideoProfileForResolution(self.resolution);
  if (CVPixelBufferGetWidth(pixelBuffer) != profile.width ||
      CVPixelBufferGetHeight(pixelBuffer) != profile.height) {
    self.failure = @"The decoded synthetic frame has the wrong dimensions";
  }
  dispatch_semaphore_signal(self.completion);
}

- (void)h264Decoder:(XMH264Decoder *)decoder didFailWithMessage:(NSString *)message {
  (void)decoder;
  self.failure = message;
  dispatch_semaphore_signal(self.completion);
}

@end

int runCase(XMVideoResolution resolution, unsigned sourceWidth, unsigned sourceHeight,
            OSType pixelFormat) {
  @autoreleasepool {
    XMVideoToolboxTestHarness *harness = [[XMVideoToolboxTestHarness alloc] init];
    harness.resolution = resolution;
    harness.encoder = [[XMH264Encoder alloc] initWithDelegate:harness resolution:resolution];
    NSDictionary *attributes = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferRef pixelBuffer = nullptr;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, sourceWidth, sourceHeight,
                                           pixelFormat,
                                           (__bridge CFDictionaryRef)attributes,
                                           &pixelBuffer);
    if (result != kCVReturnSuccess || pixelBuffer == nullptr) {
      std::fprintf(stderr, "FAIL: Could not create the synthetic video frame\n");
      return 1;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
      for (size_t plane = 0; plane < CVPixelBufferGetPlaneCount(pixelBuffer); ++plane)
        std::memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), plane ? 0x80 : 0x40,
                    CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) *
                    CVPixelBufferGetHeightOfPlane(pixelBuffer, plane));
    } else {
      std::memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x40,
                  CVPixelBufferGetDataSize(pixelBuffer));
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CMVideoFormatDescriptionRef format = nullptr;
    CMSampleBufferRef sampleBuffer = nullptr;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &format);
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), CMTimeMake(0, 30), kCMTimeInvalid};
    if (status == noErr) {
      status = CMSampleBufferCreateReadyWithImageBuffer(
          kCFAllocatorDefault, pixelBuffer, format, &timing, &sampleBuffer);
    }
    CFRelease(pixelBuffer);
    if (format != nullptr) {
      CFRelease(format);
    }
    if (status != noErr || sampleBuffer == nullptr ||
        ![harness.encoder encodeSampleBuffer:sampleBuffer]) {
      if (sampleBuffer != nullptr) {
        CFRelease(sampleBuffer);
      }
      std::fprintf(stderr, "FAIL: Could not submit the synthetic video frame\n");
      return 1;
    }
    // A camera delivering duplicate/too-fast timestamps must not exceed the
    // signaled 30 fps. This second submission should be skipped successfully.
    [harness.encoder encodeSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);

    const long waitResult = dispatch_semaphore_wait(
        harness.completion,
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(10 * NSEC_PER_SEC)));
    [harness.encoder stop];
    [harness.decoder stop];
    if (waitResult != 0) {
      std::fprintf(stderr, "FAIL: Timed out waiting for VideoToolbox\n");
      return 1;
    }
    if (harness.failure != nil) {
      std::fprintf(stderr, "FAIL: %s\n", harness.failure.UTF8String);
      return 1;
    }
    if (harness.encoder.encodedFrameCount != 1) {
      std::fprintf(stderr, "FAIL: duplicate camera timestamp was encoded\n");
      return 1;
    }
    const auto profile = XMVideoProfileForResolution(resolution);
    std::printf("PASS: %ux%u camera input -> %ux%u Baseline level %u\n",
                sourceWidth, sourceHeight, profile.width, profile.height, profile.levelIDC);
  }
  return 0;
}

int main() {
  return runCase(XMVideoResolutionVGA, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ||
         runCase(XMVideoResolutionVGA, 1920, 1080, kCVPixelFormatType_32BGRA) ||
         runCase(XMVideoResolution720p, 640, 480, kCVPixelFormatType_32BGRA) ||
         runCase(XMVideoResolution720p, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}
