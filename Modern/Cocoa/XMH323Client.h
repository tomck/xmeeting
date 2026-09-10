#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const XMH323ClientErrorDomain;

typedef NS_ERROR_ENUM(XMH323ClientErrorDomain, XMH323ClientErrorCode) {
  XMH323ClientErrorInvalidArgument = 1,
  XMH323ClientErrorNotStarted,
  XMH323ClientErrorListenerFailed,
  XMH323ClientErrorCallFailed,
  XMH323ClientErrorGatekeeperFailed,
  XMH323ClientErrorAudioUnavailable,
  XMH323ClientErrorVideoUnavailable,
};

@class XMH323Client;

@interface XMH323Call : NSObject

@property(nonatomic, copy, readonly) NSString *token;
@property(nonatomic, copy, readonly) NSString *remoteName;
@property(nonatomic, copy, readonly) NSString *remoteNumber;
@property(nonatomic, copy, readonly) NSString *remoteAddress;
@property(nonatomic, copy, readonly) NSString *remoteApplication;
@property(nonatomic, readonly, getter=isIncoming) BOOL incoming;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@protocol XMH323ClientDelegate <NSObject>
@optional
- (void)h323Client:(XMH323Client *)client didReceiveIncomingCall:(XMH323Call *)call;
- (void)h323Client:(XMH323Client *)client didEstablishCall:(XMH323Call *)call;
- (void)h323Client:(XMH323Client *)client
       didEndCall:(XMH323Call *)call
        h323Reason:(NSInteger)h323Reason
         q931Cause:(NSUInteger)q931Cause;
- (void)h323Client:(XMH323Client *)client
    didRegisterWithGatekeeper:(NSString *)gatekeeperAddress;
- (void)h323ClientGatekeeperRegistrationDidFail:(XMH323Client *)client;
- (void)h323Client:(XMH323Client *)client
    didReceiveH264NALUnits:(NSArray<NSData *> *)nalUnits;
- (void)h323Client:(XMH323Client *)client didEncounterError:(NSString *)message;
@end

// Main-thread application facade for the H323Plus engine. Delegate callbacks
// are always delivered on the main queue.
@interface XMH323Client : NSObject {
 @private
  void *_implementation;
}

@property(nonatomic, weak, nullable) id<XMH323ClientDelegate> delegate;
@property(nonatomic, readonly, getter=isStarted) BOOL started;
@property(nonatomic, readonly, getter=isRegisteredWithGatekeeper)
    BOOL registeredWithGatekeeper;
@property(nonatomic, copy, readonly) NSArray<NSString *> *activeCallTokens;
@property(nonatomic, readonly, getter=isAudioAvailable) BOOL audioAvailable;
@property(nonatomic, copy, readonly) NSString *audioInputDevice;
@property(nonatomic, copy, readonly) NSString *audioOutputDevice;
@property(nonatomic, copy, readonly) NSArray<NSString *> *audioCodecs;
// Becomes true only when the H323Plus engine has a usable, advertised video
// codec. Camera permission or a local preview alone must not enable it.
@property(nonatomic, readonly, getter=isVideoAvailable) BOOL videoAvailable;
@property(nonatomic, copy, readonly) NSArray<NSString *> *videoCodecs;

- (instancetype)initWithDelegate:(nullable id<XMH323ClientDelegate>)delegate
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

- (BOOL)startWithUserName:(NSString *)userName
               listenPort:(uint16_t)listenPort
                    error:(NSError *_Nullable *_Nullable)error;
- (void)stop;

- (BOOL)callAddress:(NSString *)address
               token:(NSString *_Nullable *_Nullable)token
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)answerCallWithToken:(NSString *)token
                       error:(NSError *_Nullable *_Nullable)error;
- (BOOL)rejectCallWithToken:(NSString *)token
                       error:(NSError *_Nullable *_Nullable)error;
- (BOOL)hangUpCallWithToken:(NSString *)token
                       error:(NSError *_Nullable *_Nullable)error;

- (BOOL)registerWithGatekeeper:(NSString *)address
                         alias:(NSString *)alias
                      password:(nullable NSString *)password
                         error:(NSError *_Nullable *_Nullable)error;
- (void)unregisterFromGatekeeper;

// The application calls this only after its local VideoToolbox pipeline has
// produced a usable H.264 access unit and its receive renderer is ready.
- (BOOL)enableH264VideoWithError:(NSError *_Nullable *_Nullable)error;
// Returns NO while no negotiated H.323 video transmitter is active; frames
// are deliberately dropped instead of being queued during audio-only calls.
- (BOOL)submitH264NALUnits:(NSArray<NSData *> *)nalUnits;

@end

NS_ASSUME_NONNULL_END
