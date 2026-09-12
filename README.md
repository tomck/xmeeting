# XMeeting

This repository preserves the final SourceForge SVN history of XMeeting and is
the basis for a new H.323-only macOS application.

The modernization branch targets macOS 11 and later on Intel and Apple Silicon.
Its new application preserves XMeeting's compact call workflow and original
artwork while using PTLib and H323Plus instead of the historical OpenH323/OPAL
integration. The original application target is retained as migration reference
and does not build against current macOS SDKs.

The modern alpha can place and receive H.323 calls with built-in G.711 A-law or
µ-law audio through the system's CoreAudio input and output devices. Experimental
H.264 video now connects AVFoundation capture, VideoToolbox encode/decode, and
H323Plus RTP. Local calls and two calls to a Linux test peer verify video in both
directions, including independent FFmpeg decoding on Linux. Remote video display
and the local picture-in-picture preview have also been confirmed by a user.
Linux independently decoded 434 frames from a physical-camera call without
errors. **XMeeting > Settings…** now selects VGA (640x480) or 720p (1280x720)
outgoing video. Output is resized to the selected format and uses a matching
H.264 encoding level; incoming video can still be up to 720p in either mode.
Physical-camera checks of both settings modes, broader interoperability,
audio-device selection, and release signing remain in progress. See the
[video verification guide](Documentation/VideoTesting.md) for reproducible tests
and the limits of the current evidence.

See [Documentation/Modernization.md](Documentation/Modernization.md) for the
dependency build, smoke tests, implemented protocol boundary, and remaining
application migration work.

## Test builds

The [macOS alpha workflow](.github/workflows/macos-alpha.yml) builds a universal
download and tests the same video-call binaries on Intel and Apple Silicon.
Version tags publish experimental prereleases after both checks pass; ordinary
branch builds only upload Actions artifacts. See the
[tester instructions](Documentation/AlphaTesting.md) and
[release procedure](Documentation/Releasing.md). These builds are not yet
Developer ID signed or notarized, and Internet NAT traversal is not configured.

## Commit attribution

Enable the version-controlled Git hook once per checkout:

```sh
git config --local core.hooksPath .githooks
```

Codex commits use `Scripts/codex-commit.sh` with explicit `--model`,
`--reasoning-effort`, and `--thread` values before `--` and the usual Git commit
arguments. The hook records the Codex co-author and supplied provenance; it
does not infer the model or cryptographically sign the commit. Ordinary human
commits are unchanged. The hook and wrapper follow the
[WhatChanged attribution workflow](https://github.com/tomck/WhatChanged/blob/main/.githooks/prepare-commit-msg).
