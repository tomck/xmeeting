#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol XMCameraCaptureDelegate;

// Owns the macOS camera session used for local preview today and the raw-frame
// handoff to the H.264 bridge later. It deliberately does not make H.323
// capability decisions; a camera alone is not sufficient to advertise video.
@interface XMCameraCapture : NSObject

@property(nonatomic, weak, nullable) id<XMCameraCaptureDelegate> delegate;
@property(nonatomic, strong, readonly) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, readonly, getter=isPreviewActive) BOOL previewActive;
@property(nonatomic, copy, readonly) NSString *statusMessage;

- (instancetype)initWithDelegate:(nullable id<XMCameraCaptureDelegate>)delegate
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (void)start;
- (void)stop;

@end

@protocol XMCameraCaptureDelegate <NSObject>
@optional
- (void)cameraCapture:(XMCameraCapture *)capture
    didChangePreviewAvailability:(BOOL)available
                         message:(NSString *)message;
// Called on the capture queue. The sample buffer is owned by AVFoundation and
// must be retained by a consumer that needs it after this method returns.
- (void)cameraCapture:(XMCameraCapture *)capture
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

NS_ASSUME_NONNULL_END
