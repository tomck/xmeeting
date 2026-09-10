#include "XMH264RTP.hpp"

#include <algorithm>
#include <limits>

namespace xmeeting::media {
namespace {

constexpr std::uint8_t kNalTypeMask = 0x1f;
constexpr std::uint8_t kNalNriMask = 0x60;
constexpr std::uint8_t kFuAType = 28;
constexpr std::uint8_t kStapAType = 24;

bool fail(const char* message, std::string* error) {
  if (error != nullptr) {
    *error = message;
  }
  return false;
}

bool appendLength(std::vector<std::uint8_t>* output,
                  std::size_t value,
                  std::size_t lengthSize) {
  if (lengthSize == 0 || lengthSize > 4) {
    return false;
  }
  const std::uint64_t limit = std::uint64_t{1} << (lengthSize * 8);
  if (value >= limit) {
    return false;
  }
  for (std::size_t index = lengthSize; index > 0; --index) {
    output->push_back(static_cast<std::uint8_t>(value >> ((index - 1) * 8)));
  }
  return true;
}

}  // namespace

bool parseH264AvccAccessUnit(const std::uint8_t* bytes,
                            std::size_t size,
                            std::size_t nalLengthSize,
                            H264AccessUnit* accessUnit,
                            std::string* error) {
  if (accessUnit == nullptr) {
    return fail("No H.264 access-unit destination was supplied", error);
  }
  accessUnit->clear();
  if (nalLengthSize == 0 || nalLengthSize > 4) {
    return fail("The AVCC NAL length field must contain one to four bytes", error);
  }
  if (size != 0 && bytes == nullptr) {
    return fail("The AVCC buffer is missing", error);
  }

  std::size_t offset = 0;
  while (offset < size) {
    if (size - offset < nalLengthSize) {
      accessUnit->clear();
      return fail("The AVCC access unit ends inside a NAL length field", error);
    }
    std::size_t nalSize = 0;
    for (std::size_t index = 0; index < nalLengthSize; ++index) {
      nalSize = (nalSize << 8) | bytes[offset + index];
    }
    offset += nalLengthSize;
    if (nalSize == 0) {
      accessUnit->clear();
      return fail("The AVCC access unit contains an empty NAL unit", error);
    }
    if (nalSize > size - offset) {
      accessUnit->clear();
      return fail("The AVCC NAL length exceeds the available data", error);
    }
    accessUnit->emplace_back(bytes + offset, bytes + offset + nalSize);
    offset += nalSize;
  }
  if (accessUnit->empty()) {
    return fail("The AVCC access unit contains no NAL units", error);
  }
  return true;
}

std::vector<std::uint8_t> makeH264AvccAccessUnit(const H264AccessUnit& accessUnit,
                                                 std::size_t nalLengthSize) {
  std::vector<std::uint8_t> result;
  for (const H264NalUnit& nal : accessUnit) {
    if (nal.empty() || !appendLength(&result, nal.size(), nalLengthSize)) {
      return {};
    }
    result.insert(result.end(), nal.begin(), nal.end());
  }
  return result;
}

bool packetizeH264AccessUnit(const H264AccessUnit& accessUnit,
                            std::size_t maximumPayloadSize,
                            std::vector<H264RtpPayload>* payloads,
                            std::string* error) {
  if (payloads == nullptr) {
    return fail("No RTP payload destination was supplied", error);
  }
  payloads->clear();
  if (maximumPayloadSize < 3) {
    return fail("The RTP payload limit is too small for H.264 FU-A", error);
  }
  if (accessUnit.empty()) {
    return fail("The H.264 access unit contains no NAL units", error);
  }

  for (const H264NalUnit& nal : accessUnit) {
    if (nal.empty()) {
      payloads->clear();
      return fail("The H.264 access unit contains an empty NAL unit", error);
    }
    const std::uint8_t nalType = nal.front() & kNalTypeMask;
    if (nalType == 0 || nalType >= kStapAType) {
      payloads->clear();
      return fail("The H.264 access unit contains an invalid or packetization NAL type", error);
    }

    if (nal.size() <= maximumPayloadSize) {
      payloads->push_back({nal, false});
      continue;
    }

    const std::uint8_t fuIndicator = (nal.front() & kNalNriMask) | kFuAType;
    const std::size_t fragmentCapacity = maximumPayloadSize - 2;
    std::size_t offset = 1;
    bool first = true;
    while (offset < nal.size()) {
      const std::size_t fragmentSize = std::min(fragmentCapacity, nal.size() - offset);
      const bool last = offset + fragmentSize == nal.size();
      H264RtpPayload packet;
      packet.bytes.reserve(fragmentSize + 2);
      packet.bytes.push_back(fuIndicator);
      packet.bytes.push_back(static_cast<std::uint8_t>(nalType | (first ? 0x80 : 0) |
                                                       (last ? 0x40 : 0)));
      packet.bytes.insert(packet.bytes.end(), nal.begin() + offset,
                          nal.begin() + offset + fragmentSize);
      payloads->push_back(std::move(packet));
      offset += fragmentSize;
      first = false;
    }
  }

  payloads->back().marker = true;
  return true;
}

std::optional<H264AccessUnit> H264RtpReassembler::push(const std::uint8_t* payload,
                                                       std::size_t size,
                                                       bool marker,
                                                       std::string* error) {
  if (error) error->clear();
  if (payload == nullptr || size == 0) {
    clearAccessUnit();
    fail("The H.264 RTP payload is empty", error);
    return std::nullopt;
  }

  if (size > maximumAccessUnitBytes - bufferedBytes_ || accessUnit_.size() >= 1024) {
    clearAccessUnit();
    fail("The H.264 access unit exceeds the receive buffer limit", error);
    return std::nullopt;
  }
  bufferedBytes_ += size;
  if ((payload[0] & 0x80) != 0) {
    clearAccessUnit();
    fail("The H.264 forbidden-zero bit is set", error);
    return std::nullopt;
  }

  const std::uint8_t nalType = payload[0] & kNalTypeMask;
  if (nalType > 0 && nalType < kStapAType) {
    if (fragmentInProgress_) {
      clearAccessUnit();
      fail("A complete NAL unit interrupted an H.264 FU-A sequence", error);
      return std::nullopt;
    }
    accessUnit_.emplace_back(payload, payload + size);
  } else if (nalType == kStapAType) {
    if (fragmentInProgress_ || size < 4) {
      clearAccessUnit();
      fail("The H.264 STAP-A payload is invalid", error);
      return std::nullopt;
    }
    std::size_t offset = 1;
    while (offset < size) {
      if (size - offset < 2) {
        clearAccessUnit();
        fail("The H.264 STAP-A length is truncated", error);
        return std::nullopt;
      }
      const std::size_t length = (std::size_t(payload[offset]) << 8) | payload[offset + 1];
      offset += 2;
      if (length == 0 || length > size - offset || accessUnit_.size() >= 1024 ||
          (payload[offset] & 0x80) || (payload[offset] & kNalTypeMask) == 0 ||
          (payload[offset] & kNalTypeMask) >= kStapAType) {
        clearAccessUnit();
        fail("The H.264 STAP-A NAL is invalid", error);
        return std::nullopt;
      }
      accessUnit_.emplace_back(payload + offset, payload + offset + length);
      offset += length;
    }
  } else if (nalType == kFuAType) {
    if (size < 3) {
      clearAccessUnit();
      fail("The H.264 FU-A payload is too short", error);
      return std::nullopt;
    }
    const bool start = (payload[1] & 0x80) != 0;
    const bool end = (payload[1] & 0x40) != 0;
    const std::uint8_t originalType = payload[1] & kNalTypeMask;
    if (originalType == 0 || originalType >= kStapAType || (start && end) || (payload[1] & 0x20)) {
      clearAccessUnit();
      fail("The H.264 FU-A header is invalid", error);
      return std::nullopt;
    }
    if (start) {
      if (fragmentInProgress_) {
        clearAccessUnit();
        fail("A new H.264 FU-A sequence started before the previous one ended", error);
        return std::nullopt;
      }
      fragmentInProgress_ = true;
      fragmentedNal_.clear();
      fragmentedNal_.reserve(size);
      fragmentedNal_.push_back((payload[0] & 0xe0) | originalType);
    } else if (!fragmentInProgress_ ||
               fragmentedNal_.front() != ((payload[0] & 0xe0) | originalType)) {
      clearAccessUnit();
      fail("The H.264 FU-A continuation has no matching start packet", error);
      return std::nullopt;
    }
    fragmentedNal_.insert(fragmentedNal_.end(), payload + 2, payload + size);
    if (end) {
      accessUnit_.push_back(std::move(fragmentedNal_));
      fragmentedNal_.clear();
      fragmentInProgress_ = false;
    }
  } else {
    clearAccessUnit();
    fail("The H.264 RTP packet type is not supported", error);
    return std::nullopt;
  }

  if (!marker) {
    return std::nullopt;
  }
  if (fragmentInProgress_ || accessUnit_.empty()) {
    clearAccessUnit();
    fail("The H.264 RTP marker arrived before the access unit was complete", error);
    return std::nullopt;
  }

  H264AccessUnit complete = std::move(accessUnit_);
  clearAccessUnit();
  return complete;
}

std::optional<H264AccessUnit> H264RtpReassembler::pushRtp(
    const std::uint8_t* payload, std::size_t size, bool marker,
    std::uint16_t sequence, std::uint32_t timestamp, std::string* error) {
  if (error) error->clear();
  if (!haveRtp_ || timestamp != timestamp_) {
    clearAccessUnit();
    discardTimestamp_ = false;
  }
  if (haveRtp_ && sequence != expectedSequence_) {
    clearAccessUnit();
    discardTimestamp_ = true;
    fail("Dropped an H.264 frame after an RTP sequence discontinuity", error);
  }
  haveRtp_ = true;
  expectedSequence_ = static_cast<std::uint16_t>(sequence + 1);
  timestamp_ = timestamp;
  if (discardTimestamp_) return std::nullopt;
  std::string detail;
  auto result = push(payload, size, marker, &detail);
  if (!detail.empty()) {
    discardTimestamp_ = true;
    if (error) *error = detail;
  }
  return result;
}

void H264RtpReassembler::clearAccessUnit() {
  accessUnit_.clear();
  fragmentedNal_.clear();
  fragmentInProgress_ = false;
  bufferedBytes_ = 0;
}

void H264RtpReassembler::reset() {
  clearAccessUnit();
  haveRtp_ = false;
  discardTimestamp_ = false;
}

}  // namespace xmeeting::media
