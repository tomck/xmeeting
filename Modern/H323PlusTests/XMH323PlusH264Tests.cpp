#include "XMH323PlusH264.hpp"

#include <ptlib.h>

#include <codecs.h>
#include <h323caps.h>
#include <h323ep.h>
#include <h323pdu.h>
#include <h245.h>

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

class TestProcess final : public PProcess {
  PCLASSINFO(TestProcess, PProcess);

 public:
  TestProcess() : PProcess("XMeeting", "H264BridgeTests", 0, 1, ReleaseCode, 0) {}
  void Main() override {}
};

void testCapabilityPdu(H323Capability& capability, XMVideoResolution resolution = XMVideoResolutionVGA) {
  const auto profile = XMVideoProfileForResolution(resolution);
  const auto receiveProfile = XMVideoProfileForResolution(XMVideoResolution720p);
  require(capability.GetMainType() == H323Capability::e_Video,
          "The native H.264 capability is not a video capability");
  require(capability.GetFormatName() == "H.264-VideoToolbox",
          "The native H.264 capability has the wrong format name");

  H245_Capability pdu;
  require(capability.OnSendingPDU(pdu), "The native H.264 capability PDU failed");
  require(pdu.GetTag() == H245_Capability::e_receiveAndTransmitVideoCapability,
          "The H.264 capability is not bidirectional");
  const H245_VideoCapability& video = pdu;
  require(video.GetTag() == H245_VideoCapability::e_genericVideoCapability,
          "The H.264 capability is not an H.241 generic capability");
  const H245_GenericCapability& generic = video;
  const PASN_ObjectId& identifier = generic.m_capabilityIdentifier;
  require(identifier.AsString() == "0.0.8.241.0.0.1",
          "The H.264 capability uses the wrong H.241 identifier");
  require(generic.HasOptionalField(H245_GenericCapability::e_collapsing),
          "The H.264 capability omitted its profile and level");
  require(generic.m_maxBitRate == receiveProfile.bitRate / 100,
          "The H.264 capability advertised the wrong bitrate");
  bool foundLevel = false;
  for (PINDEX i = 0; i < generic.m_collapsing.GetSize(); ++i) {
    const auto& parameter = generic.m_collapsing[i];
    if (parameter.m_parameterIdentifier.GetTag() == H245_ParameterIdentifier::e_standard &&
        (const PASN_Integer&)parameter.m_parameterIdentifier == 42) {
      foundLevel = (const PASN_Integer&)parameter.m_parameterValue == receiveProfile.h241Level;
    }
  }
  require(foundLevel, "The advertised decoder ceiling does not support 720p");
  require(capability.GetMediaFormat().GetOptionInteger(OpalVideoFormat::FrameWidthOption) == profile.width &&
          capability.GetMediaFormat().GetOptionInteger(OpalVideoFormat::FrameHeightOption) == profile.height,
          "The codec dimensions do not match the selected resolution");

  H245_RTPPayloadType packetization;
  require(H323SetRTPPacketization(packetization, capability.GetMediaFormat(),
                                  RTP_DataFrame::MaxPayloadType),
          "The H.264 capability omitted RTP packetization signaling");
  require(packetization.m_payloadDescriptor.GetTag() ==
              H245_RTPPayloadType_payloadDescriptor::e_oid,
          "The H.264 RTP packetization descriptor is not an OID");
  const PASN_ObjectId& packetizationIdentifier = packetization.m_payloadDescriptor;
  require(packetizationIdentifier.AsString() == "0.0.8.241.0.0.0.1",
          "The H.264 capability does not signal non-interleaved packetization");
}

void testProfileIsolationAndLimits() {
  using namespace xmeeting::h323;
  auto bridge = std::make_shared<H264MediaBridge>();
  auto vga = makeH264VideoToolboxCapability(bridge, XMVideoResolutionVGA);
  auto hd = makeH264VideoToolboxCapability(bridge, XMVideoResolution720p);
  testCapabilityPdu(*vga);
  testCapabilityPdu(*hd, XMVideoResolution720p);
  testCapabilityPdu(*vga); // HD construction must not mutate the VGA template.
  require(!makeH264VideoToolboxCapability(bridge, (XMVideoResolution)99),
          "An invalid resolution was accepted");

  H245_Capability vgaPdu, hdPdu;
  require(vga->OnSendingPDU(vgaPdu) && hd->OnSendingPDU(hdPdu), "Profile serialization failed");
  // Simulate a legacy VGA-only receiver. New XMeeting can receive 720p
  // regardless of its selected outgoing resolution.
  H245_VideoCapability& legacyVideo = vgaPdu;
  H245_GenericCapability& legacy = legacyVideo;
  legacy.m_maxBitRate = 5120;
  for (PINDEX i = 0; i < legacy.m_collapsing.GetSize(); ++i) {
    auto& parameter = legacy.m_collapsing[i];
    if ((const PASN_Integer&)parameter.m_parameterIdentifier == 42)
      (PASN_Integer&)parameter.m_parameterValue = 64;
  }
  H245_DataType hdChannel;
  require(hd->OnSendingPDU(hdChannel), "Could not serialize HD OLC");
  require(hd->OnReceivedPDU(vgaPdu), "Could not read VGA peer limits");
  H323EndPoint endpoint;
  H323Connection connection(endpoint, 1);
  std::unique_ptr<H323Codec> encoder(hd->CreateCodec(H323Codec::Encoder));
  require(!encoder->Open(connection), "720p transmission exceeded the peer's VGA level");
  require(!bridge->isTransmitting(), "Rejected 720p channel activated the bridge");

  require(vga->OnReceivedPDU(hdChannel, true),
          "Choosing VGA output incorrectly disabled 720p reception");
  H245_VideoCapability& oversizedVideo = hdChannel;
  H245_GenericCapability& oversized = oversizedVideo;
  for (PINDEX i = 0; i < oversized.m_collapsing.GetSize(); ++i) {
    auto& parameter = oversized.m_collapsing[i];
    if ((const PASN_Integer&)parameter.m_parameterIdentifier == 42)
      (PASN_Integer&)parameter.m_parameterValue = 85;
  }
  require(!vga->OnReceivedPDU(hdChannel, true), "An unsupported Level 4 channel was accepted");
  auto outgoing = makeH264VideoToolboxCapability(bridge, XMVideoResolutionVGA);
  require(outgoing->OnReceivedPDU(hdPdu), "Could not read HD peer limits");
  H245_DataType olc;
  require(outgoing->OnSendingPDU(olc), "Could not serialize VGA OLC");
  auto receiver = makeH264VideoToolboxCapability(bridge, XMVideoResolutionVGA);
  require(receiver->OnReceivedPDU(olc, true),
          "VGA OLC incorrectly inherited the HD peer's level");
  require(receiver->GetMediaFormat().GetOptionInteger("Generic Parameter 42") == 64,
          "VGA output signaled an HD encoding level");

  auto limited = makeH264VideoToolboxCapability(bridge, XMVideoResolutionVGA);
  limited->GetWritableMediaFormat().SetOptionInteger(OpalVideoFormat::MaxBitRateOption, 64000);
  std::unique_ptr<H323Codec> limitedEncoder(limited->CreateCodec(H323Codec::Encoder));
  require(!limitedEncoder->Open(connection), "Transmission exceeded the peer's bitrate limit");
}

void testBeeHDReceiveLimits() {
  // Sanitized receiveVideoCapability from the 2026-09-26 BEEHD call.
  // No addresses, aliases, or media from the diagnostic log are retained.
  const unsigned identifiers[] = {41, 42, 3, 4, 5, 6, 8};
  const unsigned values[] = {64, 43, 216, 15, 127, 320, 1270};
  H245_Capability pdu;
  pdu.SetTag(H245_Capability::e_receiveVideoCapability);
  H245_VideoCapability& video = pdu;
  video.SetTag(H245_VideoCapability::e_genericVideoCapability);
  H245_GenericCapability& generic = video;
  generic.m_capabilityIdentifier.SetTag(H245_CapabilityIdentifier::e_standard);
  (PASN_ObjectId&)generic.m_capabilityIdentifier = "0.0.8.241.0.0.1";
  generic.IncludeOptionalField(H245_GenericCapability::e_maxBitRate);
  generic.m_maxBitRate = 40960;
  generic.IncludeOptionalField(H245_GenericCapability::e_collapsing);
  generic.m_collapsing.SetSize(7);
  for (PINDEX i = 0; i < 7; ++i) {
    auto& parameter = generic.m_collapsing[i];
    parameter.m_parameterIdentifier.SetTag(H245_ParameterIdentifier::e_standard);
    (PASN_Integer&)parameter.m_parameterIdentifier = identifiers[i];
    parameter.m_parameterValue.SetTag(i == 0 ? H245_ParameterValue::e_booleanArray
                                             : H245_ParameterValue::e_unsignedMin);
    (PASN_Integer&)parameter.m_parameterValue = values[i];
  }
  H323EndPoint endpoint;
  H323Connection connection(endpoint, 1);
  auto canOpen = [&](XMVideoResolution resolution) {
    auto bridge = std::make_shared<xmeeting::h323::H264MediaBridge>();
    auto capability = xmeeting::h323::makeH264VideoToolboxCapability(bridge, resolution);
    if (!capability->OnReceivedPDU(pdu)) return false;
    std::unique_ptr<H323Codec> encoder(capability->CreateCodec(H323Codec::Encoder));
    const bool opened = encoder->Open(connection);
    require(bridge->isTransmitting() == opened, "Rejected capability activated transmission");
    encoder->Close();
    return opened;
  };
  require(canOpen(XMVideoResolution720p), "BEEHD extended limits rejected 720p at 4096 kbit/s");
  require(canOpen(XMVideoResolutionVGA), "BEEHD extended limits rejected VGA");
  generic.m_maxBitRate = 7680;
  require(!canOpen(XMVideoResolution720p), "Extended limits bypassed the video bitrate ceiling");
  require(canOpen(XMVideoResolutionVGA), "VGA was rejected within BEEHD's 768 kbit/s ceiling");
  generic.m_maxBitRate = 40960;
  (PASN_Integer&)generic.m_collapsing[3].m_parameterValue = 14; // 3584 < 3600 macroblocks
  require(!canOpen(XMVideoResolution720p), "720p exceeded CustomMaxFS");
  (PASN_Integer&)generic.m_collapsing[3].m_parameterValue = 15;
  (PASN_Integer&)generic.m_collapsing[2].m_parameterValue = 215; // 107500 < 108000 MB/s
  require(!canOpen(XMVideoResolution720p), "720p30 exceeded CustomMaxMBPS");
  (PASN_Integer&)generic.m_collapsing[2].m_parameterValue = 216;
  (PASN_Integer&)generic.m_collapsing[0].m_parameterValue = 32; // Main only
  require(!canOpen(XMVideoResolution720p), "Extended limits bypassed Baseline profile matching");
  (PASN_Integer&)generic.m_collapsing[0].m_parameterValue = 64;
  auto reused = xmeeting::h323::makeH264VideoToolboxCapability(
      std::make_shared<xmeeting::h323::H264MediaBridge>(), XMVideoResolution720p);
  require(reused->OnReceivedPDU(pdu), "Could not retain BEEHD receive limits");
  H245_Capability localPdu;
  require(reused->OnSendingPDU(localPdu), "Could not serialize local capability");
  const H245_VideoCapability& localVideo = localPdu;
  const H245_GenericCapability& localGeneric = localVideo;
  require(localGeneric.m_collapsing.GetSize() == 2,
          "Peer custom limits leaked into our advertised receive capability");
  (PASN_Integer&)generic.m_collapsing[1].m_parameterValue = 0;
  require(!canOpen(XMVideoResolution720p), "Unknown mandatory level accepted with extensions");
  (PASN_Integer&)generic.m_collapsing[1].m_parameterValue = 43;
  generic.m_collapsing.SetSize(2); // Same level, no extensions: neither output fits.
  require(!canOpen(XMVideoResolution720p) && !canOpen(XMVideoResolutionVGA),
          "A low base level without extensions was treated as HD-capable");
  require(reused->OnReceivedPDU(pdu), "Could not update receive limits");
  std::unique_ptr<H323Codec> updated(reused->CreateCodec(H323Codec::Encoder));
  require(!updated->Open(connection), "Removed custom limits survived capability update");
}

void testCodecRoundTrip(H323Capability& capability,
                        const std::shared_ptr<xmeeting::h323::H264MediaBridge>& bridge) {
  std::unique_ptr<H323Codec> encoder(capability.CreateCodec(H323Codec::Encoder));
  std::unique_ptr<H323Codec> decoder(capability.CreateCodec(H323Codec::Decoder));
  require(encoder != nullptr && decoder != nullptr,
          "The H.264 capability did not create both codec directions");

  H323EndPoint endpoint;
  H323Connection connection(endpoint, 1);
  require(encoder->Open(connection), "The H.264 transmitter did not open");
  require(decoder->Open(connection), "The H.264 receiver did not open");

  xmeeting::media::H264AccessUnit received;
  bridge->setReceiveHandler([&received](const xmeeting::media::H264AccessUnit& value) {
    received = value;
  });

  xmeeting::media::H264AccessUnit original = {
      {0x67, 0x42, 0x00, 0x1e}, {0x68, 0xce, 0x3c, 0x80}};
  original.emplace_back(73, 0x55);
  original.back()[0] = 0x65;
  require(bridge->enqueueAccessUnit(original, 16),
          "The active H.264 transmitter rejected an access unit");

  unsigned sequence = 0;
  while (received.empty()) {
    BYTE payload[2000]{};
    unsigned length = 0;
    RTP_DataFrame frame(2000);
    require(encoder->Read(payload, length, frame),
            "The H.264 transmitter stopped before the frame marker");
    frame.SetSequenceNumber(sequence++);
    frame.SetTimestamp(9000);
    unsigned written = 0;
    require(decoder->Write(payload, length, frame, written),
            "The H.264 receiver rejected a generated RTP payload");
    require(written == length, "The H.264 receiver did not consume the RTP payload");
  }
  require(received == original, "The H323Plus codec round trip changed a NAL unit");

  for (unsigned i = 0; i < 3; ++i)
    require(bridge->enqueueAccessUnit(original, 16), "A bounded transmit queue rejected a frame early");
  require(!bridge->enqueueAccessUnit(original, 16), "The transmit queue grew beyond three frames");
  for (unsigned frames = 0; frames < 3;) {
    BYTE payload[2000]{};
    unsigned length = 0;
    RTP_DataFrame frame(2000);
    require(encoder->Read(payload, length, frame), "A queued frame disappeared");
    frames += frame.GetMarker() ? 1 : 0;
  }
  require(!bridge->enqueueAccessUnit({{0x41, 0x11}}, 16),
          "Predicted video resumed after a dropped reference frame");
  require(bridge->enqueueAccessUnit(original, 16), "An IDR did not recover the transmit queue");

  encoder->Close();
  decoder->Close();
  require(!bridge->isTransmitting() && !bridge->isReceiving(),
          "Closing the H.264 codecs left the media bridge active");
  require(!bridge->enqueueAccessUnit(original, 16),
          "An idle H.264 bridge retained a camera frame");

  std::string bridgeError;
  bridge->setErrorHandler([&bridgeError](const std::string& value) {
    bridgeError = value;
  });
  require(!bridge->enqueueAccessUnit(original, 2001),
          "The H.264 bridge accepted a payload larger than its channel buffer");
  require(!bridgeError.empty(), "The oversized H.264 payload was not diagnosed");
}

void testCameraGate() {
  auto bridge = std::make_shared<xmeeting::h323::H264MediaBridge>();
  auto capability = xmeeting::h323::makeH264VideoToolboxCapability(bridge);
  H323EndPoint endpoint;
  H323Connection connection(endpoint, 1);
  std::unique_ptr<H323Codec> encoder(capability->CreateCodec(H323Codec::Encoder));
  bridge->setTransmissionEnabled(false);
  require(encoder->Open(connection), "A camera-off channel could not negotiate");
  require(!bridge->enqueueAccessUnit({{0x65, 0x11}}), "Camera-off leaked a frame on channel open");
  bridge->setTransmissionEnabled(true);
  require(bridge->enqueueAccessUnit({{0x65, 0x11}}), "Initial IDR was not accepted");
  bridge->setTransmissionEnabled(false);
  require(!bridge->enqueueAccessUnit({{0x65, 0x22}}), "Camera-off accepted a new frame");
  bridge->setTransmissionEnabled(true);
  require(!bridge->enqueueAccessUnit({{0x41, 0x33}}), "Camera resumed before an IDR");
  require(bridge->enqueueAccessUnit({{0x65, 0x44}}), "Fresh IDR did not resume transmission");
  BYTE bytes[2000];
  unsigned length = 0;
  RTP_DataFrame frame;
  require(encoder->Read(bytes, length, frame) && length == 2 && bytes[1] == 0x44,
          "A frame queued before camera-off was transmitted on resume");
  bridge->setTransmissionEnabled(false);
  encoder->Close();
  require(!bridge->isTransmitting(), "Camera-off blocked channel shutdown");
}

}  // namespace

int main() {
  TestProcess process;
  testBeeHDReceiveLimits();
  testProfileIsolationAndLimits();
  testCameraGate();
  auto bridge = std::make_shared<xmeeting::h323::H264MediaBridge>();
  std::unique_ptr<H323Capability> capability =
      xmeeting::h323::makeH264VideoToolboxCapability(bridge);
  require(capability != nullptr, "The native H.264 capability was not created");
  testCapabilityPdu(*capability);
  testCodecRoundTrip(*capability, bridge);
  std::cout << "H323Plus H.264 bridge tests passed\n";
  return 0;
}
