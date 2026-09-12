#pragma once

#include "XMH264RTP.hpp"
#include "XMVideoProfile.h"

#include <functional>
#include <memory>
#include <string>

class H323Capability;
class H323Codec;

namespace xmeeting::h323 {

class H264MediaBridge final {
 public:
  using ReceiveHandler =
      std::function<void(const media::H264AccessUnit& accessUnit)>;
  using ErrorHandler = std::function<void(const std::string& message)>;

  H264MediaBridge();
  ~H264MediaBridge();

  H264MediaBridge(const H264MediaBridge&) = delete;
  H264MediaBridge& operator=(const H264MediaBridge&) = delete;

  // Camera frames are accepted only while an H.323 transmitter is active.
  // This prevents an idle endpoint from accumulating encoded video.
  bool enqueueAccessUnit(const media::H264AccessUnit& accessUnit,
                         std::size_t maximumPayloadSize = 1200);

  void setReceiveHandler(ReceiveHandler handler);
  void setErrorHandler(ErrorHandler handler);

  bool isTransmitting() const;
  bool isReceiving() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;

  friend class H264VideoCodec;
};

// Builds the H.241 generic H.264 capability used by the native bridge. The
// caller owns the returned capability. Creating it does not advertise it; an
// endpoint must explicitly add it to its capability table after the complete
// capture, encode, decode, and render path is ready.
std::unique_ptr<H323Capability> makeH264VideoToolboxCapability(
    const std::shared_ptr<H264MediaBridge>& bridge,
    XMVideoResolution resolution = XMVideoResolutionVGA);

}  // namespace xmeeting::h323
