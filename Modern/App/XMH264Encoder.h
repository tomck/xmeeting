#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import "XMVideoProfile.h"

NS_ASSUME_NONNULL_BEGIN

@protocol XMH264EncoderDelegate;

// A real-time H.264 Baseline encoder for the native H.323/RTP media bridge.
@interface XMH264Encoder : NSObject

@property(nonatomic, weak, nullable) id<XMH264EncoderDelegate> delegate;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) NSUInteger encodedFrameCount;
@property(nonatomic, readonly) XMVideoResolution resolution;

- (instancetype)initWithDelegate:(nullable id<XMH264EncoderDelegate>)delegate;
- (instancetype)initWithDelegate:(nullable id<XMH264EncoderDelegate>)delegate
                     resolution:(XMVideoResolution)resolution
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (BOOL)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)stop;

@end

@protocol XMH264EncoderDelegate <NSObject>
@optional
// Called by VideoToolbox. Consumers must retain the sample buffer
// before returning if they need it asynchronously.
- (void)h264Encoder:(XMH264Encoder *)encoder
    didEncodeSampleBuffer:(CMSampleBufferRef)sampleBuffer
                 keyFrame:(BOOL)keyFrame;
- (void)h264Encoder:(XMH264Encoder *)encoder
    didEncodeNALUnits:(NSArray<NSData *> *)nalUnits
             keyFrame:(BOOL)keyFrame;
- (void)h264Encoder:(XMH264Encoder *)encoder didFailWithMessage:(NSString *)message;
@end

NS_ASSUME_NONNULL_END
