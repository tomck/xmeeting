#include "XMH323PlusH264.hpp"

#include <ptlib.h>

#include <codecs.h>
#include <h323caps.h>
#include <h323con.h>
#include <mediafmt.h>

#include <condition_variable>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <utility>

namespace xmeeting::h323 {
namespace {

constexpr char kH264CapabilityOid[] = "0.0.8.241.0.0.1";
constexpr char kH264NonInterleavedPacketizationOid[] = "0.0.8.241.0.0.0.1";
constexpr char kH264FormatName[] = "H.264-VideoToolbox";
constexpr unsigned kFrameWidth = 640;
constexpr unsigned kFrameHeight = 480;
constexpr unsigned kFrameRate = 30;
constexpr unsigned kBitRate = 512000;
constexpr unsigned kH241BaselineProfile = 64;
constexpr unsigned kH241Level30 = 64;
constexpr std::size_t kH323RtpPayloadCapacity = 2000;

void addGenericUnsignedOption(OpalMediaFormat& format,
                              unsigned ordinal,
                              unsigned value,
                              OpalMediaOption::MergeType merge,
                              OpalMediaOption::H245GenericInfo::IntegerTypes integerType) {
  PString name(PString::Printf, "Generic Parameter %u", ordinal);
  auto* option = new OpalMediaOptionUnsigned(name, false, merge, value);
  OpalMediaOption::H245GenericInfo generic{};
  generic.ordinal = ordinal;
  generic.mode = OpalMediaOption::H245GenericInfo::Collapsing;
  generic.integerType = integerType;
  generic.excludeTCS = false;
  generic.excludeOLC = false;
  generic.excludeReqMode = false;
  option->SetH245Generic(generic);
  format.AddOption(option);
}

OpalVideoFormat& h264VideoToolboxFormat() {
  static OpalVideoFormat format(kH264FormatName,
                                RTP_DataFrame::DynamicBase,
                                kFrameWidth,
                                kFrameHeight,
                                kFrameRate,
                                kBitRate);
  static const bool configured = [] {
    format.AddOption(new OpalMediaOptionInteger(
        OpalVideoFormat::FrameWidthOption, true, OpalMediaOption::MinMerge,
        kFrameWidth, 16, 4096));
    format.AddOption(new OpalMediaOptionInteger(
        OpalVideoFormat::FrameHeightOption, true, OpalMediaOption::MinMerge,
        kFrameHeight, 16, 2160));
    format.AddOption(new OpalMediaOptionInteger(
        OpalVideoFormat::TargetBitRateOption, false, OpalMediaOption::MinMerge,
        kBitRate, 1000));
    format.AddOption(new OpalMediaOptionInteger(
        OpalVideoFormat::MaxBitRateOption, false, OpalMediaOption::MinMerge,
        kBitRate, 1000));
    format.AddOption(new OpalMediaOptionInteger(
        OpalVideoFormat::FrameTimeOption, false, OpalMediaOption::NoMerge,
        OpalMediaFormat::VideoTimeUnits / kFrameRate));
    format.AddOption(new OpalMediaOptionInteger(
        OpalVideoFormat::MaxPayloadSizeOption, false, OpalMediaOption::MaxMerge,
        1200));
    format.AddOption(new OpalMediaOptionString(
        "Media Packetization", true, kH264NonInterleavedPacketizationOid));

    addGenericUnsignedOption(format, 41, kH241BaselineProfile,
                             OpalMediaOption::AndMerge,
                             OpalMediaOption::H245GenericInfo::BooleanArray);
    addGenericUnsignedOption(format, 42, kH241Level30,
                             OpalMediaOption::MinMerge,
                             OpalMediaOption::H245GenericInfo::UnsignedInt);
    return true;
  }();
  (void)configured;
  return format;
}

}  // namespace

class H264MediaBridge::Impl final {
 public:
  bool enqueue(const media::H264AccessUnit& accessUnit,
               std::size_t maximumPayloadSize) {
    bool keyFrame = false;
    std::size_t bytes = 0;
    for (const auto& nal : accessUnit) {
      if (nal.size() > media::H264RtpReassembler::maximumAccessUnitBytes - bytes) return false;
      bytes += nal.size();
      keyFrame |= !nal.empty() && (nal.front() & 31) == 5;
    }
    if (maximumPayloadSize > kH323RtpPayloadCapacity) {
      reportError("The requested H.264 RTP payload exceeds the H323Plus channel capacity");
      return false;
    }
    std::vector<media::H264RtpPayload> payloads;
    std::string error;
    if (!media::packetizeH264AccessUnit(accessUnit, maximumPayloadSize, &payloads,
                                        &error)) {
      reportError(error);
      return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!transmitting_) {
      return false;
    }
    // Dropping a predicted frame invalidates subsequent predictions. Keep
    // memory/latency bounded and resume only at an independently decodable IDR.
    if (queuedFrames_ >= 3) {
      waitingForKeyFrame_ = true;
      return false;
    }
    if (waitingForKeyFrame_ && !keyFrame) return false;
    waitingForKeyFrame_ = false;
    ++queuedFrames_;
    for (media::H264RtpPayload& payload : payloads) {
      transmitPayloads_.push_back(std::move(payload));
    }
    condition_.notify_one();
    return true;
  }

  bool takeTransmitPayload(media::H264RtpPayload* payload) {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [this] {
      return !transmitting_ || !transmitPayloads_.empty();
    });
    if (!transmitting_ || transmitPayloads_.empty()) {
      return false;
    }
    *payload = std::move(transmitPayloads_.front());
    transmitPayloads_.pop_front();
    if (payload->marker) --queuedFrames_;
    return true;
  }

  void setTransmitting(bool transmitting) {
    std::lock_guard<std::mutex> lock(mutex_);
    transmitting_ = transmitting;
    transmitPayloads_.clear();
    queuedFrames_ = 0;
    waitingForKeyFrame_ = true;
    condition_.notify_all();
  }

  void setReceiving(bool receiving) {
    std::lock_guard<std::mutex> lock(mutex_);
    receiving_ = receiving;
    reassembler_.reset();
  }

  bool receive(const std::uint8_t* payload, std::size_t size, const RTP_DataFrame& frame) {
    ReceiveHandler handler;
    std::optional<media::H264AccessUnit> accessUnit;
    std::string error;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!receiving_) {
        return false;
      }
      accessUnit = reassembler_.pushRtp(payload, size, frame.GetMarker(),
                                        frame.GetSequenceNumber(), frame.GetTimestamp(), &error);
      handler = receiveHandler_;
    }
    if (!error.empty()) {
      reportError(error);
      return true;
    }
    if (accessUnit.has_value() && handler) {
      handler(*accessUnit);
    }
    return true;
  }

  void setReceiveHandler(ReceiveHandler handler) {
    std::lock_guard<std::mutex> lock(mutex_);
    receiveHandler_ = std::move(handler);
  }

  void setErrorHandler(ErrorHandler handler) {
    std::lock_guard<std::mutex> lock(mutex_);
    errorHandler_ = std::move(handler);
  }

  bool isTransmitting() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return transmitting_;
  }

  bool isReceiving() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return receiving_;
  }

 private:
  void reportError(const std::string& error) {
    ErrorHandler handler;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      handler = errorHandler_;
    }
    if (handler) {
      handler(error);
    }
  }

  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<media::H264RtpPayload> transmitPayloads_;
  media::H264RtpReassembler reassembler_;
  ReceiveHandler receiveHandler_;
  ErrorHandler errorHandler_;
  bool transmitting_ = false;
  bool receiving_ = false;
  unsigned queuedFrames_ = 0;
  bool waitingForKeyFrame_ = true;
};

class H264VideoCodec final : public H323VideoCodec {
  PCLASSINFO(H264VideoCodec, H323VideoCodec);

 public:
  H264VideoCodec(const OpalMediaFormat& format,
                 Direction direction,
                 std::shared_ptr<H264MediaBridge> bridge)
      : H323VideoCodec(format, direction),
        direction_(direction),
        bridge_(std::move(bridge)) {
    frameWidth = kFrameWidth;
    frameHeight = kFrameHeight;
  }

  ~H264VideoCodec() override {
    Close();
  }

  PBoolean Open(H323Connection&) override {
    if (open_.exchange(true)) {
      return true;
    }
    if (direction_ == Encoder) {
      bridge_->impl_->setTransmitting(true);
    } else {
      bridge_->impl_->setReceiving(true);
    }
    return true;
  }

  void Close() override {
    if (!open_.exchange(false)) {
      return;
    }
    if (direction_ == Encoder) {
      bridge_->impl_->setTransmitting(false);
    } else {
      bridge_->impl_->setReceiving(false);
    }
  }

  PBoolean Read(BYTE* buffer,
                unsigned& length,
                RTP_DataFrame& rtpFrame) override {
    if (direction_ != Encoder || !open_.load()) {
      return false;
    }
    media::H264RtpPayload payload;
    if (!bridge_->impl_->takeTransmitPayload(&payload)) {
      return false;
    }
    std::memcpy(buffer, payload.bytes.data(), payload.bytes.size());
    length = static_cast<unsigned>(payload.bytes.size());
    rtpFrame.SetMarker(payload.marker);
    return true;
  }

  PBoolean Write(const BYTE* buffer,
                 unsigned length,
                 const RTP_DataFrame& rtpFrame,
                 unsigned& written) override {
    written = length;
    if (direction_ != Decoder || !open_.load()) {
      return false;
    }
    if (length == 0) {
      return true;
    }
    return bridge_->impl_->receive(buffer, length, rtpFrame);
  }

  unsigned GetFrameRate() const override {
    return kFrameRate;
  }

 private:
  Direction direction_;
  std::shared_ptr<H264MediaBridge> bridge_;
  std::atomic_bool open_{false};
};

class H264VideoToolboxCapability final : public H323GenericVideoCapability {
  PCLASSINFO(H264VideoToolboxCapability, H323GenericVideoCapability);

 public:
  explicit H264VideoToolboxCapability(std::shared_ptr<H264MediaBridge> bridge)
      : H323GenericVideoCapability(kH264CapabilityOid, kBitRate / 100),
        bridge_(std::move(bridge)) {
    GetWritableMediaFormat() = h264VideoToolboxFormat();
    rtpPayloadType = GetMediaFormat().GetPayloadType();
    SetCapabilityDirection(H323Capability::e_ReceiveAndTransmit);
  }

  PObject* Clone() const override {
    return new H264VideoToolboxCapability(*this);
  }

  PString GetFormatName() const override {
    return kH264FormatName;
  }

  H323Codec* CreateCodec(H323Codec::Direction direction) const override {
    return new H264VideoCodec(GetMediaFormat(), direction, bridge_);
  }

 private:
  std::shared_ptr<H264MediaBridge> bridge_;
};

H264MediaBridge::H264MediaBridge() : impl_(std::make_unique<Impl>()) {}

H264MediaBridge::~H264MediaBridge() = default;

bool H264MediaBridge::enqueueAccessUnit(const media::H264AccessUnit& accessUnit,
                                        std::size_t maximumPayloadSize) {
  return impl_->enqueue(accessUnit, maximumPayloadSize);
}

void H264MediaBridge::setReceiveHandler(ReceiveHandler handler) {
  impl_->setReceiveHandler(std::move(handler));
}

void H264MediaBridge::setErrorHandler(ErrorHandler handler) {
  impl_->setErrorHandler(std::move(handler));
}

bool H264MediaBridge::isTransmitting() const {
  return impl_->isTransmitting();
}

bool H264MediaBridge::isReceiving() const {
  return impl_->isReceiving();
}

std::unique_ptr<H323Capability> makeH264VideoToolboxCapability(
    const std::shared_ptr<H264MediaBridge>& bridge) {
  if (!bridge) {
    return nullptr;
  }
  return std::make_unique<H264VideoToolboxCapability>(bridge);
}

}  // namespace xmeeting::h323
