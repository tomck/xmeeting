#import "XMH264Encoder.h"

#include "XMH264RTP.hpp"

#import <VideoToolbox/VideoToolbox.h>

@interface XMH264Encoder ()

@property(nonatomic) VTCompressionSessionRef compressionSession;
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, readwrite) NSUInteger encodedFrameCount;

- (void)handleCompressionStatus:(OSStatus)status sampleBuffer:(nullable CMSampleBufferRef)sampleBuffer;

@end

namespace {

void compressionOutput(void *outputCallbackRefCon,
                       void *sourceFrameRefCon,
                       OSStatus status,
                       VTEncodeInfoFlags infoFlags,
                       CMSampleBufferRef sampleBuffer) {
  (void)sourceFrameRefCon;
  (void)infoFlags;
  XMH264Encoder *encoder = (__bridge XMH264Encoder *)outputCallbackRefCon;
  [encoder handleCompressionStatus:status sampleBuffer:sampleBuffer];
}

NSArray<NSData *> *nalUnitsFromSampleBuffer(CMSampleBufferRef sampleBuffer,
                                            BOOL keyFrame,
                                            NSString **failure) {
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
  if (format == nullptr) {
    *failure = @"The H.264 frame has no format description";
    return nil;
  }

  const uint8_t *firstParameterSet = nullptr;
  size_t firstParameterSetSize = 0;
  size_t parameterSetCount = 0;
  int nalLengthSize = 0;
  OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format, 0, &firstParameterSet, &firstParameterSetSize, &parameterSetCount,
      &nalLengthSize);
  if (status != noErr || nalLengthSize < 1 || nalLengthSize > 4) {
    *failure = @"VideoToolbox did not provide a valid H.264 format description";
    return nil;
  }

  NSMutableArray<NSData *> *result = [NSMutableArray array];
  if (keyFrame) {
    for (size_t index = 0; index < parameterSetCount; ++index) {
      const uint8_t *parameterSet = nullptr;
      size_t parameterSetSize = 0;
      status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, index, &parameterSet, &parameterSetSize, nullptr, nullptr);
      if (status != noErr || parameterSet == nullptr || parameterSetSize == 0) {
        *failure = @"VideoToolbox returned an invalid H.264 parameter set";
        return nil;
      }
      [result addObject:[NSData dataWithBytes:parameterSet length:parameterSetSize]];
    }
  }

  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (blockBuffer == nullptr) {
    *failure = @"The H.264 frame has no encoded data";
    return nil;
  }
  const size_t dataLength = CMBlockBufferGetDataLength(blockBuffer);
  std::vector<std::uint8_t> bytes(dataLength);
  if (CMBlockBufferCopyDataBytes(blockBuffer, 0, dataLength, bytes.data()) != kCMBlockBufferNoErr) {
    *failure = @"The H.264 frame data could not be read";
    return nil;
  }

  xmeeting::media::H264AccessUnit accessUnit;
  std::string error;
  if (!xmeeting::media::parseH264AvccAccessUnit(bytes.data(), bytes.size(),
                                                static_cast<std::size_t>(nalLengthSize),
                                                &accessUnit, &error)) {
    *failure = [NSString stringWithUTF8String:error.c_str()];
    return nil;
  }
  for (const xmeeting::media::H264NalUnit &nal : accessUnit) {
    [result addObject:[NSData dataWithBytes:nal.data() length:nal.size()]];
  }
  return [result copy];
}

}  // namespace

@implementation XMH264Encoder

- (instancetype)init {
  return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<XMH264EncoderDelegate>)delegate {
  self = [super init];
  if (self != nil) {
    _delegate = delegate;
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (imageBuffer == nil) {
    [self reportFailure:@"The camera did not provide a video frame"];
    return NO;
  }

  if (self.compressionSession == nil && ![self createCompressionSessionForImageBuffer:imageBuffer]) {
    return NO;
  }

  CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (!CMTIME_IS_VALID(presentationTime)) {
    presentationTime = CMClockGetTime(CMClockGetHostTimeClock());
  }
  const OSStatus status = VTCompressionSessionEncodeFrame(
      self.compressionSession, imageBuffer, presentationTime, kCMTimeInvalid, nullptr, nullptr, nullptr);
  if (status != noErr) {
    [self reportFailure:@"VideoToolbox could not encode a camera frame"];
    return NO;
  }
  return YES;
}

- (BOOL)createCompressionSessionForImageBuffer:(CVImageBufferRef)imageBuffer {
  const int width = static_cast<int>(CVPixelBufferGetWidth(imageBuffer));
  const int height = static_cast<int>(CVPixelBufferGetHeight(imageBuffer));
  VTCompressionSessionRef session = nullptr;
  const OSStatus createStatus = VTCompressionSessionCreate(
      kCFAllocatorDefault, width, height, kCMVideoCodecType_H264, nullptr, nullptr, nullptr,
      compressionOutput, (__bridge void *)self, &session);
  if (createStatus != noErr || session == nullptr) {
    [self reportFailure:@"VideoToolbox could not create an H.264 encoder"];
    return NO;
  }

  VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                       kVTProfileLevel_H264_Baseline_3_0);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(30));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(512000));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                       (__bridge CFTypeRef)@(60));
  VTCompressionSessionPrepareToEncodeFrames(session);

  self.compressionSession = session;
  self.running = YES;
  return YES;
}

- (void)stop {
  if (self.compressionSession == nullptr) {
    return;
  }
  VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
  VTCompressionSessionInvalidate(self.compressionSession);
  CFRelease(self.compressionSession);
  self.compressionSession = nullptr;
  self.running = NO;
}

- (void)handleCompressionStatus:(OSStatus)status sampleBuffer:(CMSampleBufferRef)sampleBuffer {
  if (status != noErr || sampleBuffer == nil) {
    [self reportFailure:@"VideoToolbox did not produce an H.264 frame"];
    return;
  }

  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  CFDictionaryRef attachment = attachments != nullptr && CFArrayGetCount(attachments) != 0
                                   ? static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0))
                                   : nullptr;
  const BOOL keyFrame = attachment == nullptr ||
                        !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
  self.encodedFrameCount += 1;

  id<XMH264EncoderDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h264Encoder:didEncodeSampleBuffer:keyFrame:)]) {
    [delegate h264Encoder:self didEncodeSampleBuffer:sampleBuffer keyFrame:keyFrame];
  }
  if ([delegate respondsToSelector:@selector(h264Encoder:didEncodeNALUnits:keyFrame:)]) {
    NSString *failure = nil;
    NSArray<NSData *> *nalUnits = nalUnitsFromSampleBuffer(sampleBuffer, keyFrame, &failure);
    if (nalUnits == nil) {
      [self reportFailure:failure ?: @"The H.264 frame could not be packetized"];
      return;
    }
    [delegate h264Encoder:self didEncodeNALUnits:nalUnits keyFrame:keyFrame];
  }
}

- (void)reportFailure:(NSString *)message {
  id<XMH264EncoderDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h264Encoder:didFailWithMessage:)]) {
    [delegate h264Encoder:self didFailWithMessage:message];
  }
}

@end
