#import "XMH264Decoder.h"
#import "XMH264Encoder.h"
#include "XMH323PlusEngine.hpp"
#include "XMTestAudio.hpp"

#pragma push_macro("nil")
#undef nil
#include <ptlib.h>
#include <ptlib/pprocess.h>
#pragma pop_macro("nil")
#ifdef BOOL
#undef BOOL
#endif

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <unistd.h>

using namespace xmeeting::h323;

@interface XMCallVideoHarness : NSObject <XMH264EncoderDelegate, XMH264DecoderDelegate> {
 @public
  std::mutex mutex;
  H264AccessUnit encoded;
  std::atomic<unsigned> decodedFrames;
  std::atomic<unsigned> errors;
}
@property(nonatomic, strong) XMH264Encoder *encoder;
@property(nonatomic, strong) XMH264Decoder *decoder;
@property(nonatomic) XMVideoResolution resolution;
@property(nonatomic) XMVideoResolution receiveResolution;
@end

@implementation XMCallVideoHarness
- (instancetype)init {
  self = [super init];
  if (self) {
    decodedFrames = 0;
    errors = 0;
    _encoder = [[XMH264Encoder alloc] initWithDelegate:self];
    _decoder = [[XMH264Decoder alloc] initWithDelegate:self];
  }
  return self;
}
- (void)h264Encoder:(XMH264Encoder *)encoder
    didEncodeNALUnits:(NSArray<NSData *> *)nalUnits keyFrame:(BOOL)keyFrame {
  (void)encoder;
  if (!keyFrame) return;
  std::lock_guard<std::mutex> lock(mutex);
  encoded.clear();
  for (NSData *nal in nalUnits) {
    const auto *bytes = static_cast<const uint8_t *>(nal.bytes);
    encoded.emplace_back(bytes, bytes + nal.length);
  }
}
- (void)h264Encoder:(XMH264Encoder *)encoder didFailWithMessage:(NSString *)message {
  (void)encoder;
  ++errors;
  std::fprintf(stderr, "Encoder: %s\n", message.UTF8String);
}
- (void)h264Decoder:(XMH264Decoder *)decoder
    didDecodePixelBuffer:(CVPixelBufferRef)buffer presentationTimeStamp:(CMTime)time {
  (void)decoder;
  (void)time;
  const auto profile = XMVideoProfileForResolution(self.receiveResolution);
  if (CVPixelBufferGetWidth(buffer) != profile.width || CVPixelBufferGetHeight(buffer) != profile.height) {
    ++errors;
  } else {
    ++decodedFrames;
  }
}
- (void)h264Decoder:(XMH264Decoder *)decoder didFailWithMessage:(NSString *)message {
  (void)decoder;
  ++errors;
  std::fprintf(stderr, "Decoder: %s\n", message.UTF8String);
}
@end

namespace {
class TestProcess final : public PProcess {
  PCLASSINFO(TestProcess, PProcess);
 public:
  TestProcess() : PProcess("XMeeting", "H264CallTests", 0, 1, ReleaseCode, 0) {}
  void Main() override {}
};

class Sink final : public EventSink {
 public:
  explicit Sink(XMCallVideoHarness *value) : harness(value) {}
  void onIncomingCall(const CallInfo& info) override {
    std::lock_guard<std::mutex> lock(mutex);
    incoming = info.token;
  }
  void onCallEstablished(const CallInfo& info) override {
    negotiatedFastStart = info.fastStart;
    ++established;
  }
  void onCallEnded(const CallEndedInfo& info) override {
    std::printf("Call cleared: reason=%d cause=%u\n", info.h323Reason, info.q931Cause);
    ++ended;
  }
  void onAudioChannelStarted(const AudioChannelInfo&) override { ++audio; }
  void onH264AccessUnit(const H264AccessUnit& unit) override {
    @autoreleasepool {
      NSMutableArray<NSData *> *nals = [NSMutableArray array];
      for (const auto& nal : unit) {
        [nals addObject:[NSData dataWithBytes:nal.data() length:nal.size()]];
      }
      const unsigned index = ++received;
      [harness.decoder decodeNALUnits:nals presentationTimeStamp:CMTimeMake(index, 30)];
    }
  }
  void onError(const std::string& message) override {
    ++errors;
    std::fprintf(stderr, "H.323: %s\n", message.c_str());
  }
  std::string takeIncoming() {
    std::lock_guard<std::mutex> lock(mutex);
    std::string result;
    result.swap(incoming);
    return result;
  }
  __strong XMCallVideoHarness *harness;
  std::atomic<unsigned> established{0}, ended{0}, received{0}, audio{0}, errors{0};
  std::atomic<bool> negotiatedFastStart{false};
 private:
  std::mutex mutex;
  std::string incoming;
};

bool prepareVideo(XMCallVideoHarness *harness) {
  CVPixelBufferRef pixels = nullptr;
  NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
                         (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess)
    return false;
  CVPixelBufferLockBaseAddress(pixels, 0);
  auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixels));
  // Detailed deterministic content forces FU-A fragmentation of the IDR.
  for (unsigned y = 0; y < 480; ++y) {
    auto *row = base + y * CVPixelBufferGetBytesPerRow(pixels);
    for (unsigned x = 0; x < 640; ++x) {
      row[4*x] = (x * 13 + y * 7) & 255;
      row[4*x+1] = (x + y) & 255;
      row[4*x+2] = (x ^ y) & 255;
      row[4*x+3] = 255;
    }
  }
  CVPixelBufferUnlockBaseAddress(pixels, 0);
  CMVideoFormatDescriptionRef format = nullptr;
  CMSampleBufferRef sample = nullptr;
  CMSampleTimingInfo timing = {CMTimeMake(1, 30), kCMTimeZero, kCMTimeInvalid};
  OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &format);
  if (status == noErr)
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, format, &timing, &sample);
  const bool ok = status == noErr && [harness.encoder encodeSampleBuffer:sample];
  if (sample) CFRelease(sample);
  if (format) CFRelease(format);
  CFRelease(pixels);
  [harness.encoder stop]; // Drains output so encoded is ready before callers use it.
  std::lock_guard<std::mutex> lock(harness->mutex);
  return ok && !harness->encoded.empty() && harness->errors == 0;
}

bool runCall(H323PlusEngine& caller, H323PlusEngine& callee, Sink& a, Sink& b,
             const std::string& address, unsigned round, bool localPeer, bool audioOnly, bool controls) {
  if (controls && (!caller.microphoneMuted() || caller.videoTransmissionEnabled())) return false;
  xmeeting::test::resetAudioSamples();
  std::string token;
  if (!caller.call(address, &token)) return false;
  const unsigned startA = a.harness->decodedFrames, startB = b.harness->decodedFrames;
  const unsigned receivedB = b.received;
  unsigned sentA = 0, sentB = 0;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto incoming = b.takeIncoming();
    if (!incoming.empty()) {
      // Ringing is not acceptance. Fast Start must not establish the call or
      // start microphone/speaker channels before the receiving user answers.
      std::this_thread::sleep_for(std::chrono::milliseconds(150));
      if (a.established >= round || b.established >= round ||
          a.audio > (round - 1) * 2 || b.audio > (round - 1) * 2) {
        std::fprintf(stderr, "FAIL: media started before the incoming call was accepted\n");
        return false;
      }
      if (!callee.answer(incoming)) return false;
    }
    sentA += caller.submitH264AccessUnit(a.harness->encoded);
    if (localPeer) sentB += callee.submitH264AccessUnit(b.harness->encoded);
    if ((audioOnly || (a.harness->decodedFrames >= startA + 10 &&
        (!localPeer || controls || b.harness->decodedFrames >= startB + 10))) &&
        a.established >= round && (!localPeer || b.established >= round) &&
        a.audio >= round * 2 && (!localPeer || b.audio >= round * 2)) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(34));
  }
  bool mediaOK = (audioOnly || (a.harness->decodedFrames >= startA + 10 &&
                       (controls || ((!localPeer || b.harness->decodedFrames >= startB + 10) && sentA >= 10)))) &&
                       a.established >= round && (!localPeer || b.established >= round) &&
                       a.audio >= round * 2 && (!localPeer || b.audio >= round * 2) &&
                       a.errors == 0 && b.errors == 0 &&
                       a.harness->errors == 0 && b.harness->errors == 0;
  std::printf("Round %u: sent=%u/%u decoded=%u/%u established=%u/%u audio=%u/%u\n",
              round, sentA, sentB, a.harness->decodedFrames.load() - startA,
              b.harness->decodedFrames.load() - startB, a.established.load(),
              b.established.load(), a.audio.load(), b.audio.load());
  const bool expectedFastStart = caller.fastStartEnabled() && callee.fastStartEnabled();
  const bool negotiationOK = !localPeer ||
      (a.negotiatedFastStart == expectedFastStart && b.negotiatedFastStart == expectedFastStart);
  std::printf("Fast Start: caller=%d callee=%d expected=%d\n",
              (int)a.negotiatedFastStart, (int)b.negotiatedFastStart, expectedFastStart);
  if (controls && mediaOK) {
    auto pump = [&](unsigned milliseconds) {
      const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
      while (std::chrono::steady_clock::now() < until) {
        caller.submitH264AccessUnit(a.harness->encoded);
        callee.submitH264AccessUnit(b.harness->encoded);
        std::this_thread::sleep_for(std::chrono::milliseconds(34));
      }
    };
    pump(350);
    auto initial = xmeeting::test::audioSamples(false);
    mediaOK = initial.blocks > 0 && initial.audibleBlocks == 0 && b.received == receivedB && sentA == 0;
    // Test each direction at the far endpoint after allowing in-flight RTP to drain.
    caller.setMicrophoneMuted(false); caller.setVideoTransmissionEnabled(true);
    for (bool controlCaller : {true, false}) {
      H323PlusEngine& controlled = controlCaller ? caller : callee;
      Sink& receiver = controlCaller ? b : a;
      Sink& otherReceiver = controlCaller ? a : b;
      pump(700);
      controlled.setMicrophoneMuted(true); controlled.setVideoTransmissionEnabled(false);
      pump(700);
      const unsigned pausedFrames = receiver.received, otherFrames = otherReceiver.received;
      const unsigned pausedDecoded = receiver.harness->decodedFrames;
      xmeeting::test::resetAudioSamples();
      pump(700);
      const auto muted = xmeeting::test::audioSamples(!controlCaller);
      const auto opposite = xmeeting::test::audioSamples(controlCaller);
      mediaOK &= muted.blocks > 0 && muted.audibleBlocks == 0 && receiver.received == pausedFrames &&
                 opposite.audibleBlocks > 0 && otherReceiver.received > otherFrames;
      controlled.setMicrophoneMuted(false); controlled.setVideoTransmissionEnabled(true);
      xmeeting::test::resetAudioSamples();
      const auto resumeDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
      do { pump(100); }
      while ((receiver.harness->decodedFrames < pausedDecoded + 10 ||
              xmeeting::test::audioSamples(!controlCaller).audibleBlocks == 0) &&
             std::chrono::steady_clock::now() < resumeDeadline);
      const auto resumed = xmeeting::test::audioSamples(!controlCaller);
      mediaOK &= resumed.audibleBlocks > 0 && receiver.received >= pausedFrames + 10 &&
                 receiver.harness->decodedFrames >= pausedDecoded + 10;
      std::printf("Controls %s: silent blocks=%llu audible=%llu resumed=%llu video resumed=%u\n",
          controlCaller ? "caller" : "callee", (unsigned long long)muted.blocks,
          (unsigned long long)muted.audibleBlocks, (unsigned long long)resumed.audibleBlocks,
          receiver.received.load() - pausedFrames);
    }
    // Hanging up while camera-off must unblock workers, and redial must keep
    // the user's privacy selections without briefly transmitting live media.
    caller.setMicrophoneMuted(true); caller.setVideoTransmissionEnabled(false);
  }
  const bool protectedSettings = !caller.setFastStartEnabled(false) &&
      !caller.configureAudioDevices("NullAudio", "Null Audio", "Null Audio");
  caller.hangUp(token);
  const auto clearDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while ((a.ended < round || (localPeer && b.ended < round)) && std::chrono::steady_clock::now() < clearDeadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  [a.harness.decoder stop];
  [b.harness.decoder stop];
  return mediaOK && negotiationOK && protectedSettings && a.ended >= round && (!localPeer || b.ended >= round) &&
         a.errors == 0 && b.errors == 0 && a.harness->errors == 0 && b.harness->errors == 0;
}
} // namespace

int main(int argc, char **argv) {
  @autoreleasepool {
    TestProcess process;
    process.PreInitialise(argc, argv, nullptr);
    std::string peer;
    XMVideoResolution resolution = XMVideoResolutionVGA;
    bool mixed = false, controls = false;
    bool callerFastStart = true, calleeFastStart = true, audioOnly = false;
    for (int i = 1; i < argc; ++i) {
      if (std::strcmp(argv[i], "--trace") == 0) PTrace::Initialise(4);
      else if (std::strcmp(argv[i], "--720p") == 0) resolution = XMVideoResolution720p;
      else if (std::strcmp(argv[i], "--mixed") == 0) mixed = true;
      else if (std::strcmp(argv[i], "--no-fast-start") == 0) callerFastStart = calleeFastStart = false;
      else if (std::strcmp(argv[i], "--slow-callee") == 0) calleeFastStart = false;
      else if (std::strcmp(argv[i], "--slow-caller") == 0) callerFastStart = false;
      else if (std::strcmp(argv[i], "--audio-only") == 0) audioOnly = true;
      else if (std::strcmp(argv[i], "--controls") == 0) controls = true;
      else if (std::strcmp(argv[i], "--peer") == 0 && i+1 < argc) peer = argv[++i];
      else { std::fprintf(stderr, "Usage: xmeeting-h264-call-tests [--trace] [--720p] [--mixed] [--audio-only|--controls] [--no-fast-start|--slow-caller|--slow-callee] [--peer host:port]\n"); return 2; }
    }
    if (controls && (audioOnly || !peer.empty())) return 2;
    XMCallVideoHarness *a = [[XMCallVideoHarness alloc] init];
    XMCallVideoHarness *b = [[XMCallVideoHarness alloc] init];
    a.resolution = resolution;
    b.resolution = mixed ? (resolution == XMVideoResolutionVGA ? XMVideoResolution720p : XMVideoResolutionVGA) : resolution;
    a.receiveResolution = b.resolution;
    b.receiveResolution = a.resolution;
    a.encoder = [[XMH264Encoder alloc] initWithDelegate:a resolution:a.resolution];
    b.encoder = [[XMH264Encoder alloc] initWithDelegate:b resolution:b.resolution];
    if (!prepareVideo(a) || !prepareVideo(b)) {
      std::fprintf(stderr, "FAIL: could not encode synthetic H.264 video\n");
      return 1;
    }
    Sink sinkA(a), sinkB(b);
    H323PlusEngine caller(sinkA), callee(sinkB);
    if (controls) { caller.setMicrophoneMuted(true); caller.setVideoTransmissionEnabled(false); }
    if (!caller.fastStartEnabled() || !callee.fastStartEnabled() ||
        !caller.setFastStartEnabled(callerFastStart) || !callee.setFastStartEnabled(calleeFastStart)) return 1;
    const unsigned port = 30000 + (getpid() % 10000) * 2;
    const bool localPeer = peer.empty();
    if (localPeer) peer = "127.0.0.1:" + std::to_string(port + 1);
    bool ok = caller.configureAudioDevices(controls ? "XMeetingTestAudio" : "NullAudio",
                  controls ? "Caller" : "Null Audio", controls ? "Caller" : "Null Audio") &&
              callee.configureAudioDevices(controls ? "XMeetingTestAudio" : "NullAudio",
                  controls ? "Callee" : "Null Audio", controls ? "Callee" : "Null Audio") &&
              (audioOnly || (caller.enableH264Video(a.resolution) && callee.enableH264Video(b.resolution))) &&
              caller.start("XMeetingVideoCaller", port) &&
              callee.start("XMeetingVideoCallee", port + 1);
    for (unsigned round = 1; ok && round <= 2; ++round)
      ok = runCall(caller, callee, sinkA, sinkB, peer, round, localPeer, audioOnly, controls);
    caller.stop();
    callee.stop();
    std::printf("%s: two H.323 %s calls to %s\n",
                ok ? "PASS" : "FAIL", audioOnly ? "audio-only" : "H.264 RTP / VideoToolbox", peer.c_str());
    return ok ? 0 : 1;
  }
}
