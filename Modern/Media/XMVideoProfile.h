#pragma once

// Shared by capture, VideoToolbox and H.241 signaling. Values also identify
// the saved user preference; do not renumber them.
typedef enum XMVideoResolution {
  XMVideoResolutionVGA = 0,
  XMVideoResolution720p = 1,
} XMVideoResolution;

typedef struct XMVideoProfile {
  unsigned width;
  unsigned height;
  unsigned framesPerSecond;
  unsigned bitRate;
  unsigned levelIDC;
  unsigned h241Level;
} XMVideoProfile;

static inline int XMVideoResolutionIsValid(XMVideoResolution resolution) {
  return resolution == XMVideoResolutionVGA || resolution == XMVideoResolution720p;
}

static inline XMVideoProfile XMVideoProfileForResolution(XMVideoResolution resolution) {
  if (resolution == XMVideoResolution720p) {
    const XMVideoProfile profile = {1280, 720, 30, 1500000, 31, 71};
    return profile;
  }
  const XMVideoProfile profile = {640, 480, 30, 512000, 30, 64};
  return profile;
}
