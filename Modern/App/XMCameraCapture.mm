#import "XMCameraCapture.h"

@interface XMCameraCapture () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, strong, readwrite) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, readwrite, getter=isPreviewActive) BOOL previewActive;
@property(nonatomic, copy, readwrite) NSString *statusMessage;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property(nonatomic) dispatch_queue_t sessionQueue;
@property(nonatomic) XMVideoResolution resolution;
@property(atomic) BOOL stopped;

@end

@implementation XMCameraCapture

- (instancetype)init {
  return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<XMCameraCaptureDelegate>)delegate {
  return [self initWithDelegate:delegate resolution:XMVideoResolutionVGA];
}

- (instancetype)initWithDelegate:(id<XMCameraCaptureDelegate>)delegate
                     resolution:(XMVideoResolution)resolution {
  if (!XMVideoResolutionIsValid(resolution)) return nil;
  self = [super init];
  if (self != nil) {
    _delegate = delegate;
    _resolution = resolution;
    _session = [[AVCaptureSession alloc] init];
    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _statusMessage = @"Camera preview is unavailable";
    _sessionQueue = dispatch_queue_create("net.sourceforge.xmeeting.camera", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)start {
  AVAuthorizationStatus authorization =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (authorization == AVAuthorizationStatusAuthorized) {
    [self configureAndStartSession];
    return;
  }

  if (authorization == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) {
      if (granted) {
        [self configureAndStartSession];
      } else {
        [self publishAvailability:NO message:@"Camera access was not granted"];
      }
    }];
    return;
  }

  [self publishAvailability:NO message:@"Camera access is disabled in macOS Privacy & Security"];
}

- (void)stop {
  self.stopped = YES;
  // Drain capture callbacks before the application destroys the encoder they
  // use. Shutdown is called by the application on the main thread.
  dispatch_sync(self.sessionQueue, ^{
    [self.videoOutput setSampleBufferDelegate:nil queue:nullptr];
    if (self.session.isRunning) {
      [self.session stopRunning];
    }
    [self publishAvailability:NO message:@"Camera preview is unavailable"];
  });
}

- (void)configureAndStartSession {
  dispatch_async(self.sessionQueue, ^{
    if (self.stopped) return;
    if (self.session.isRunning) {
      [self publishAvailability:YES message:@"Camera preview ready"];
      return;
    }

    AVCaptureDevice *device =
        [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (device == nil) {
      [self publishAvailability:NO message:@"No camera is available"];
      return;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil || error != nil) {
      [self publishAvailability:NO message:@"Could not open the selected camera"];
      return;
    }

    [self.session beginConfiguration];
    for (AVCaptureInput *existingInput in self.session.inputs) {
      [self.session removeInput:existingInput];
    }
    for (AVCaptureOutput *existingOutput in self.session.outputs) {
      [self.session removeOutput:existingOutput];
    }
    self.videoOutput = nil;
    if ([self.session canAddInput:input]) {
      [self.session addInput:input];
    }
    // Query preset support after attaching the actual camera. The encoder
    // still enforces dimensions if the camera supplies another native size.
    AVCaptureSessionPreset preset = self.resolution == XMVideoResolution720p
        ? AVCaptureSessionPreset1280x720 : AVCaptureSessionPreset640x480;
    if ([self.session canSetSessionPreset:preset]) self.session.sessionPreset = preset;
    if (self.session.inputs.count != 0) {
      AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
      output.alwaysDiscardsLateVideoFrames = YES;
      output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      };
      [output setSampleBufferDelegate:self queue:self.sessionQueue];
      if ([self.session canAddOutput:output]) {
        [self.session addOutput:output];
        self.videoOutput = output;
      }
    }
    [self.session commitConfiguration];

    if (self.session.inputs.count == 0 || self.videoOutput == nil) {
      [self publishAvailability:NO message:@"The selected camera cannot be used by XMeeting"];
      return;
    }

    [self.session startRunning];
    [self publishAvailability:self.session.isRunning
                       message:self.session.isRunning ? @"Camera preview ready"
                                                     : @"Could not start the camera preview"];
  });
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  (void)output;
  (void)connection;
  id<XMCameraCaptureDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(cameraCapture:didOutputSampleBuffer:)]) {
    [delegate cameraCapture:self didOutputSampleBuffer:sampleBuffer];
  }
}

- (void)publishAvailability:(BOOL)available message:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.previewActive = available;
    self.statusMessage = message;
    id<XMCameraCaptureDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(cameraCapture:didChangePreviewAvailability:message:)]) {
      [delegate cameraCapture:self didChangePreviewAvailability:available message:message];
    }
  });
}

@end
