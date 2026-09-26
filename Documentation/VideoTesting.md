# Experimental H.264 video verification

The native path connects AVFoundation capture, VideoToolbox H.264 Baseline,
an H.241 capability, RFC 6184 RTP, VideoToolbox decoding, and AppKit display.
Local preview alone does not prove a video call. Capability advertisement is explicitly enabled
after the application produces an encoded access unit. A camera-free black-frame
preflight validates the codec so a call started with camera-off can still negotiate
video for later use. This does not request camera access or start capture.

## Video settings

Choose **XMeeting > Settings… > Outgoing video resolution** (Command-comma).
VGA is the default. The selection is saved automatically, applies before the
next call, and cannot be changed while a call is active or connecting.

| Output | Dimensions | H.264 Baseline level | Bitrate target | Maximum frame rate |
| --- | --- | --- | --- | --- |
| VGA | 640x480 | 3.0 | 512 kbit/s | 30 fps |
| 720p | 1280x720 | 3.1 | 1.5 Mbit/s | 30 fps |

Capture requests the selected preset after attaching the actual camera.
VideoToolbox then scales and letterboxes input into a fixed-size pixel buffer,
so a camera providing a different native format cannot silently change the
encoded output. Configuration errors prevent video enablement. Incoming video
can be up to 720p regardless of the selected outgoing resolution.

The open-channel description uses the actual output profile; the advertised
receive ceiling is Baseline 3.1. The H.241 level values are 64 (3.0) and 71 (3.1),
as specified by [H.241, Table 8-4](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.241-200605-S%21%21PDF-E&lang=e&type=items).
The encoder checks the peer's Baseline profile, frame-size/processing limits,
and bitrate ceiling. Frame limits include H.241 CustomMaxFS and CustomMaxMBPS
extensions rather than rejecting a receiver solely for a lower base level.
If an older endpoint cannot receive 720p, select VGA and redial;
automatic mid-call resolution adaptation is not implemented.

### BEEHD interoperability regression

The capability test includes a sanitized BEEHD receive offer: base H.241 level
43, CustomMaxMBPS 216, CustomMaxFS 15, and maxBitRate 40960. Its extended
frame limits allow 720p30 even though the base level alone does not. Tests also
reject insufficient frame size, processing rate, bitrate, or profile, and check
that peer extensions neither leak into local advertisements nor survive removal.

This fixes the observed local transmit-channel opening rejection; it does not
prove end-to-end BEEHD decoding. Repeat an iPhone-to-Mac call with BEEHD at
4096 kbit/s, Rx 720p enabled, and Net Sense disabled. Check Mac video on the
iPhone as well as phone video on the Mac, then hang up and redial. Packetization
compatibility and decoder-buffer constraints remain separate interoperability
checks; this patch does not change packetization or encoder bitrate.

## Devices and Fast Start

XMeeting → Settings… (Command-comma) selects the camera, microphone, and
speakers, with **System Default** available for each. Camera choices are saved
by AVFoundation unique ID. The current PTLib CoreAudio backend selects audio
devices by name; devices with duplicate names must be renamed in macOS before
they can be selected safely. An unavailable saved device stays selected and
is reported; XMeeting does not silently switch to a different microphone or camera.
Reconnect it and click **Refresh Devices**, or choose another device.
Audio device/default changes are detected while idle. Settings are locked
while a call is connecting, ringing, or active. Camera changes restart local preview.

**Enable H.225 Fast Start** is checked by default and saved automatically.
H323Plus offers media channels during H.225 call setup, with ordinary H.245
negotiation as fallback. H.245 tunneling remains enabled. This option is classic
Fast Start, not H.460.6 Extended Fast Connect, encryption, or NAT traversal.
Fast Start reverse-channel offers advertise our 720p receive ceiling, independently
of the chosen outgoing camera resolution; transmitter descriptions use the
actual outgoing profile.

For a physical-device check, choose each camera and confirm local preview;
choose a microphone and speakers, make a short call, and confirm audio both
ways. Hang up, change devices, and redial. Relaunch to check saved selections.
Unplug an explicitly selected device while idle and confirm that it is reported
as unavailable, with no unexpected input substituted; reconnect and refresh.
Repeat calls with Fast Start checked and unchecked, and with only one peer
enabling it. These manual checks supplement synthetic tests, not replace them.

## In-call controls

The compact bar below video has **Mic On / Mic Muted**, **Camera On / Camera Off**,
and elapsed connected time. Shift-Command-M toggles microphone mute;
Shift-Command-V toggles the camera. The same actions are in the Call menu.

Microphone mute replaces captured PCM with silence before G.711 encoding;
it does not change the Mac's global input level or mute incoming sound. The
microphone remains open for quick unmute, and RTP continues with encoded silence.
Camera-off closes the outgoing frame gate, flushes queued video, and stops
AVFoundation capture. Incoming video continues; some peers retain the last
received picture. Resume uses a new encoder and a fresh IDR, not queued old frames.
Already transmitted network packets cannot be recalled by either control.

Controls work before dialing and during a call. Their choices survive hangup,
redial, and device/settings changes within the same app session; a fresh launch
starts unmuted with the camera enabled. The timer starts on establishment, not
during ringing, freezes on hangup, and resets on the next call attempt.

Manual check: make a short call, confirm the other party stops hearing you when
muted, and verify you still hear them. Turn the camera off and verify the Mac's
camera indicator goes out and the other endpoint receives no live motion. Resume
both without redialing. Repeat after hanging up while muted/camera-off, and check
the timer's start, stop, and reset behavior. Physical-device checks are still
needed on both processor types and macOS 11.

## Automated macOS tests

From the repository root, with the universal H323Plus SDK already built:

```sh
cmake -S Modern -B .build/call-verification -DBUILD_TESTING=ON
cmake --build .build/call-verification -j 2
ctest --test-dir .build/call-verification --output-on-failure
.build/call-verification/h323plus-cocoa-smoke 29642
codesign --verify --deep --strict .build/call-verification/XMeeting.app
```

VideoToolbox and the network tests need normal macOS media/socket access; a
restricted execution sandbox can prevent CoreVideo allocation or listeners.
Tests use generated video and silence or a generated audio tone, without camera
or microphone access. The tone/counter sound device exists only in the test binary.

| Test | What it checks |
| --- | --- |
| `xmeeting-call-duration-tests` | Establishment-only timing, duplicate callbacks, frozen hangup duration, redial reset, minute/hour formatting |
| `xmeeting-h264-rtp-tests` | AVCC conversion, single-NAL/FU-A, receive STAP-A, truncated input, sequence gaps/wrap, timestamp boundaries, and receive size limits |
| `xmeeting-h323plus-h264-tests` | Per-profile signaling, independent receive limits, unsupported-level/bitrate rejection, real codec Read/Write, shutdown, bounded queue, IDR recovery |
| `xmeeting-videotoolbox-tests` | BGRA/NV12 camera-size normalization into both output sizes, actual SPS profile/level, decoded dimensions, duplicate-timestamp suppression |
| `xmeeting-h264-call-tests` | Two consecutive calls between real H323Plus endpoints, bidirectional RTP/VideoToolbox decode, G.711 channels, hangup, and redial |
| `xmeeting-h264-720p-call-tests` | The same two-call checks with 720p output in both directions |
| `xmeeting-h264-mixed-call-tests` | Two calls with VGA output at one end and 720p output at the other |
| `xmeeting-h264-reverse-mixed-call-tests` | The same Fast Start test with a 720p caller and VGA callee |
| `xmeeting-h264-slow-mixed-call-tests`, `xmeeting-h264-slow-reverse-mixed-call-tests` | Both mixed-resolution directions with Fast Start disabled |
| `xmeeting-h264-slow-call-tests` | Both endpoints disable Fast Start; audio and video use ordinary H.245 negotiation |
| `xmeeting-h264-slow-caller-tests`, `xmeeting-h264-slow-callee-tests` | Fast Start fallback when only one endpoint enables it |
| `xmeeting-audio-fast-call-tests`, `xmeeting-audio-slow-call-tests` | Two audio-only calls, with and without Fast Start |
| `xmeeting-call-settings-tests` | Default/toggled Fast Start, idle-only configuration, real audio enumeration, missing-device rejection, default recovery |
| `xmeeting-call-controls-tests`, `xmeeting-slow-call-controls-tests` | Far-end decoded silence and video stop/resume in both directions, pre-muted dialing, retained controls on redial, hangup while camera-off, with and without Fast Start |

The call test uses temporary high listener ports, has a 50-second CTest timeout,
and requires at least ten decoded frames at each endpoint in each video call.
It also checks whether Fast Start was actually negotiated, not just requested.
The audio-only cases require G.711 channels in both directions. It can
also call an explicitly supplied remote peer:

```sh
.build/call-verification/xmeeting-h264-call-tests --peer 192.168.0.31:18222
```

In remote mode, the Mac verifies received video and its outgoing channel.
Separately decode the peer's recording to verify the Mac-to-Linux direction.

## Isolated Linux fixture peer

The existing `XMeetingTest` service is an audio baseline. A video input driver
such as `FakeVideo` does not itself supply an H.264 codec. The test VM's original
plugin build disabled H.264 because its codec dependencies were absent.

`Modern/H323PlusTests/H264TestPeer.cpp` is a bounded, headless test endpoint that
uses the native H323Plus bridge. It repeatedly sends a generated IDR frame and
writes received NAL units in Annex-B format. It needs no camera, display, or
codec libraries of its own. Debian FFmpeg supplies independent H.264 encoding
and decoding for the fixture. This validates media across different codecs and
operating systems; both endpoints still share the H323Plus/bridge implementation.

Create a new staging directory on the Linux host. Copy these files into it:

- `Modern/H323PlusTests/H264TestPeer.cpp` and `Makefile.linux`
- `Modern/H323Plus/XMH323PlusH264.cpp` and `.hpp`
- `Modern/Media/XMH264RTP.cpp`, `.hpp`, and `XMVideoProfile.h`

With the VM's existing PTLib/H323Plus builds and Debian's `ffmpeg` installed:

```sh
make -f Makefile.linux PTLIBDIR=/home/tom/ptlib OPENH323DIR=/home/tom/h323plus \
  P_SHAREDLIB=0 DEBUG= default_target -j2
ffmpeg -v error -f lavfi -i testsrc2=size=640x480:rate=10 -frames:v 1 \
  -c:v libx264 -profile:v baseline -level:v 3.0 -preset ultrafast \
  -tune zerolatency -x264-params keyint=1 -f h264 test-frame.h264
./obj_linux_x86_64_s/h264-test-peer -i test-frame.h264 -o received.h264 -x 18222 -s 120
```

For a 720p fixture, generate `testsrc2=size=1280x720:rate=10` with `-level:v 3.1`
and run the peer with `-r 720p`. The default is `-r vga`. Use the matching mode
for the Mac test (`xmeeting-h264-call-tests --720p --peer host:port`).

Place the call during that 120-second interval. Use a fresh output filename for
each run; the peer writes the specified recording file. It exits automatically
and does not register with the gatekeeper or replace the port-1720 audio service.
After the run, require error-free decoding and a nonzero decoded frame count:

```sh
ffmpeg -v error -xerror -i received.h264 -f null -
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=codec_name,width,height,nb_read_frames -of json received.h264
```

## Status and remaining release checks

On 2026-09-09 all four local tests passed on the Intel Mac, including two actual
H.323/RTP calls. The rebuilt app passed strict signature verification and
contains both `x86_64` and `arm64` slices. The fixture peer also builds on Debian
13 against the VM's existing static PTLib/H323Plus libraries. Two calls to its
port 18222 completed with G.711 channels and ten decoded Linux test-pattern
frames per call on the Mac. The Linux peer reported 19 received access units
and zero bridge errors. FFmpeg independently decoded the recording with
`-v error -xerror` without errors; ffprobe counted all 19 frames at 640x480.
Both calls cleared cleanly, and the original port-1720 audio service stayed
active. An intermittent VM network stall required a guest reboot before the
recording could be checked; it is not established as an application failure.

The user subsequently confirmed a connected call with visible video in the
rebuilt AppKit application against the Linux visual test endpoint. This adds
user-confirmed remote display to the automated media tests. The user also
confirmed successful GUI hangup and redial, and supplied a screenshot showing
the Linux test pattern during a connected call. Incoming camera data was
discarded during that initial visual test.

On 2026-09-10 the lower-left local-preview inset was built in
`.build/pip-verification/XMeeting.app` for both architectures and passed strict
signature verification. The user confirmed that the local-preview inset looks
correct during the call.

A subsequent physical-camera call on 2026-09-10 was received by the Linux
fixture peer and independently decoded with FFmpeg using `-v error -xerror`.
It decoded 434 H.264 Baseline frames without errors; ffprobe independently
reported 434 frames at 1280x720. The private temporary clip was deleted after
verification and the temporary listener stopped. This confirms actual camera
transmission to Linux as well as remote test-pattern display on the Mac; it
does not establish interoperability with an independent H.323 stack.

That 1280x720 output revealed that the earlier camera preset did not enforce
the configured VGA format. The new fixed-size encoder input and shared output
profiles address this mismatch. Repeat a physical-camera call in each settings
mode to verify the full device/UI path in addition to the synthetic tests.

On 2026-09-11 all six tests passed on the Intel Mac, including VGA/VGA,
720p/720p, and mixed VGA/720p two-call loops. Synthetic 1280x720 NV12 and
1920x1080 BGRA inputs decoded at the selected VGA output size; VGA BGRA and
720p NV12 inputs decoded at the selected 720p size. The tests also checked the
actual encoded SPS profile/level and rejected unsupported peer limits. Both
settings selections were visually checked in the native settings window.

On 2026-09-12 all 15 cases passed locally on Intel after adding Fast Start
and device settings. This included both mixed-resolution call directions,
Fast Start fallback, audio-only calls, hangup/redial, and a delayed-answer
check that audio channels did not start before acceptance. CoreAudio device
enumeration, explicit selection, unavailable-device rejection, and default
recovery passed without opening physical audio devices. Settings were visually
checked with Fast Start on/off and unavailable saved selections. The ad-hoc
signature verified, and both universal slices report macOS 11.0 as minimum.
The workflow includes all cases on Apple Silicon, but this new revision has
not yet run there or in a physical-device call.

For a visual camera call, run the peer with `-o /dev/null` to discard incoming
video, open the rebuilt app, wait for "Ready for H.323 audio and H.264 video
calls," then dial `192.168.0.31:18222`. The large video area should show the
Linux test pattern, with the local camera in a bordered lower-left inset,
matching the original XMeeting picture-in-picture layout.
Hang up and check that the local preview returns to full size, then redial.
The plain address `192.168.0.31` still reaches the
existing audio-only endpoint on port 1720.

On 2026-09-13 all 18 tests passed on Intel with the new call controls. The two
control-call cases also passed a strengthened rerun requiring at least ten
new decoded frames after each resume, in addition to audible received test
audio. Generated-tone calls verified decoded silence while muted, no new
outgoing video while camera-off, continued media in the opposite direction,
and preservation of controls across hangup/redial with Fast Start on and off.
Camera-free VGA/720p codec preflight and timer lifecycle tests passed. The call
window was rendered and visually checked in idle and muted/camera-off states;
both universal slices target macOS 11.0 and the ad-hoc signature verified.
Actual camera-indicator behavior and subjective microphone quality still need
a physical-device call; this revision has not yet run natively on Apple Silicon.

Still required: physical-camera checks of both settings modes, independent H.323 endpoint
interoperability, physical Apple Silicon and
macOS 11 testing, camera/permission changes, and sustained audio/video quality.
RTP discontinuities now discard damaged access units; transmit overflow waits
for an IDR. Fast-update requests and full recovery of predicted frames after
packet loss remain follow-up work. Signing here is development ad-hoc signing,
not distribution signing or notarization.
