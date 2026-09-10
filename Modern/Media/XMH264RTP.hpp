#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace xmeeting::media {

using H264NalUnit = std::vector<std::uint8_t>;
using H264AccessUnit = std::vector<H264NalUnit>;

struct H264RtpPayload {
  std::vector<std::uint8_t> bytes;
  bool marker = false;
};

// Converts the length-prefixed representation produced and consumed by
// VideoToolbox into individual NAL units. The length field is normally four
// bytes, but the value is carried in the format description and may vary.
bool parseH264AvccAccessUnit(const std::uint8_t* bytes,
                            std::size_t size,
                            std::size_t nalLengthSize,
                            H264AccessUnit* accessUnit,
                            std::string* error = nullptr);

std::vector<std::uint8_t> makeH264AvccAccessUnit(const H264AccessUnit& accessUnit,
                                                 std::size_t nalLengthSize = 4);

// RFC 6184 packetization-mode 1. Small NAL units use single-NAL packets and
// larger units use FU-A fragmentation. STAP-A aggregation is intentionally
// omitted for the first interoperable baseline.
bool packetizeH264AccessUnit(const H264AccessUnit& accessUnit,
                            std::size_t maximumPayloadSize,
                            std::vector<H264RtpPayload>* payloads,
                            std::string* error = nullptr);

class H264RtpReassembler final {
 public:
  static constexpr std::size_t maximumAccessUnitBytes = 4 * 1024 * 1024;
  // Returns a complete access unit when the RTP marker bit ends a frame.
  // A null optional means that more packets are required. Malformed input
  // resets the partial frame and reports an error.
  std::optional<H264AccessUnit> push(const std::uint8_t* payload,
                                     std::size_t size,
                                     bool marker,
                                     std::string* error = nullptr);

  // Network entry point: detect missing packets and never splice fragments
  // from different RTP timestamps into a single decoded frame.
  std::optional<H264AccessUnit> pushRtp(const std::uint8_t* payload,
                                      std::size_t size, bool marker,
                                      std::uint16_t sequence, std::uint32_t timestamp,
                                      std::string* error = nullptr);

  void reset();

 private:
  void clearAccessUnit();
  H264AccessUnit accessUnit_;
  H264NalUnit fragmentedNal_;
  bool fragmentInProgress_ = false;
  std::size_t bufferedBytes_ = 0;
  bool haveRtp_ = false;
  bool discardTimestamp_ = false;
  std::uint16_t expectedSequence_ = 0;
  std::uint32_t timestamp_ = 0;
};

}  // namespace xmeeting::media
