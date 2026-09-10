#include "XMH264RTP.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using xmeeting::media::H264AccessUnit;
using xmeeting::media::H264RtpPayload;
using xmeeting::media::H264RtpReassembler;

void require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

void testAvccRoundTrip() {
  const H264AccessUnit original = {{0x67, 0x42, 0x00, 0x1f},
                                   {0x68, 0xce, 0x3c, 0x80},
                                   {0x65, 0x88, 0x84}};
  const auto bytes = xmeeting::media::makeH264AvccAccessUnit(original);
  H264AccessUnit parsed;
  std::string error;
  require(xmeeting::media::parseH264AvccAccessUnit(bytes.data(), bytes.size(), 4,
                                                   &parsed, &error),
          error.c_str());
  require(parsed == original, "AVCC access-unit round trip changed a NAL unit");

  const std::uint8_t truncated[] = {0, 0, 0, 5, 0x65, 0x01};
  require(!xmeeting::media::parseH264AvccAccessUnit(truncated, sizeof(truncated), 4,
                                                    &parsed, &error),
          "A truncated AVCC NAL unit was accepted");
}

void testRtpRoundTrip() {
  H264AccessUnit original = {{0x67, 0x42, 0x00, 0x1f}, {0x68, 0xce, 0x3c, 0x80}};
  original.emplace_back(73, 0x5a);
  original.back()[0] = 0x65;

  std::vector<H264RtpPayload> packets;
  std::string error;
  require(xmeeting::media::packetizeH264AccessUnit(original, 16, &packets, &error),
          error.c_str());
  require(packets.size() > original.size(), "The large H.264 NAL unit was not fragmented");
  for (std::size_t index = 0; index < packets.size(); ++index) {
    require(packets[index].bytes.size() <= 16, "An H.264 RTP payload exceeded its limit");
    require(packets[index].marker == (index + 1 == packets.size()),
            "The RTP marker was not limited to the final packet");
  }

  H264RtpReassembler reassembler;
  std::optional<H264AccessUnit> completed;
  for (const H264RtpPayload& packet : packets) {
    completed = reassembler.push(packet.bytes.data(), packet.bytes.size(), packet.marker, &error);
  }
  require(completed.has_value(), "The final RTP packet did not complete an access unit");
  require(*completed == original, "RTP packetization/reassembly changed a NAL unit");
}

void testMalformedFuA() {
  H264RtpReassembler reassembler;
  std::string error;
  const std::uint8_t continuation[] = {0x7c, 0x05, 0x11};
  require(!reassembler.push(continuation, sizeof(continuation), false, &error).has_value(),
          "A stray FU-A continuation completed an access unit");
  require(!error.empty(), "A stray FU-A continuation did not report an error");

  std::vector<H264RtpPayload> packets;
  require(!xmeeting::media::packetizeH264AccessUnit({{0x65, 0x01}}, 2, &packets, &error),
          "An unusably small RTP payload limit was accepted");
}

void testLossRecoveryAndAggregation() {
  H264RtpReassembler receiver;
  std::string error;
  const std::uint8_t start[] = {0x7c, 0x85, 0x11};
  const std::uint8_t end[] = {0x7c, 0x45, 0x33};
  require(!receiver.pushRtp(start, sizeof(start), false, 10, 9000, &error),
          "An incomplete fragmented frame was emitted");
  require(!receiver.pushRtp(end, sizeof(end), true, 12, 9000, &error) && !error.empty(),
          "A frame with a missing FU-A fragment was emitted");
  const std::uint8_t next[] = {0x65, 0x44};
  require(receiver.pushRtp(next, sizeof(next), true, 13, 12000, &error).has_value(),
          "Reception did not recover at the next intact timestamp");

  receiver.reset();
  receiver.pushRtp(start, sizeof(start), false, 65535, 9000, &error);
  require(receiver.pushRtp(end, sizeof(end), true, 0, 9000, &error).has_value(),
          "RTP sequence-number wrap was treated as packet loss");

  receiver.pushRtp(start, sizeof(start), false, 1, 12000, &error);
  auto completed = receiver.pushRtp(next, sizeof(next), true, 2, 15000, &error);
  require(completed && *completed == H264AccessUnit{{0x65, 0x44}},
          "NAL units from different timestamps were spliced together");

  const std::uint8_t stap[] = {0x78, 0, 2, 0x67, 0x42, 0, 2, 0x68, 0x11};
  completed = receiver.pushRtp(stap, sizeof(stap), true, 3, 18000, &error);
  require(completed && *completed == H264AccessUnit{{0x67, 0x42}, {0x68, 0x11}},
          "STAP-A parameter-set aggregation was not decoded");
  const std::uint8_t badStap[] = {0x78, 0, 4, 0x67};
  require(!receiver.push(badStap, sizeof(badStap), true, &error) && !error.empty(),
          "A truncated STAP-A was accepted");
  std::vector<std::uint8_t> oversized(H264RtpReassembler::maximumAccessUnitBytes + 1, 0x55);
  oversized[0] = 0x65;
  require(!receiver.push(oversized.data(), oversized.size(), true, &error) && !error.empty(),
          "An unbounded video frame was accepted");
}

}  // namespace

int main() {
  testAvccRoundTrip();
  testRtpRoundTrip();
  testMalformedFuA();
  testLossRecoveryAndAggregation();
  std::cout << "H.264 AVCC/RTP tests passed\n";
  return 0;
}
