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
    arguments.Parse("u-user:x-port:g-gatekeeper:p-password:h-help.", false);
    if (arguments.HasOption('h')) {
      printUsage();
      return;
    }

    const std::string user = static_cast<const char*>(arguments.GetOptionString('u', "XMeeting"));
    const unsigned port = arguments.GetOptionString('x', "1720").AsUnsigned();

    ConsoleSink sink;
    xmeeting::h323::H323PlusEngine engine(sink);
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
                 "  -p --password value   Gatekeeper password\n";
  }
};

}  // namespace

PCREATE_PROCESS(H323PlusSmokeProcess);
