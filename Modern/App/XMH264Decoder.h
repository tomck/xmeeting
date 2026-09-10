#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol XMH264DecoderDelegate;

// Decodes the H.264 NAL access units delivered by the H323Plus media bridge.
// SPS and PPS units may be included with any access unit and are retained for
// subsequent frames until the remote encoder changes format.
@interface XMH264Decoder : NSObject

@property(nonatomic, weak, nullable) id<XMH264DecoderDelegate> delegate;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) NSUInteger decodedFrameCount;

- (instancetype)initWithDelegate:(nullable id<XMH264DecoderDelegate>)delegate
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (void)decodeNALUnits:(NSArray<NSData *> *)nalUnits
    presentationTimeStamp:(CMTime)presentationTimeStamp;
- (void)stop;

@end

@protocol XMH264DecoderDelegate <NSObject>
@optional
// Called on VideoToolbox's decode thread. Retain the pixel buffer before
// returning if it will be used asynchronously.
- (void)h264Decoder:(XMH264Decoder *)decoder
    didDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
    presentationTimeStamp:(CMTime)presentationTimeStamp;
- (void)h264Decoder:(XMH264Decoder *)decoder didFailWithMessage:(NSString *)message;
@end

NS_ASSUME_NONNULL_END
