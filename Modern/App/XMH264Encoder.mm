#import "XMH264Encoder.h"

#include "XMH264RTP.hpp"

#import <VideoToolbox/VideoToolbox.h>

@interface XMH264Encoder ()

@property(nonatomic) VTCompressionSessionRef compressionSession;
@property(nonatomic) VTPixelTransferSessionRef transferSession;
@property(nonatomic) CMTime lastSubmittedTime;
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
  return [self initWithDelegate:delegate resolution:XMVideoResolutionVGA];
}

- (instancetype)initWithDelegate:(id<XMH264EncoderDelegate>)delegate
                     resolution:(XMVideoResolution)resolution {
  if (!XMVideoResolutionIsValid(resolution)) return nil;
  self = [super init];
  if (self != nil) {
    _delegate = delegate;
    _resolution = resolution;
    _lastSubmittedTime = kCMTimeInvalid;
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
  const XMVideoProfile profile = XMVideoProfileForResolution(self.resolution);
  if (CMTIME_IS_NUMERIC(self.lastSubmittedTime)) {
    const double elapsed = CMTimeGetSeconds(CMTimeSubtract(presentationTime, self.lastSubmittedTime));
    if (elapsed >= 0 && elapsed + 0.00001 < 1.0 / profile.framesPerSecond) return YES;
  }

  // Camera presets are requests, not an output-size guarantee (including for
  // virtual cameras). Normalize every input into the selected encoder format.
  CVPixelBufferRef output = nullptr;
  CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(self.compressionSession);
  if (pool == nullptr || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) != kCVReturnSuccess) {
    [self reportFailure:@"Could not allocate the selected video output size"];
    return NO;
  }
  const OSStatus transferStatus = VTPixelTransferSessionTransferImage(self.transferSession, imageBuffer, output);
  if (transferStatus != noErr) {
    CFRelease(output);
    [self reportFailure:@"Could not resize the camera frame for video output"];
    return NO;
  }
  CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey);
  CVBufferRemoveAttachment(output, kCVImageBufferPixelAspectRatioKey);
  const OSStatus status = VTCompressionSessionEncodeFrame(
      self.compressionSession, output, presentationTime,
      CMTimeMake(1, profile.framesPerSecond), nullptr, nullptr, nullptr);
  CFRelease(output);
  if (status != noErr) {
    [self reportFailure:@"VideoToolbox could not encode a camera frame"];
    return NO;
  }
  self.lastSubmittedTime = presentationTime;
  return YES;
}

- (BOOL)createCompressionSessionForImageBuffer:(CVImageBufferRef)imageBuffer {
  (void)imageBuffer;
  const XMVideoProfile profile = XMVideoProfileForResolution(self.resolution);
  NSDictionary *attributes = @{
    (id)kCVPixelBufferWidthKey: @(profile.width),
    (id)kCVPixelBufferHeightKey: @(profile.height),
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  VTCompressionSessionRef session = nullptr;
  const OSStatus createStatus = VTCompressionSessionCreate(
      kCFAllocatorDefault, profile.width, profile.height, kCMVideoCodecType_H264,
      nullptr, (__bridge CFDictionaryRef)attributes, nullptr,
      compressionOutput, (__bridge void *)self, &session);
  if (createStatus != noErr || session == nullptr) {
    [self reportFailure:@"VideoToolbox could not create an H.264 encoder"];
    return NO;
  }

  CFStringRef level = self.resolution == XMVideoResolution720p
                         ? kVTProfileLevel_H264_Baseline_3_1 : kVTProfileLevel_H264_Baseline_3_0;
  NSDictionary *properties = @{
    (id)kVTCompressionPropertyKey_RealTime: @YES,
    (id)kVTCompressionPropertyKey_ProfileLevel: (__bridge id)level,
    (id)kVTCompressionPropertyKey_AllowFrameReordering: @NO,
    (id)kVTCompressionPropertyKey_ExpectedFrameRate: @(profile.framesPerSecond),
    (id)kVTCompressionPropertyKey_AverageBitRate: @(profile.bitRate),
    (id)kVTCompressionPropertyKey_MaxKeyFrameInterval: @(profile.framesPerSecond * 2),
    (id)kVTCompressionPropertyKey_DataRateLimits: @[@(profile.bitRate / 8), @1],
  };
  self.compressionSession = session;
  if (VTSessionSetProperties(session, (__bridge CFDictionaryRef)properties) != noErr ||
      VTCompressionSessionPrepareToEncodeFrames(session) != noErr ||
      VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transferSession) != noErr ||
      VTSessionSetProperty(self.transferSession, kVTPixelTransferPropertyKey_ScalingMode,
                           kVTScalingMode_Letterbox) != noErr) {
    [self stop];
    [self reportFailure:@"VideoToolbox could not configure the selected video format"];
    return NO;
  }
  self.running = YES;
  return YES;
}

- (void)stop {
  self.lastSubmittedTime = kCMTimeInvalid;
  if (self.transferSession != nullptr) {
    VTPixelTransferSessionInvalidate(self.transferSession);
    CFRelease(self.transferSession);
    self.transferSession = nullptr;
  }
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

  const XMVideoProfile profile = XMVideoProfileForResolution(self.resolution);
  const CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(
      CMSampleBufferGetFormatDescription(sampleBuffer));
  if (size.width != profile.width || size.height != profile.height) {
    [self reportFailure:@"The encoder output does not match the selected video resolution"];
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
