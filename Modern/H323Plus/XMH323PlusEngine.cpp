#include "XMH323PlusEngine.hpp"

#include <ptlib.h>

#include <h323ep.h>
#include <transports.h>

#include <utility>

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

}  // namespace

class H323PlusEngine::Impl final : public H323EndPoint {
  PCLASSINFO(Impl, H323EndPoint);

 public:
  explicit Impl(EventSink& sink) : sink_(sink) {}

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

}  // namespace xmeeting::h323
