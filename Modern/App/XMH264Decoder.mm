#import "XMH264Decoder.h"

#import <VideoToolbox/VideoToolbox.h>

@interface XMH264Decoder ()

@property(nonatomic) VTDecompressionSessionRef decompressionSession;
@property(nonatomic) CMVideoFormatDescriptionRef videoFormat;
@property(nonatomic, strong, nullable) NSData *sequenceParameterSet;
@property(nonatomic, strong, nullable) NSData *pictureParameterSet;
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, readwrite) NSUInteger decodedFrameCount;
@property(nonatomic) dispatch_queue_t decodeQueue;

- (BOOL)prepareSession;
- (void)handleDecodeStatus:(OSStatus)status
               imageBuffer:(nullable CVImageBufferRef)imageBuffer
    presentationTimeStamp:(CMTime)presentationTimeStamp;

@end

namespace {

void decompressionOutput(void *decompressionOutputRefCon,
                         void *sourceFrameRefCon,
                         OSStatus status,
                         VTDecodeInfoFlags infoFlags,
                         CVImageBufferRef imageBuffer,
                         CMTime presentationTimeStamp,
                         CMTime presentationDuration) {
  (void)sourceFrameRefCon;
  (void)infoFlags;
  (void)presentationDuration;
  XMH264Decoder *decoder = (__bridge XMH264Decoder *)decompressionOutputRefCon;
  [decoder handleDecodeStatus:status
                  imageBuffer:imageBuffer
       presentationTimeStamp:presentationTimeStamp];
}

}  // namespace

@implementation XMH264Decoder

- (instancetype)init {
  return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<XMH264DecoderDelegate>)delegate {
  self = [super init];
  if (self != nil) {
    _delegate = delegate;
    _decodeQueue = dispatch_queue_create("net.sourceforge.xmeeting.h264.decode",
                                         DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)decodeNALUnits:(NSArray<NSData *> *)nalUnits
    presentationTimeStamp:(CMTime)presentationTimeStamp {
  NSArray<NSData *> *copiedNALUnits = [[NSArray alloc] initWithArray:nalUnits copyItems:YES];
  dispatch_async(self.decodeQueue, ^{
    NSMutableArray<NSData *> *frameNALUnits = [NSMutableArray array];
    BOOL parameterSetsChanged = NO;
    for (NSData *nal in copiedNALUnits) {
      if (nal.length == 0) {
        continue;
      }
      const uint8_t type = (*static_cast<const uint8_t *>(nal.bytes)) & 0x1f;
      if (type == 7) {
        if (![self.sequenceParameterSet isEqualToData:nal]) {
          self.sequenceParameterSet = nal;
          parameterSetsChanged = YES;
        }
      } else if (type == 8) {
        if (![self.pictureParameterSet isEqualToData:nal]) {
          self.pictureParameterSet = nal;
          parameterSetsChanged = YES;
        }
      } else {
        [frameNALUnits addObject:nal];
      }
    }

    if (parameterSetsChanged) {
      [self invalidateSession];
    }
    if (frameNALUnits.count == 0) {
      return;
    }
    if (![self prepareSession]) {
      return;
    }

    size_t totalLength = 0;
    for (NSData *nal in frameNALUnits) {
      totalLength += 4 + nal.length;
    }
    NSMutableData *avcc = [NSMutableData dataWithCapacity:totalLength];
    for (NSData *nal in frameNALUnits) {
      const uint32_t length = static_cast<uint32_t>(nal.length);
      const uint8_t prefix[4] = {
          static_cast<uint8_t>(length >> 24), static_cast<uint8_t>(length >> 16),
          static_cast<uint8_t>(length >> 8), static_cast<uint8_t>(length)};
      [avcc appendBytes:prefix length:sizeof(prefix)];
      [avcc appendData:nal];
    }

    CMBlockBufferRef blockBuffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, nullptr, avcc.length, kCFAllocatorDefault, nullptr,
        0, avcc.length, 0, &blockBuffer);
    if (status == noErr) {
      status = CMBlockBufferReplaceDataBytes(avcc.bytes, blockBuffer, 0, avcc.length);
    }
    if (status != noErr || blockBuffer == nullptr) {
      if (blockBuffer != nullptr) {
        CFRelease(blockBuffer);
      }
      [self reportFailure:@"A received H.264 frame could not be buffered"];
      return;
    }

    CMSampleTimingInfo timing = {kCMTimeInvalid, presentationTimeStamp, kCMTimeInvalid};
    const size_t sampleSize = avcc.length;
    CMSampleBufferRef sampleBuffer = nullptr;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer,
                                       self.videoFormat, 1, 1, &timing, 1,
                                       &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || sampleBuffer == nullptr) {
      [self reportFailure:@"A received H.264 frame could not be described"];
      return;
    }

    const VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression |
                                     kVTDecodeFrame_1xRealTimePlayback;
    status = VTDecompressionSessionDecodeFrame(self.decompressionSession, sampleBuffer,
                                                flags, nullptr, nullptr);
    CFRelease(sampleBuffer);
    if (status != noErr) {
      [self reportFailure:@"VideoToolbox could not decode a received H.264 frame"];
    }
  });
}

- (BOOL)prepareSession {
  if (self.decompressionSession != nullptr) {
    return YES;
  }
  if (self.sequenceParameterSet.length == 0 || self.pictureParameterSet.length == 0) {
    [self reportFailure:@"Received H.264 video is waiting for SPS and PPS parameter sets"];
    return NO;
  }

  const uint8_t *parameterSetPointers[] = {
      static_cast<const uint8_t *>(self.sequenceParameterSet.bytes),
      static_cast<const uint8_t *>(self.pictureParameterSet.bytes)};
  const size_t parameterSetSizes[] = {self.sequenceParameterSet.length,
                                      self.pictureParameterSet.length};
  OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
      kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4,
      &_videoFormat);
  if (status != noErr || self.videoFormat == nullptr) {
    [self reportFailure:@"VideoToolbox rejected the received H.264 parameter sets"];
    return NO;
  }

  NSDictionary *attributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  VTDecompressionOutputCallbackRecord callback = {decompressionOutput,
                                                    (__bridge void *)self};
  status = VTDecompressionSessionCreate(kCFAllocatorDefault, self.videoFormat,
                                        nullptr, (__bridge CFDictionaryRef)attributes,
                                        &callback, &_decompressionSession);
  if (status != noErr || self.decompressionSession == nullptr) {
    [self invalidateSession];
    [self reportFailure:@"VideoToolbox could not create an H.264 decoder"];
    return NO;
  }
  self.running = YES;
  return YES;
}

- (void)stop {
  dispatch_sync(self.decodeQueue, ^{
    [self invalidateSession];
    self.sequenceParameterSet = nil;
    self.pictureParameterSet = nil;
  });
}

- (void)invalidateSession {
  if (self.decompressionSession != nullptr) {
    VTDecompressionSessionWaitForAsynchronousFrames(self.decompressionSession);
    VTDecompressionSessionInvalidate(self.decompressionSession);
    CFRelease(self.decompressionSession);
    self.decompressionSession = nullptr;
  }
  if (self.videoFormat != nullptr) {
    CFRelease(self.videoFormat);
    self.videoFormat = nullptr;
  }
  self.running = NO;
}

- (void)handleDecodeStatus:(OSStatus)status
               imageBuffer:(CVImageBufferRef)imageBuffer
    presentationTimeStamp:(CMTime)presentationTimeStamp {
  if (status != noErr || imageBuffer == nullptr) {
    [self reportFailure:@"VideoToolbox did not produce a decoded video frame"];
    return;
  }
  self.decodedFrameCount += 1;
  id<XMH264DecoderDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h264Decoder:didDecodePixelBuffer:presentationTimeStamp:)]) {
    [delegate h264Decoder:self
      didDecodePixelBuffer:static_cast<CVPixelBufferRef>(imageBuffer)
      presentationTimeStamp:presentationTimeStamp];
  }
}

- (void)reportFailure:(NSString *)message {
  id<XMH264DecoderDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h264Decoder:didFailWithMessage:)]) {
    [delegate h264Decoder:self didFailWithMessage:message];
  }
}

@end
