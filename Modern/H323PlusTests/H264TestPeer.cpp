// Bounded, headless Linux peer for native macOS video validation. The input
// is one independently encoded Annex-B IDR with SPS/PPS, repeated at 10 fps.
// Received Annex-B video is saved for independent FFmpeg decoding.
#include "XMH323PlusH264.hpp"
#include <ptlib.h>
#include <ptlib/pprocess.h>
#include <h323ep.h>
#include <transports.h>
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <mutex>
#include <thread>

namespace {
using xmeeting::h323::H264MediaBridge;
using xmeeting::media::H264AccessUnit;

H264AccessUnit readAnnexB(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
  H264AccessUnit nals;
  size_t start = 0;
  for (size_t i = 0; i + 3 <= bytes.size();) {
    size_t prefix = 0;
    if (bytes[i] == 0 && bytes[i+1] == 0) {
      if (bytes[i+2] == 1) prefix = 3;
      else if (i + 4 <= bytes.size() && bytes[i+2] == 0 && bytes[i+3] == 1) prefix = 4;
    }
    if (prefix == 0) { ++i; continue; }
    if (i > start && start != 0) nals.emplace_back(bytes.begin()+start, bytes.begin()+i);
    i += prefix;
    start = i;
  }
  if (start && start < bytes.size()) nals.emplace_back(bytes.begin()+start, bytes.end());
  return nals;
}

class Endpoint final : public H323EndPoint {
  PCLASSINFO(Endpoint, H323EndPoint);
 public:
  explicit Endpoint(std::shared_ptr<H264MediaBridge> bridge, XMVideoResolution resolution) {
    SetLocalUserName("XMeetingVideoTest");
    SetSoundChannelPlayDriver("NullAudio");
    SetSoundChannelRecordDriver("NullAudio");
    SetSoundChannelPlayDevice("Null Audio");
    SetSoundChannelRecordDevice("Null Audio");
    AddAllCapabilities(0, P_MAX_INDEX, "G.711-*");
    AddAllUserInputCapabilities(0, P_MAX_INDEX);
    SetCapability(0, P_MAX_INDEX, xmeeting::h323::makeH264VideoToolboxCapability(bridge, resolution).release());
  }
  H323Connection::AnswerCallResponse OnAnswerCall(
      H323Connection&, const PString&, const H323SignalPDU&, H323SignalPDU&) override {
    return H323Connection::AnswerCallNow;
  }
  void OnConnectionEstablished(H323Connection& connection, const PString& token) override {
    H323EndPoint::OnConnectionEstablished(connection, token);
    std::cout << "Established " << token << std::endl;
  }
  void OnConnectionCleared(H323Connection& connection, const PString& token) override {
    std::cout << "Cleared " << token << " reason=" << connection.GetCallEndReason() << std::endl;
    H323EndPoint::OnConnectionCleared(connection, token);
  }
};

class PeerProcess final : public PProcess {
  PCLASSINFO(PeerProcess, PProcess);
 public:
  PeerProcess() : PProcess("XMeeting", "H264TestPeer", 0, 1, ReleaseCode, 0) {}
  void Main() override {
    auto& args = GetArguments();
    args.Parse("i-input:o-output:x-port:s-seconds:r-resolution:t-trace.");
    const auto input = args.GetOptionString('i');
    const auto output = args.GetOptionString('o');
    const unsigned port = args.GetOptionString('x', "18222").AsUnsigned();
    const unsigned seconds = args.GetOptionString('s', "120").AsUnsigned();
    const PString selected = args.GetOptionString('r', "vga");
    if (input.IsEmpty() || output.IsEmpty() || port == 0 || port > 65535 || seconds == 0 || seconds > 3600 ||
        (selected != "vga" && selected != "720p")) {
      std::cerr << "Usage: h264-test-peer -i frame.h264 -o received.h264 [-x 18222] [-s 120] [-r vga|720p] [-tttt]\n";
      SetTerminationValue(2);
      return;
    }
    if (args.HasOption('t')) PTrace::Initialise(args.GetOptionCount('t'));
    const auto nals = readAnnexB(static_cast<const char *>(input));
    bool idr = false, sps = false, pps = false;
    for (const auto& nal : nals) {
      idr |= (nal[0] & 31) == 5;
      sps |= (nal[0] & 31) == 7;
      pps |= (nal[0] & 31) == 8;
    }
    if (!idr || !sps || !pps) {
      std::cerr << "Input must contain an IDR frame with SPS and PPS\n";
      SetTerminationValue(2);
      return;
    }
    std::ofstream recording(static_cast<const char *>(output), std::ios::binary);
    if (!recording) { SetTerminationValue(2); return; }
    std::mutex recordingMutex;
    std::atomic<unsigned> received{0}, errors{0};
    auto bridge = std::make_shared<H264MediaBridge>();
    bridge->setReceiveHandler([&](const H264AccessUnit& unit) {
      std::lock_guard<std::mutex> lock(recordingMutex);
      for (const auto& nal : unit) {
        recording.write("\0\0\0\1", 4);
        recording.write(reinterpret_cast<const char *>(nal.data()), nal.size());
      }
      recording.flush();
      ++received;
    });
    bridge->setErrorHandler([&](const std::string& message) {
      ++errors;
      std::cerr << message << std::endl;
    });
    Endpoint endpoint(bridge, selected == "720p" ? XMVideoResolution720p : XMVideoResolutionVGA);
    auto *listener = new H323ListenerTCP(endpoint, PIPSocket::Address::GetAny(4), port);
    if (!endpoint.StartListener(listener)) {
      delete listener;
      SetTerminationValue(1);
      return;
    }
    std::cout << "Listening on " << port << " for " << seconds << " seconds" << std::endl;
    unsigned sent = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (std::chrono::steady_clock::now() < deadline) {
      if (bridge->isTransmitting()) sent += bridge->enqueueAccessUnit(nals);
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    endpoint.ClearAllCalls(H323Connection::EndedByLocalUser, true);
    endpoint.RemoveListener(nullptr);
    std::cout << "Sent=" << sent << " received=" << received << " errors=" << errors << std::endl;
    SetTerminationValue(received > 0 && errors == 0 ? 0 : 1);
  }
};
} // namespace
PCREATE_PROCESS(PeerProcess);
