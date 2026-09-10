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
  if (CVPixelBufferGetWidth(pixelBuffer) != 640 ||
      CVPixelBufferGetHeight(pixelBuffer) != 480) {
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

int main() {
  @autoreleasepool {
    XMVideoToolboxTestHarness *harness = [[XMVideoToolboxTestHarness alloc] init];
    NSDictionary *attributes = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferRef pixelBuffer = nullptr;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480,
                                           kCVPixelFormatType_32BGRA,
                                           (__bridge CFDictionaryRef)attributes,
                                           &pixelBuffer);
    if (result != kCVReturnSuccess || pixelBuffer == nullptr) {
      std::fprintf(stderr, "FAIL: Could not create the synthetic video frame\n");
      return 1;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    std::memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x40,
                CVPixelBufferGetDataSize(pixelBuffer));
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
    std::printf("VideoToolbox H.264 encode/decode test passed\n");
  }
  return 0;
}
