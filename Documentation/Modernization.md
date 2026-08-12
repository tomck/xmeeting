# XMeeting modernization

## Supported baseline

New code targets macOS 11 (Big Sur) or later, C++17, and the standard macOS
architectures (`x86_64` and `arm64`). This includes every Apple Silicon Mac and
extends support to older 64-bit Intel Macs. The dependency baseline is pinned to:

- PTLib 2.10.9.6
- H323Plus 1.28.0
- Apple Clang and the active macOS SDK supplied by Xcode

`Scripts/build-h323plus-universal.sh` builds both dependency slices from the
official tagged repositories and combines them into static universal libraries.
The PTLib patch in `Dependencies/patches` adds the missing 64-bit little-endian
configuration for Apple Silicon. A second, narrowly scoped H323Plus patch makes
transport cleanup wait until an outbound call thread has actually terminated;
upstream 1.28.0 otherwise deletes the thread and its connection after a
10-second cleanup timeout while the thread can still be running.

```sh
./Scripts/build-h323plus-universal.sh
cmake -S Modern -B .build/modern
cmake --build .build/modern
.build/modern/h323plus-smoke --help
.build/modern/h323plus-smoke --audio-info
.build/modern/h323plus-cocoa-smoke 18201
open .build/modern/XMeeting.app
```

The dependency output is generated at
`.build/h323plus/macos-universal`. Override the deployment target, output path,
or architectures with `XMEETING_DEPLOYMENT_TARGET`,
`XMEETING_H323PLUS_OUTPUT_ROOT`, or `XMEETING_ARCHITECTURES`.

## Why this is not a library rename

The checked-in application does not directly use the OpenH323 API. Its H.323
implementation subclasses the 2006 OPAL classes `OpalManager`, `OpalConnection`,
and `OpalMediaStream`. H323Plus preserves the standalone OpenH323 API instead:
`H323EndPoint` has no `OpalManager`, and its connection and media callbacks are
different. H323Plus also does not provide SIP.

`Modern/H323Plus/XMH323PlusEngine` is therefore an OPAL-free adapter. It already
provides listener startup, outgoing calls, incoming answer/reject, hangup,
gatekeeper registration, call metadata, and lifecycle callbacks. Its public
header intentionally exposes no PTLib or H323Plus types, so it can be bridged to
Objective-C without importing colliding OPAL H.323 declarations.

The modern product is intentionally H.323-only. SIP remains available in many
maintained macOS clients and is not carried forward here. The `sip:` URL scheme
and modern build feature have been removed; the old SIP/OPAL sources remain only
as historical migration reference and are not part of a modern target.

`Modern/Cocoa/XMH323Client` is the ARC-compatible Foundation facade used by new
application code. It owns PTLib process initialization, keeps C++ types private,
and delivers H.323 call and gatekeeper events to its delegate on the main queue.
It rejects `sip:` addresses at the API boundary so an old preference or URL
cannot silently route into H323Plus as an invalid H.323 destination.

`Modern/App` is the new ARC AppKit application shell. It deliberately preserves
XMeeting's compact call-window layout and original iconography while replacing
the implementation underneath. The current milestone starts a real H.323
listener and supports outgoing calls, incoming accept/reject, hangup, H.323 URL
handling, and call-state feedback. It advertises only the built-in G.711 A-law
and µ-law codecs, force-loads PTLib's native CoreAudio driver, selects the
system-default input and output devices, and requests microphone access before
enabling calls. It refuses to place or answer a call when PTLib exposes only its
silent `NullAudio` test device. Video media is not connected yet.

`h323plus-smoke --audio-info` reports the selected devices and advertised
codecs. Its `--null-audio` option exists only for automated/local loopback tests.
A two-endpoint loopback has verified call establishment, bidirectional G.711
logical-channel startup, clean channel shutdown, and hangup without requiring
physical audio hardware. A real-device call to an independent H.323 product is
still required before audio interoperability is considered release-tested.

## Remaining application migration

The modern app is now at the first audio-capable alpha milestone; the legacy
`XMeeting` app target remains only as a design and behavior reference because it
is not compatible with current SDKs. Work remaining for a useful public release
is prioritized as follows:

1. Test G.711 calls against independent H.323 endpoints using real microphones
   and speakers on physical Intel and Apple Silicon Macs; fix device-change,
   permission, echo, failure-reporting, and reconnect behavior found there.
2. Add input/output device selection, mute, output level, ringtone, and useful
   call-duration/end-reason feedback.
3. Add a preferences UI for listener ports, gatekeeper accounts, and the H.460/
   STUN settings needed to work reliably beyond a local network.
4. Replace the QuickTime 7 capture/compression path with AVFoundation,
   VideoToolbox, and CoreMedia; package a deliberately small universal video
   codec set and display it with modern Core Animation or Metal.
5. Replace AddressBook with Contacts and add permission-aware asynchronous
   access if preserving the historical address-book workflow remains valuable.
6. Add automated regression tests, hardened-runtime signing, notarization,
   packaging, and a compatibility matrix covering macOS 11 through current
   releases on both architectures.

`Config/Modern.xcconfig` and `Config/H323Plus.xcconfig` hold the settings for new
targets, including `XMEETING_H323_ONLY=1`. They are deliberately not attached to
the legacy target: doing so would make the project appear modern while it still
imports removed QuickTime headers and OPAL-only H.323 APIs.
