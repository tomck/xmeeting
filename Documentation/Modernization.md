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
configuration for Apple Silicon.

```sh
./Scripts/build-h323plus-universal.sh
cmake -S Modern -B .build/modern
cmake --build .build/modern
.build/modern/h323plus-smoke --help
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
handling, and call-state feedback. Audio and video media are not connected yet.

## Remaining application migration

The command-line smoke target verifies the new protocol dependency and adapter;
the legacy `XMeeting` app target is not compatible with current SDKs. These
independent removals are still required:

1. Define the supported codec set, build/package the corresponding universal
   H323Plus media plugins, and bridge their audio/video paths to the application.
2. Establish an interoperable G.711 audio call and add audio device selection.
3. Replace QuickTime 7 Sequence Grabber, compression, decompression, packetizer,
   and recorder APIs with AVFoundation, VideoToolbox, and CoreMedia.
4. Replace AddressBook with Contacts and add permission-aware asynchronous
   access.
5. Replace legacy OpenGL/GLUT presentation with Metal or modern Core Animation.
6. Convert the old nibs/project target, adopt ARC, add hardened-runtime signing,
   and run call interoperability tests on physical Intel and Apple Silicon Macs.

`Config/Modern.xcconfig` and `Config/H323Plus.xcconfig` hold the settings for new
targets, including `XMEETING_H323_ONLY=1`. They are deliberately not attached to
the legacy target: doing so would make the project appear modern while it still
imports removed QuickTime headers and OPAL-only H.323 APIs.
