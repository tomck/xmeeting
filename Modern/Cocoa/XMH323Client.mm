#import "XMH323Client.h"

#include "XMH323PlusEngine.hpp"

#pragma push_macro("nil")
#undef nil
#include <ptlib.h>
#include <ptlib/pprocess.h>
#pragma pop_macro("nil")

// PTLib provides this macro for pre-Objective-C compatibility. Keep it from
// changing Cocoa method signatures in the remainder of this translation unit.
#ifdef BOOL
#undef BOOL
#endif

#include <memory>
#include <mutex>
#include <string>

NSErrorDomain const XMH323ClientErrorDomain = @"net.sourceforge.xmeeting.H323Client";

@interface XMH323Call ()

@property(nonatomic, copy, readwrite) NSString *token;
@property(nonatomic, copy, readwrite) NSString *remoteName;
@property(nonatomic, copy, readwrite) NSString *remoteNumber;
@property(nonatomic, copy, readwrite) NSString *remoteAddress;
@property(nonatomic, copy, readwrite) NSString *remoteApplication;
@property(nonatomic, readwrite, getter=isIncoming) BOOL incoming;

- (instancetype)initWithToken:(NSString *)token
                    remoteName:(NSString *)remoteName
                  remoteNumber:(NSString *)remoteNumber
                 remoteAddress:(NSString *)remoteAddress
             remoteApplication:(NSString *)remoteApplication
                      incoming:(BOOL)incoming;

@end

@interface XMH323Client ()

@property(nonatomic, readwrite, getter=isStarted) BOOL started;

- (void *)xm_implementation;
- (void)xm_deliverIncomingCall:(XMH323Call *)call;
- (void)xm_deliverEstablishedCall:(XMH323Call *)call;
- (void)xm_deliverEndedCall:(XMH323Call *)call
                 h323Reason:(NSInteger)h323Reason
                  q931Cause:(NSUInteger)q931Cause;
- (void)xm_deliverGatekeeperRegistration:(NSString *)address;
- (void)xm_deliverGatekeeperRegistrationFailure;
- (void)xm_deliverError:(NSString *)message;

@end

namespace {

using xmeeting::h323::CallEndedInfo;
using xmeeting::h323::CallInfo;
using xmeeting::h323::EventSink;
using xmeeting::h323::H323PlusEngine;

class XMH323Process final : public PProcess {
  PCLASSINFO(XMH323Process, PProcess);

 public:
  XMH323Process() : PProcess("XMeeting", "XMeeting", 1, 0, AlphaCode, 0) {}
  void Main() override {}
};

void ensurePTLibIsInitialised() {
  static std::once_flag initialisationFlag;
  std::call_once(initialisationFlag, [] {
    static XMH323Process *process = new XMH323Process;
    static char processName[] = "XMeeting";
    static char *arguments[] = {processName, nullptr};
    process->PreInitialise(1, arguments, nullptr);
    (void)process;
  });
}

NSString *stringFromStdString(const std::string &value) {
  NSString *string = [[NSString alloc] initWithBytes:value.data()
                                              length:value.size()
                                            encoding:NSUTF8StringEncoding];
  return string ?: @"";
}

std::string stdStringFromString(NSString *value) {
  const char *utf8 = value.UTF8String;
  return utf8 == nullptr ? std::string() : std::string(utf8);
}

XMH323Call *callFromCallInfo(const CallInfo &info) {
  return [[XMH323Call alloc] initWithToken:stringFromStdString(info.token)
                                remoteName:stringFromStdString(info.remoteName)
                              remoteNumber:stringFromStdString(info.remoteNumber)
                             remoteAddress:stringFromStdString(info.remoteAddress)
                         remoteApplication:stringFromStdString(info.remoteApplication)
                                  incoming:info.incoming];
}

void dispatchOnMainQueue(dispatch_block_t block) {
  if (NSThread.isMainThread) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

BOOL fail(NSError **error, XMH323ClientErrorCode code, NSString *description) {
  if (error != nullptr) {
    *error = [NSError errorWithDomain:XMH323ClientErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey : description}];
  }
  return NO;
}

class CocoaEventSink final : public EventSink {
 public:
  explicit CocoaEventSink(XMH323Client *owner) : owner_(owner) {}

  void onIncomingCall(const CallInfo &info) override {
    @autoreleasepool {
      XMH323Call *call = callFromCallInfo(info);
      __weak XMH323Client *owner = owner_;
      dispatchOnMainQueue(^{
        [owner xm_deliverIncomingCall:call];
      });
    }
  }

  void onCallEstablished(const CallInfo &info) override {
    @autoreleasepool {
      XMH323Call *call = callFromCallInfo(info);
      __weak XMH323Client *owner = owner_;
      dispatchOnMainQueue(^{
        [owner xm_deliverEstablishedCall:call];
      });
    }
  }

  void onCallEnded(const CallEndedInfo &info) override {
    @autoreleasepool {
      XMH323Call *call = callFromCallInfo(info.call);
      const NSInteger h323Reason = info.h323Reason;
      const NSUInteger q931Cause = info.q931Cause;
      __weak XMH323Client *owner = owner_;
      dispatchOnMainQueue(^{
        [owner xm_deliverEndedCall:call h323Reason:h323Reason q931Cause:q931Cause];
      });
    }
  }

  void onGatekeeperRegistered(const std::string &address) override {
    @autoreleasepool {
      NSString *gatekeeperAddress = stringFromStdString(address);
      __weak XMH323Client *owner = owner_;
      dispatchOnMainQueue(^{
        [owner xm_deliverGatekeeperRegistration:gatekeeperAddress];
      });
    }
  }

  void onGatekeeperRegistrationFailed() override {
    __weak XMH323Client *owner = owner_;
    dispatchOnMainQueue(^{
      [owner xm_deliverGatekeeperRegistrationFailure];
    });
  }

  void onError(const std::string &message) override {
    @autoreleasepool {
      NSString *errorMessage = stringFromStdString(message);
      __weak XMH323Client *owner = owner_;
      dispatchOnMainQueue(^{
        [owner xm_deliverError:errorMessage];
      });
    }
  }

 private:
  __weak XMH323Client *owner_;
};

struct CocoaClientImplementation {
  explicit CocoaClientImplementation(XMH323Client *owner) : sink(owner), engine(sink) {}

  CocoaEventSink sink;
  H323PlusEngine engine;
};

CocoaClientImplementation *implementation(XMH323Client *client) {
  return static_cast<CocoaClientImplementation *>([client xm_implementation]);
}

}  // namespace

@implementation XMH323Call

- (instancetype)initWithToken:(NSString *)token
                    remoteName:(NSString *)remoteName
                  remoteNumber:(NSString *)remoteNumber
                 remoteAddress:(NSString *)remoteAddress
             remoteApplication:(NSString *)remoteApplication
                      incoming:(BOOL)incoming {
  self = [super init];
  if (self != nil) {
    _token = [token copy];
    _remoteName = [remoteName copy];
    _remoteNumber = [remoteNumber copy];
    _remoteAddress = [remoteAddress copy];
    _remoteApplication = [remoteApplication copy];
    _incoming = incoming;
  }
  return self;
}

@end

@implementation XMH323Client

- (instancetype)init {
  return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<XMH323ClientDelegate>)delegate {
  self = [super init];
  if (self != nil) {
    ensurePTLibIsInitialised();
    _delegate = delegate;
    _implementation = new CocoaClientImplementation(self);
  }
  return self;
}

- (void)dealloc {
  if (_implementation != nullptr) {
    implementation(self)->engine.stop();
    delete implementation(self);
    _implementation = nullptr;
  }
}

- (void *)xm_implementation {
  return _implementation;
}

- (BOOL)startWithUserName:(NSString *)userName
               listenPort:(uint16_t)listenPort
                    error:(NSError **)error {
  if (userName.length == 0 || listenPort == 0) {
    return fail(error, XMH323ClientErrorInvalidArgument,
                @"An H.323 user name and nonzero listener port are required.");
  }
  if (self.started) {
    return YES;
  }

  if (!implementation(self)->engine.start(stdStringFromString(userName), listenPort)) {
    return fail(error, XMH323ClientErrorListenerFailed,
                @"The H.323 listener could not be started.");
  }
  self.started = YES;
  return YES;
}

- (void)stop {
  if (_implementation != nullptr) {
    implementation(self)->engine.stop();
  }
  self.started = NO;
}

- (BOOL)callAddress:(NSString *)address
               token:(NSString **)token
               error:(NSError **)error {
  if (!self.started) {
    return fail(error, XMH323ClientErrorNotStarted, @"The H.323 client is not started.");
  }
  if (address.length == 0) {
    return fail(error, XMH323ClientErrorInvalidArgument, @"A call address is required.");
  }
  if ([address rangeOfString:@"sip:"
                     options:(NSAnchoredSearch | NSCaseInsensitiveSearch)]
          .location != NSNotFound) {
    return fail(error, XMH323ClientErrorInvalidArgument,
                @"This XMeeting build supports H.323 addresses only.");
  }

  std::string returnedToken;
  if (!implementation(self)->engine.call(stdStringFromString(address), &returnedToken)) {
    return fail(error, XMH323ClientErrorCallFailed, @"The H.323 call could not be started.");
  }
  if (token != nullptr) {
    *token = stringFromStdString(returnedToken);
  }
  return YES;
}

- (BOOL)answerCallWithToken:(NSString *)token error:(NSError **)error {
  if (!self.started) {
    return fail(error, XMH323ClientErrorNotStarted, @"The H.323 client is not started.");
  }
  if (token.length == 0 || !implementation(self)->engine.answer(stdStringFromString(token))) {
    return fail(error, XMH323ClientErrorCallFailed, @"The incoming call could not be answered.");
  }
  return YES;
}

- (BOOL)rejectCallWithToken:(NSString *)token error:(NSError **)error {
  if (!self.started) {
    return fail(error, XMH323ClientErrorNotStarted, @"The H.323 client is not started.");
  }
  if (token.length == 0 || !implementation(self)->engine.reject(stdStringFromString(token))) {
    return fail(error, XMH323ClientErrorCallFailed, @"The incoming call could not be rejected.");
  }
  return YES;
}

- (BOOL)hangUpCallWithToken:(NSString *)token error:(NSError **)error {
  if (!self.started) {
    return fail(error, XMH323ClientErrorNotStarted, @"The H.323 client is not started.");
  }
  if (token.length == 0 || !implementation(self)->engine.hangUp(stdStringFromString(token))) {
    return fail(error, XMH323ClientErrorCallFailed, @"The H.323 call could not be cleared.");
  }
  return YES;
}

- (BOOL)registerWithGatekeeper:(NSString *)address
                         alias:(NSString *)alias
                      password:(NSString *)password
                         error:(NSError **)error {
  if (!self.started) {
    return fail(error, XMH323ClientErrorNotStarted, @"The H.323 client is not started.");
  }
  if (address.length == 0) {
    return fail(error, XMH323ClientErrorInvalidArgument,
                @"A gatekeeper address is required.");
  }

  if (!implementation(self)->engine.registerWithGatekeeper(
          stdStringFromString(address), stdStringFromString(alias),
          stdStringFromString(password ?: @""))) {
    return fail(error, XMH323ClientErrorGatekeeperFailed,
                @"Gatekeeper registration could not be started.");
  }
  return YES;
}

- (void)unregisterFromGatekeeper {
  implementation(self)->engine.unregisterFromGatekeeper();
}

- (BOOL)isRegisteredWithGatekeeper {
  return implementation(self)->engine.isRegisteredWithGatekeeper();
}

- (NSArray<NSString *> *)activeCallTokens {
  const std::vector<std::string> tokens = implementation(self)->engine.activeCallTokens();
  NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:tokens.size()];
  for (const std::string &token : tokens) {
    [result addObject:stringFromStdString(token)];
  }
  return [result copy];
}

- (void)xm_deliverIncomingCall:(XMH323Call *)call {
  id<XMH323ClientDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h323Client:didReceiveIncomingCall:)]) {
    [delegate h323Client:self didReceiveIncomingCall:call];
  }
}

- (void)xm_deliverEstablishedCall:(XMH323Call *)call {
  id<XMH323ClientDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h323Client:didEstablishCall:)]) {
    [delegate h323Client:self didEstablishCall:call];
  }
}

- (void)xm_deliverEndedCall:(XMH323Call *)call
                 h323Reason:(NSInteger)h323Reason
                  q931Cause:(NSUInteger)q931Cause {
  id<XMH323ClientDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h323Client:didEndCall:h323Reason:q931Cause:)]) {
    [delegate h323Client:self
              didEndCall:call
              h323Reason:h323Reason
               q931Cause:q931Cause];
  }
}

- (void)xm_deliverGatekeeperRegistration:(NSString *)address {
  id<XMH323ClientDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h323Client:didRegisterWithGatekeeper:)]) {
    [delegate h323Client:self didRegisterWithGatekeeper:address];
  }
}

- (void)xm_deliverGatekeeperRegistrationFailure {
  id<XMH323ClientDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h323ClientGatekeeperRegistrationDidFail:)]) {
    [delegate h323ClientGatekeeperRegistrationDidFail:self];
  }
}

- (void)xm_deliverError:(NSString *)message {
  id<XMH323ClientDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(h323Client:didEncounterError:)]) {
    [delegate h323Client:self didEncounterError:message];
  }
}

@end
