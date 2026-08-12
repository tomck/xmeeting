#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace xmeeting::h323 {

struct CallInfo {
  std::string token;
  std::string remoteName;
  std::string remoteNumber;
  std::string remoteAddress;
  std::string remoteApplication;
  bool incoming = false;
};

struct CallEndedInfo {
  CallInfo call;
  int h323Reason = 0;
  unsigned q931Cause = 0;
};

struct AudioSystemInfo {
  bool available = false;
  std::string driver;
  std::string inputDevice;
  std::string outputDevice;
  std::vector<std::string> inputDevices;
  std::vector<std::string> outputDevices;
  std::vector<std::string> codecs;
};

struct AudioChannelInfo {
  std::string token;
  std::string codec;
  bool transmitting = false;
};

// H323Plus invokes these methods from its worker threads. Implementations that
// touch AppKit must dispatch their work to the main queue.
class EventSink {
 public:
  virtual ~EventSink() = default;

  virtual void onIncomingCall(const CallInfo&) {}
  virtual void onCallEstablished(const CallInfo&) {}
  virtual void onCallEnded(const CallEndedInfo&) {}
  virtual void onAudioChannelStarted(const AudioChannelInfo&) {}
  virtual void onAudioChannelStopped(const AudioChannelInfo&) {}
  virtual void onGatekeeperRegistered(const std::string&) {}
  virtual void onGatekeeperRegistrationFailed() {}
  virtual void onError(const std::string&) {}
};

// A narrow, OPAL-free boundary around H323Plus. Keeping H323Plus and PTLib
// types out of this header prevents them from colliding with the legacy OPAL
// stack while the rest of XMeeting is migrated.
class H323PlusEngine final {
 public:
  // The sink must outlive the engine.
  explicit H323PlusEngine(EventSink& sink);
  ~H323PlusEngine();

  H323PlusEngine(const H323PlusEngine&) = delete;
  H323PlusEngine& operator=(const H323PlusEngine&) = delete;

  bool start(const std::string& localUserName, std::uint16_t listenPort = 1720);
  void stop();

  bool call(const std::string& address, std::string* token = nullptr);
  bool answer(const std::string& token);
  bool reject(const std::string& token);
  bool hangUp(const std::string& token);

  bool registerWithGatekeeper(const std::string& address,
                              const std::string& alias,
                              const std::string& password);
  void unregisterFromGatekeeper();
  bool isRegisteredWithGatekeeper() const;

  std::vector<std::string> activeCallTokens() const;
  AudioSystemInfo audioSystemInfo() const;
  bool configureAudioDevices(const std::string& driver,
                             const std::string& inputDevice,
                             const std::string& outputDevice);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace xmeeting::h323
