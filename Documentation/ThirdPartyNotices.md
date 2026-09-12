# XMeeting binary distribution notices

XMeeting's license is included as `XMeeting.txt` in this directory. Copyright
notices in individual source files remain in the corresponding source archive.

This app statically includes PTLib v2_10_9_6 and H323Plus v1_28_0 from
[willamowius/ptlib](https://github.com/willamowius/ptlib) and
[willamowius/h323plus](https://github.com/willamowius/h323plus), with the patches
listed in `Dependencies.txt`. Their upstream license texts are included as
`PTLib-MPL-1.0.html`, `H323Plus-MPL-1.0.html`, and `H323Plus-MPL-1.1.html`.
Consult the source files for their individual copyright and license notices,
including third-party code incorporated by those libraries.

The matching `XMeeting-…-source.tar.gz` release asset provides the exact XMeeting
revision, original dependency source archives (including their notices), all
local patches, and the build script. It is available alongside the binary ZIP
on the same GitHub release. When redistributing the ZIP privately, include that
source archive too, so recipients have the source and modifications available.

Apple's system frameworks provide H.264 encoding/decoding and device access.
They are not redistributed in this archive. This build does not bundle FFmpeg,
x264, or external H323Plus codec plugins.
