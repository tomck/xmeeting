#import "XMH264Decoder.h"
#import "XMH264Encoder.h"
#include "XMH323PlusEngine.hpp"

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
  if (CVPixelBufferGetWidth(buffer) != 640 || CVPixelBufferGetHeight(buffer) != 480) {
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
  void onCallEstablished(const CallInfo&) override { ++established; }
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
             const std::string& address, unsigned round, bool localPeer) {
  std::string token;
  if (!caller.call(address, &token)) return false;
  const unsigned startA = a.harness->decodedFrames, startB = b.harness->decodedFrames;
  unsigned sentA = 0, sentB = 0;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto incoming = b.takeIncoming();
    if (!incoming.empty() && !callee.answer(incoming)) return false;
    sentA += caller.submitH264AccessUnit(a.harness->encoded);
    if (localPeer) sentB += callee.submitH264AccessUnit(b.harness->encoded);
    if (a.harness->decodedFrames >= startA + 10 &&
        (!localPeer || b.harness->decodedFrames >= startB + 10)) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(34));
  }
  const bool mediaOK = a.harness->decodedFrames >= startA + 10 &&
                       (!localPeer || b.harness->decodedFrames >= startB + 10) &&
                       a.established >= round && (!localPeer || b.established >= round) &&
                       a.audio >= round * 2 && (!localPeer || b.audio >= round * 2) && sentA >= 10 &&
                       a.errors == 0 && b.errors == 0 &&
                       a.harness->errors == 0 && b.harness->errors == 0;
  std::printf("Round %u: sent=%u/%u decoded=%u/%u established=%u/%u audio=%u/%u\n",
              round, sentA, sentB, a.harness->decodedFrames.load() - startA,
              b.harness->decodedFrames.load() - startB, a.established.load(),
              b.established.load(), a.audio.load(), b.audio.load());
  caller.hangUp(token);
  const auto clearDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while ((a.ended < round || (localPeer && b.ended < round)) && std::chrono::steady_clock::now() < clearDeadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  [a.harness.decoder stop];
  [b.harness.decoder stop];
  return mediaOK && a.ended >= round && (!localPeer || b.ended >= round);
}
} // namespace

int main(int argc, char **argv) {
  @autoreleasepool {
    TestProcess process;
    process.PreInitialise(argc, argv, nullptr);
    std::string peer;
    for (int i = 1; i < argc; ++i) {
      if (std::strcmp(argv[i], "--trace") == 0) PTrace::Initialise(4);
      else if (std::strcmp(argv[i], "--peer") == 0 && i+1 < argc) peer = argv[++i];
      else { std::fprintf(stderr, "Usage: xmeeting-h264-call-tests [--trace] [--peer host:port]\n"); return 2; }
    }
    XMCallVideoHarness *a = [[XMCallVideoHarness alloc] init];
    XMCallVideoHarness *b = [[XMCallVideoHarness alloc] init];
    if (!prepareVideo(a) || !prepareVideo(b)) {
      std::fprintf(stderr, "FAIL: could not encode synthetic H.264 video\n");
      return 1;
    }
    Sink sinkA(a), sinkB(b);
    H323PlusEngine caller(sinkA), callee(sinkB);
    const unsigned port = 30000 + (getpid() % 10000) * 2;
    const bool localPeer = peer.empty();
    if (localPeer) peer = "127.0.0.1:" + std::to_string(port + 1);
    bool ok = caller.configureAudioDevices("NullAudio", "Null Audio", "Null Audio") &&
              callee.configureAudioDevices("NullAudio", "Null Audio", "Null Audio") &&
              caller.enableH264Video() && callee.enableH264Video() &&
              caller.start("XMeetingVideoCaller", port) &&
              callee.start("XMeetingVideoCallee", port + 1);
    for (unsigned round = 1; ok && round <= 2; ++round)
      ok = runCall(caller, callee, sinkA, sinkB, peer, round, localPeer);
    caller.stop();
    callee.stop();
    std::printf("%s: two H.323 calls with H.264 RTP to %s and VideoToolbox decoding\n",
                ok ? "PASS" : "FAIL", peer.c_str());
    return ok ? 0 : 1;
  }
}
