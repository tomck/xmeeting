#include "XMH323PlusEngine.hpp"

#include <ptlib.h>
#include <ptlib/pprocess.h>

#include <iostream>
#include <mutex>
#include <string>

namespace {

class ConsoleSink final : public xmeeting::h323::EventSink {
 public:
  void onIncomingCall(const xmeeting::h323::CallInfo& call) override {
    print("Incoming call", call);
  }

  void onCallEstablished(const xmeeting::h323::CallInfo& call) override {
    print("Established call", call);
  }

  void onCallEnded(const xmeeting::h323::CallEndedInfo& ended) override {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cout << "Call ended: token=" << ended.call.token
              << " h323Reason=" << ended.h323Reason
              << " q931Cause=" << ended.q931Cause << std::endl;
  }

  void onAudioChannelStarted(const xmeeting::h323::AudioChannelInfo& audio) override {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cout << "Audio channel started: token=" << audio.token
              << " direction=" << (audio.transmitting ? "send" : "receive")
              << " codec=" << audio.codec << std::endl;
  }

  void onAudioChannelStopped(const xmeeting::h323::AudioChannelInfo& audio) override {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cout << "Audio channel stopped: token=" << audio.token
              << " direction=" << (audio.transmitting ? "send" : "receive")
              << " codec=" << audio.codec << std::endl;
  }

  void onGatekeeperRegistered(const std::string& address) override {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cout << "Gatekeeper registration confirmed by " << address << std::endl;
  }

  void onGatekeeperRegistrationFailed() override {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cout << "Gatekeeper registration rejected" << std::endl;
  }

  void onError(const std::string& message) override {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cerr << "Error: " << message << std::endl;
  }

 private:
  void print(const char* event, const xmeeting::h323::CallInfo& call) {
    std::lock_guard<std::mutex> lock(outputMutex_);
    std::cout << event << ": token=" << call.token
              << " remote=" << call.remoteName
              << " address=" << call.remoteAddress << std::endl;
  }

  std::mutex outputMutex_;
};

class H323PlusSmokeProcess final : public PProcess {
  PCLASSINFO(H323PlusSmokeProcess, PProcess);

 public:
  H323PlusSmokeProcess()
      : PProcess("XMeeting", "h323plus-smoke", 0, 1, AlphaCode, 0) {}

  void Main() override {
    PArgList& arguments = GetArguments();
    arguments.Parse(
        "u-user:x-port:g-gatekeeper:p-password:A-audio-info.N-null-audio.h-help.",
        false);
    if (arguments.HasOption('h')) {
      printUsage();
      return;
    }

    const std::string user = static_cast<const char*>(arguments.GetOptionString('u', "XMeeting"));
    const unsigned port = arguments.GetOptionString('x', "1720").AsUnsigned();

    ConsoleSink sink;
    xmeeting::h323::H323PlusEngine engine(sink);
    if (arguments.HasOption('N') &&
        !engine.configureAudioDevices("NullAudio", "Null Audio", "Null Audio")) {
      std::cerr << "Could not configure the null audio test device" << std::endl;
      SetTerminationValue(1);
      return;
    }
    if (arguments.HasOption('A')) {
      const xmeeting::h323::AudioSystemInfo audio = engine.audioSystemInfo();
      std::cout << "Audio driver: " << audio.driver << '\n'
                << "Input device: " << audio.inputDevice << '\n'
                << "Output device: " << audio.outputDevice << '\n'
                << "Detected inputs:";
      for (const std::string& device : audio.inputDevices) {
        std::cout << " " << device;
      }
      std::cout << "\nDetected outputs:";
      for (const std::string& device : audio.outputDevices) {
        std::cout << " " << device;
      }
      std::cout << '\n'
                << "Codecs:";
      for (const std::string& codec : audio.codecs) {
        std::cout << " " << codec;
      }
      std::cout << '\n';
      if (!audio.available) {
        std::cerr << "CoreAudio input/output is not available" << std::endl;
        SetTerminationValue(1);
      }
      return;
    }

    if (!engine.start(user, static_cast<std::uint16_t>(port))) {
      SetTerminationValue(1);
      return;
    }

    if (arguments.HasOption('g') &&
        !engine.registerWithGatekeeper(
            static_cast<const char*>(arguments.GetOptionString('g')),
            user,
            static_cast<const char*>(arguments.GetOptionString('p')))) {
      std::cerr << "Gatekeeper registration could not be started" << std::endl;
    }

    if (arguments.GetCount() > 0) {
      std::string token;
      if (!engine.call(static_cast<const char*>(arguments[0]), &token)) {
        std::cerr << "Could not start the outgoing call" << std::endl;
      } else {
        std::cout << "Outgoing call token: " << token << std::endl;
      }
    }

    std::cout << "Commands: a <token>, r <token>, h <token>, c <address>, q" << std::endl;
    std::string line;
    while (std::getline(std::cin, line) && line != "q") {
      const std::size_t separator = line.find(' ');
      const std::string command = line.substr(0, separator);
      const std::string value = separator == std::string::npos ? "" : line.substr(separator + 1);
      if (command == "a") {
        engine.answer(value);
      } else if (command == "r") {
        engine.reject(value);
      } else if (command == "h") {
        engine.hangUp(value);
      } else if (command == "c") {
        engine.call(value);
      }
    }

    engine.stop();
  }

 private:
  static void printUsage() {
    std::cout << "usage: h323plus-smoke [options] [alias@host]\n"
                 "  -u --user name        Local H.323 alias\n"
                 "  -x --port number      Listener port (default 1720)\n"
                 "  -g --gatekeeper host  Register with a gatekeeper\n"
                 "  -p --password value   Gatekeeper password\n"
                 "  -A --audio-info       Show audio devices and G.711 codecs\n"
                 "  -N --null-audio       Use silent audio devices for loopback testing\n";
  }
};

}  // namespace

PCREATE_PROCESS(H323PlusSmokeProcess);
