#include <ptlib.h>
#include <h323ep.h>
#include <h323con.h>
#include <transports.h>
#include <cstdlib>
#include <iostream>

namespace {
void require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << std::endl;
    std::_Exit(1); // A failing SDK may have deadlocked its destructor too.
  }
}
class TestProcess final : public PProcess {
  PCLASSINFO(TestProcess, PProcess);
 public:
  TestProcess() : PProcess("XMeeting", "CallCancellationTests", 0, 1, ReleaseCode, 0) {}
  void Main() override {}
};
class Endpoint final : public H323EndPoint {
 public:
  PSyncPoint cleared;
  void OnConnectionCleared(H323Connection& connection, const PString& token) override {
    H323EndPoint::OnConnectionCleared(connection, token);
    cleared.Signal();
  }
};
// No network or camera: force Connect() to fail only after cleanup closes
// the transport, exactly the ordering observed when cancelling a pending call.
class PendingTransport final : public H323TransportTCP {
 public:
  PendingTransport(H323EndPoint& endpoint, PSyncPoint& entered)
      : H323TransportTCP(endpoint), entered_(entered) {}
  PBoolean Connect() override {
    entered_.Signal();
    require(closed_.Wait(3000), "Cleanup did not interrupt pending connect");
    return false;
  }
  PBoolean Close() override {
    const auto result = H323TransportTCP::Close();
    closed_.Signal();
    return result;
  }
 private:
  PSyncPoint& entered_;
  PSyncPoint closed_;
};
}
int main() {
  TestProcess process;
  Endpoint endpoint;
  for (unsigned attempt = 0; attempt < 10; ++attempt) {
    PSyncPoint entered;
    PString token;
    require(endpoint.MakeCall("127.0.0.1:1720",
            new PendingTransport(endpoint, entered), token) != nullptr,
            "Could not start synthetic pending call");
    require(entered.Wait(3000), "Call did not reach connect");
    require(endpoint.ClearCall(token), "Cancel was rejected");
    require(endpoint.cleared.Wait(3000), "Cancel deadlocked while connect was interrupted");
    endpoint.ClearAllCalls(H323Connection::EndedByLocalUser, true);
  }
  std::cout << "Pending-call cancellation and redial tests passed\n";
}
