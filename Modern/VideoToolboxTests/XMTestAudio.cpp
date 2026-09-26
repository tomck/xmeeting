#include "XMTestAudio.hpp"
#include <ptlib.h>
#include <ptlib/sound.h>
#include <ptclib/delaychan.h>
#include <atomic>
#include <cstdint>
#include <mutex>

namespace {
std::mutex samplesMutex;
xmeeting::test::AudioSamples callerSamples, calleeSamples;
}

namespace xmeeting::test {
void resetAudioSamples() {
  std::lock_guard<std::mutex> lock(samplesMutex);
  callerSamples = {}; calleeSamples = {};
}
AudioSamples audioSamples(bool caller) {
  std::lock_guard<std::mutex> lock(samplesMutex);
  return caller ? callerSamples : calleeSamples;
}
}

class XMeetingTestSound final : public PSoundChannel {
  PCLASSINFO(XMeetingTestSound, PSoundChannel);
 public:
  ~XMeetingTestSound() override { Close(); }
  static PStringArray GetDeviceNames(Directions = Player) {
    PStringArray names;
    names.AppendString("Caller"); names.AppendString("Callee");
    return names;
  }
  PBoolean Open(const PString& device, Directions direction, unsigned channels,
                unsigned rate, unsigned bits) override {
    name_ = device; activeDirection = direction;
    if (!SetFormat(channels, rate, bits)) return false;
    os_handle = 1; open_ = true;
    return true;
  }
  PString GetName() const override { return name_; }
  PBoolean Close() override { open_ = false; os_handle = -1; return true; }
  PBoolean IsOpen() const override { return open_; }
  PBoolean SetFormat(unsigned channels, unsigned rate, unsigned bits) override {
    rate_ = rate;
    return channels == 1 && bits == 16 && rate > 0;
  }
  unsigned GetChannels() const override { return 1; }
  unsigned GetSampleRate() const override { return rate_; }
  unsigned GetSampleSize() const override { return 16; }
  PBoolean SetBuffers(PINDEX, PINDEX) override { return true; }
  PBoolean GetBuffers(PINDEX& size, PINDEX& count) override { size = 320; count = 2; return true; }
  PBoolean Read(void* data, PINDEX size) override {
    if (!open_) return false;
    auto* samples = static_cast<std::int16_t*>(data);
    for (PINDEX i = 0; i < size / 2; ++i)
      samples[i] = ((sample_++ / 10) & 1) ? 12000 : -12000;
    lastReadCount = size;
    pacing_.Delay(size / 2 * 1000 / rate_);
    return open_;
  }
  PBoolean Write(const void* data, PINDEX size) override {
    if (!open_) return false;
    const auto* samples = static_cast<const std::int16_t*>(data);
    bool audible = false;
    for (PINDEX i = 0; i < size / 2; ++i)
      audible |= samples[i] > 256 || samples[i] < -256; // G.711 quantizes silence near zero.
    {
      std::lock_guard<std::mutex> lock(samplesMutex);
      auto& result = name_ == "Caller" ? callerSamples : calleeSamples;
      ++result.blocks;
      result.audibleBlocks += audible;
    }
    lastWriteCount = size;
    pacing_.Delay(size / 2 * 1000 / rate_);
    return open_;
  }
 private:
  std::atomic<bool> open_{false};
  PString name_;
  unsigned rate_ = 8000, sample_ = 0;
  PAdaptiveDelay pacing_;
};

PCREATE_SOUND_PLUGIN(XMeetingTestAudio, XMeetingTestSound)
