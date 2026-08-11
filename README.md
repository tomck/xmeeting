# XMeeting

This repository preserves the final SourceForge SVN history of XMeeting and is
the basis for a new H.323-only macOS application.

The modernization branch targets macOS 14 and later on Intel and Apple Silicon.
Its new protocol layer uses PTLib and H323Plus instead of the historical
OpenH323/OPAL integration. The original application target is retained as
migration reference and does not yet build against current macOS SDKs.

See [Documentation/Modernization.md](Documentation/Modernization.md) for the
dependency build, smoke tests, implemented protocol boundary, and remaining
application migration work.
