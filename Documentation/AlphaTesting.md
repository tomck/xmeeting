# XMeeting experimental Mac build

For volunteer testing, not a stable release. Targets macOS 11 and later on
Intel and Apple Silicon. Automated tests cover both processor types, including
VGA, 720p, and mixed-resolution video calls with synthetic media. That is not
proof of physical camera/microphone quality or compatibility with every macOS
release and H.323 endpoint; macOS 11 and independent endpoint testing remain open.

## Install

Download `XMeeting-…-macos-universal.zip` (not GitHub's source-code ZIP).
Unzip it and move `XMeeting.app` to Applications. The adjacent `Build.txt`
identifies the source commit; `SHA256SUMS.txt` contains checksums of the downloads.

This alpha is ad-hoc signed, **not Developer ID signed or notarized by Apple**.
Only proceed if you trust the source. macOS may block the first launch. After
attempting to open it, use System Settings → Privacy & Security → Open Anyway
(System Preferences → Security & Privacy on older macOS). See
[Apple's guidance](https://support.apple.com/en-us/102445).
Do not disable Gatekeeper globally. If macOS reports malware or that the app
is damaged, stop and report the exact message instead of bypassing it.

Allow microphone and camera access when requested, and incoming connections
if the macOS application firewall asks. Headphones help avoid audio feedback.
Allowing an app through the Mac firewall does not configure your home router.

## Make a test call

1. Put both computers on the same LAN, or on a trusted VPN that allows direct
   traffic between them. Use each other's reachable LAN/VPN address, not a
   private home address that cannot be reached from the other network.
2. Set your local alias. In XMeeting → Settings… choose VGA (640×480) first;
   720p (1280×720) can be tested next. Change this while idle, not during a call.
3. Enter the other computer's address and click Call. The receiving user
   accepts the call. Both users should see remote video plus their local preview
   and confirm they can hear each other.
4. Hang up, redial, then reverse the calling direction. Repeat with 720p, and
   with one person on VGA and the other on 720p. Also try an audio-only peer.

Record the build from `Build.txt`, Mac model/processor, macOS version, camera,
chosen resolution, other endpoint, and whether audio/video worked each way.
Include the status message for failures. Do not post private recordings or
unredacted network traces. Longer calls and repeated hangup/redial are useful.

## Network and privacy limits

This alpha does not provide a public directory, a configured traversal service,
automatic router port forwarding, or end-to-end call encryption. Prefer a
trusted LAN or encrypted private VPN for initial testing. Do not expose it
directly to the Internet or open broad router port ranges as a shortcut.

The planned Internet-calling path is a separately configured H.323 gatekeeper
with H.460.18/.19 traversal and media relay, plus app settings and testing for
it. A gatekeeper can locate registered users and relay calls through NAT; a
conference mixer is a separate feature. This is not enabled merely by downloading
this alpha. [GNU Gatekeeper's routed-mode and traversal documentation](https://www.gnugk.org/gnugk-manual-5.html).

H.245 tunneling is enabled by default in our H323Plus endpoint. It carries codec
negotiation and media-channel control inside H.225 call signaling, avoiding a
separate H.245 TCP connection when the peer supports tunneling. It does not carry
the actual audio/video RTP stream and is not encryption or a substitute for NAT
traversal. H.460.18/.19 addresses the separate signaling/media traversal problem.

## Source and licenses

The adjacent `XMeeting-…-source.tar.gz` contains the exact app source, pinned
upstream PTLib/H323Plus source archives, our dependency patches, and build
instructions. See `Licenses/` in the binary download. No external FFmpeg, x264,
or codec plugins are required; H.264 uses Apple's VideoToolbox.

Releases in a private GitHub repository require repository access. The owner
can alternatively share the complete binary ZIP and matching source archive.
