#include "XMH323PlusEngine.hpp"
#include "XMH323PlusH264.hpp"

#include <ptlib.h>
#include <ptlib/sound.h>

#include <CoreAudio/CoreAudio.h>

#include <h323ep.h>
#include <transports.h>

#include <utility>

// PTLib's macOS sound implementation is a static plug-in. Referencing its
// loader explicitly prevents the archive linker from discarding CoreAudio.
PPLUGIN_STATIC_LOAD(CoreAudio, PSoundChannel);

namespace xmeeting::h323 {
namespace {

std::string toStdString(const PString& value) {
  return std::string(static_cast<const char*>(value));
}

CallInfo makeCallInfo(H323Connection& connection, bool incoming) {
  CallInfo info;
  info.token = toStdString(connection.GetCallToken());
  info.remoteName = toStdString(connection.GetRemotePartyName());
  info.remoteNumber = toStdString(connection.GetRemotePartyNumber());
  info.remoteAddress = toStdString(connection.GetRemotePartyAddress());
  info.remoteApplication = toStdString(connection.GetRemoteApplication());
  info.incoming = incoming;
  return info;
}

AudioChannelInfo makeAudioChannelInfo(H323Connection& connection,
                                      const H323Channel& channel) {
  AudioChannelInfo info;
  info.token = toStdString(connection.GetCallToken());
  info.codec = toStdString(channel.GetCapability().GetFormatName());
  info.transmitting = channel.GetDirection() == H323Channel::IsTransmitter;
  return info;
}

std::vector<std::string> toStringVector(const PStringArray& values) {
  std::vector<std::string> result;
  result.reserve(values.GetSize());
  for (PINDEX index = 0; index < values.GetSize(); ++index) {
    result.push_back(toStdString(values[index]));
  }
  return result;
}

bool isRealAudioDevice(const PString& value) {
  return !value.IsEmpty() && !(value *= "Null");
}

PString defaultCoreAudioDevice(PSoundChannel::Directions direction) {
  AudioObjectPropertyAddress defaultDeviceProperty = {
      direction == PSoundChannel::Player ? kAudioHardwarePropertyDefaultOutputDevice
                                         : kAudioHardwarePropertyDefaultInputDevice,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMaster,
  };
  AudioDeviceID device = kAudioDeviceUnknown;
  UInt32 deviceSize = sizeof(device);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultDeviceProperty, 0,
                                 nullptr, &deviceSize, &device) != noErr ||
      device == kAudioDeviceUnknown) {
    return PString::Empty();
  }

  AudioObjectPropertyAddress nameProperty = {
      kAudioObjectPropertyName,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMaster,
  };
  CFStringRef name = nullptr;
  UInt32 nameSize = sizeof(name);
  if (AudioObjectGetPropertyData(device, &nameProperty, 0, nullptr, &nameSize, &name) != noErr ||
      name == nullptr) {
    return PString::Empty();
  }

  const CFIndex bufferSize =
      CFStringGetMaximumSizeForEncoding(CFStringGetLength(name), kCFStringEncodingUTF8) + 1;
  std::vector<char> buffer(static_cast<std::size_t>(bufferSize));
  const bool converted = CFStringGetCString(name, buffer.data(), bufferSize,
                                             kCFStringEncodingUTF8);
  CFRelease(name);
  return converted ? PString(buffer.data()) : PString::Empty();
}

}  // namespace

class H323PlusEngine::Impl final : public H323EndPoint {
  PCLASSINFO(Impl, H323EndPoint);

 public:
  explicit Impl(EventSink& sink)
      : sink_(sink), h264Bridge_(std::make_shared<H264MediaBridge>()) {
    // G.711 is built into H323Plus and is the universal interoperability
    // baseline for H.323 audio. Do not advertise video until its modern media
    // path exists.
    AddAllCapabilities(0, P_MAX_INDEX, "G.711-*");
    AddAllUserInputCapabilities(0, P_MAX_INDEX);

    h264Bridge_->setReceiveHandler([this](const media::H264AccessUnit& accessUnit) {
      sink_.onH264AccessUnit(accessUnit);
    });
    h264Bridge_->setErrorHandler([](const std::string& message) {
      // A dropped video frame must not change an established audio call into
      // an application-wide error. The next IDR can recover the picture.
      PTRACE(2, "XMeeting H.264: " << message);
    });

    // Select PTLib's native macOS devices explicitly. Leaving the driver name
    // empty can fall back to NullAudio in a statically linked application.
    const PString inputDevice = defaultCoreAudioDevice(PSoundChannel::Recorder);
    const PString outputDevice = defaultCoreAudioDevice(PSoundChannel::Player);
    audioDriver_ = "CoreAudio";
    if (isRealAudioDevice(inputDevice) && isRealAudioDevice(outputDevice)) {
      configureAudioDevices("CoreAudio", toStdString(inputDevice), toStdString(outputDevice));
    }
  }

  ~Impl() override {
    stop();
  }

  bool start(const std::string& localUserName, std::uint16_t listenPort) {
    if (started_) {
      return true;
    }
    if (!PProcess::IsInitialised()) {
      sink_.onError("PTLib has not been initialised with a PProcess instance");
      return false;
    }
    if (localUserName.empty()) {
      sink_.onError("The local H.323 user name cannot be empty");
      return false;
    }

    SetLocalUserName(localUserName.c_str());
    auto* listener = new H323ListenerTCP(
        *this, PIPSocket::Address::GetAny(4), static_cast<WORD>(listenPort));
    if (!StartListener(listener)) {
      delete listener;
      sink_.onError("Could not start the H.323 listener on TCP port " +
                    std::to_string(listenPort));
      return false;
    }

    started_ = true;
    return true;
  }

  void stop() {
    if (started_) {
      ClearAllCalls(H323Connection::EndedByLocalUser, true);
      RemoveListener(nullptr);
      started_ = false;
    }

    if (GetGatekeeper() != nullptr) {
      RemoveGatekeeper();
    }
  }

  bool call(const std::string& address, std::string* returnedToken) {
    if (!started_ || address.empty()) {
      return false;
    }

    PString token;
    if (MakeCall(address.c_str(), token) == nullptr) {
      return false;
    }
    if (returnedToken != nullptr) {
      *returnedToken = toStdString(token);
    }
    return true;
  }

  bool answer(const std::string& token, H323Connection::AnswerCallResponse response) {
    H323Connection* connection = FindConnectionWithLock(token.c_str());
    if (connection == nullptr) {
      return false;
    }

    connection->AnsweringCall(response);
    connection->Unlock();
    return true;
  }

  bool hangUp(const std::string& token) {
    return !token.empty() && ClearCall(token.c_str(), H323Connection::EndedByLocalUser);
  }

  bool registerWithGatekeeper(const std::string& address,
                              const std::string& alias,
                              const std::string& password) {
    if (!started_ || address.empty()) {
      return false;
    }
    if (!alias.empty()) {
      SetLocalUserName(alias.c_str());
    }
    SetGatekeeperPassword(password.c_str());
    return UseGatekeeper(address.c_str());
  }

  std::vector<std::string> activeCallTokens() {
    PStringList connections = GetAllConnections();
    std::vector<std::string> result;
    result.reserve(connections.GetSize());
    for (PINDEX index = 0; index < connections.GetSize(); ++index) {
      result.push_back(toStdString(connections[index]));
    }
    return result;
  }

  AudioSystemInfo audioSystemInfo() const {
    AudioSystemInfo info;
    info.driver = audioDriver_;
    info.inputDevice = toStdString(GetSoundChannelRecordDevice());
    info.outputDevice = toStdString(GetSoundChannelPlayDevice());
    info.inputDevices = toStringVector(
        PSoundChannel::GetDeviceNames(audioDriver_.c_str(), PSoundChannel::Recorder));
    info.outputDevices = toStringVector(
        PSoundChannel::GetDeviceNames(audioDriver_.c_str(), PSoundChannel::Player));

    const H323Capabilities& capabilities = GetCapabilities();
    for (PINDEX index = 0; index < capabilities.GetSize(); ++index) {
      const H323Capability& capability = capabilities[index];
      if (capability.GetMainType() == H323Capability::e_Audio) {
        info.codecs.push_back(toStdString(capability.GetFormatName()));
      }
    }

    info.available = audioDriver_ == "CoreAudio" && audioPlaybackConfigured_ &&
                     audioRecordingConfigured_ &&
                     isRealAudioDevice(GetSoundChannelRecordDevice()) &&
                     isRealAudioDevice(GetSoundChannelPlayDevice()) && !info.codecs.empty();
    return info;
  }

  VideoSystemInfo videoSystemInfo() const {
    VideoSystemInfo info;
#ifdef H323_VIDEO
    info.frameworkEnabled = true;
#endif

    const H323Capabilities& capabilities = GetCapabilities();
    for (PINDEX index = 0; index < capabilities.GetSize(); ++index) {
      const H323Capability& capability = capabilities[index];
      if (capability.GetMainType() == H323Capability::e_Video) {
        info.codecs.push_back(toStdString(capability.GetFormatName()));
      }
    }

    // The capability list is exactly what H323Plus will offer during H.245
    // negotiation. A future VideoToolbox bridge must register its codec here
    // before this becomes true.
    info.codecAvailable = !info.codecs.empty();
    info.advertised = info.codecAvailable;
    return info;
  }

  bool enableH264Video(XMVideoResolution resolution) {
#ifdef H323_VIDEO
    if (!XMVideoResolutionIsValid(resolution)) return false;
    if (h264VideoEnabled_) {
      return resolution == videoResolution_;
    }
    std::unique_ptr<H323Capability> capability =
        makeH264VideoToolboxCapability(h264Bridge_, resolution);
    if (!capability) {
      return false;
    }
    SetCapability(0, P_MAX_INDEX, capability.release());
    h264VideoEnabled_ = true;
    videoResolution_ = resolution;
    return true;
#else
    return false;
#endif
  }

  bool submitH264AccessUnit(const H264AccessUnit& accessUnit) {
    return h264VideoEnabled_ && h264Bridge_->enqueueAccessUnit(accessUnit);
  }

  bool configureAudioDevices(const std::string& driver,
                             const std::string& inputDevice,
                             const std::string& outputDevice) {
    audioDriver_ = driver;
    audioPlaybackConfigured_ = SetSoundChannelPlayDriver(driver.c_str());
    if (audioPlaybackConfigured_ && !outputDevice.empty()) {
      audioPlaybackConfigured_ = SetSoundChannelPlayDevice(outputDevice.c_str());
    }

    audioRecordingConfigured_ = SetSoundChannelRecordDriver(driver.c_str());
    if (audioRecordingConfigured_ && !inputDevice.empty()) {
      audioRecordingConfigured_ = SetSoundChannelRecordDevice(inputDevice.c_str());
    }
    return audioPlaybackConfigured_ && audioRecordingConfigured_;
  }

  PBoolean OnIncomingCall(H323Connection& connection,
                          const H323SignalPDU&,
                          H323SignalPDU&) override {
    sink_.onIncomingCall(makeCallInfo(connection, true));
    return true;
  }

  H323Connection::AnswerCallResponse OnAnswerCall(
      H323Connection&,
      const PString&,
      const H323SignalPDU&,
      H323SignalPDU&) override {
    return H323Connection::AnswerCallPending;
  }

  void OnConnectionEstablished(H323Connection& connection,
                               const PString& token) override {
    H323EndPoint::OnConnectionEstablished(connection, token);
    sink_.onCallEstablished(makeCallInfo(connection, connection.HadAnsweredCall()));
  }

  void OnConnectionCleared(H323Connection& connection,
                           const PString& token) override {
    CallEndedInfo info;
    info.call = makeCallInfo(connection, connection.HadAnsweredCall());
    info.call.token = toStdString(token);
    info.h323Reason = static_cast<int>(connection.GetCallEndReason());
    info.q931Cause = connection.GetQ931Cause();
    sink_.onCallEnded(info);
    H323EndPoint::OnConnectionCleared(connection, token);
  }

  PBoolean OnStartLogicalChannel(H323Connection& connection,
                                 H323Channel& channel) override {
    if (!H323EndPoint::OnStartLogicalChannel(connection, channel)) {
      return false;
    }
    if (channel.GetCapability().GetMainType() == H323Capability::e_Audio) {
      sink_.onAudioChannelStarted(makeAudioChannelInfo(connection, channel));
    }
    return true;
  }

  PBoolean OpenAudioChannel(H323Connection& connection,
                            PBoolean isEncoding,
                            unsigned bufferSize,
                            H323AudioCodec& codec) override {
    if (H323EndPoint::OpenAudioChannel(connection, isEncoding, bufferSize, codec)) {
      return true;
    }
    sink_.onError(isEncoding ? "Could not open the selected microphone"
                             : "Could not open the selected audio output device");
    return false;
  }

  void OnClosedLogicalChannel(H323Connection& connection,
                              const H323Channel& channel) override {
    if (channel.GetCapability().GetMainType() == H323Capability::e_Audio) {
      sink_.onAudioChannelStopped(makeAudioChannelInfo(connection, channel));
    }
    H323EndPoint::OnClosedLogicalChannel(connection, channel);
  }

  void OnRegistrationConfirm(const H323TransportAddress& rasAddress) override {
    H323EndPoint::OnRegistrationConfirm(rasAddress);
    sink_.onGatekeeperRegistered(toStdString(rasAddress));
  }

  void OnRegistrationReject() override {
    H323EndPoint::OnRegistrationReject();
    sink_.onGatekeeperRegistrationFailed();
  }

 private:
  EventSink& sink_;
  bool started_ = false;
  std::string audioDriver_;
  bool audioPlaybackConfigured_ = false;
  bool audioRecordingConfigured_ = false;
  std::shared_ptr<H264MediaBridge> h264Bridge_;
  bool h264VideoEnabled_ = false;
  XMVideoResolution videoResolution_ = XMVideoResolutionVGA;
};

H323PlusEngine::H323PlusEngine(EventSink& sink)
    : impl_(std::make_unique<Impl>(sink)) {}

H323PlusEngine::~H323PlusEngine() = default;

bool H323PlusEngine::start(const std::string& localUserName, std::uint16_t listenPort) {
  return impl_->start(localUserName, listenPort);
}

void H323PlusEngine::stop() {
  impl_->stop();
}

bool H323PlusEngine::call(const std::string& address, std::string* token) {
  return impl_->call(address, token);
}

bool H323PlusEngine::answer(const std::string& token) {
  return impl_->answer(token, H323Connection::AnswerCallNow);
}

bool H323PlusEngine::reject(const std::string& token) {
  return impl_->answer(token, H323Connection::AnswerCallDenied);
}

bool H323PlusEngine::hangUp(const std::string& token) {
  return impl_->hangUp(token);
}

bool H323PlusEngine::registerWithGatekeeper(const std::string& address,
                                            const std::string& alias,
                                            const std::string& password) {
  return impl_->registerWithGatekeeper(address, alias, password);
}

void H323PlusEngine::unregisterFromGatekeeper() {
  if (impl_->GetGatekeeper() != nullptr) {
    impl_->RemoveGatekeeper();
  }
}

bool H323PlusEngine::isRegisteredWithGatekeeper() const {
  return impl_->IsRegisteredWithGatekeeper();
}

std::vector<std::string> H323PlusEngine::activeCallTokens() const {
  return impl_->activeCallTokens();
}

AudioSystemInfo H323PlusEngine::audioSystemInfo() const {
  return impl_->audioSystemInfo();
}

VideoSystemInfo H323PlusEngine::videoSystemInfo() const {
  return impl_->videoSystemInfo();
}

bool H323PlusEngine::enableH264Video(XMVideoResolution resolution) {
  return impl_->enableH264Video(resolution);
}

bool H323PlusEngine::submitH264AccessUnit(const H264AccessUnit& accessUnit) {
  return impl_->submitH264AccessUnit(accessUnit);
}

bool H323PlusEngine::configureAudioDevices(const std::string& driver,
                                           const std::string& inputDevice,
                                           const std::string& outputDevice) {
  return impl_->configureAudioDevices(driver, inputDevice, outputDevice);
}

}  // namespace xmeeting::h323
