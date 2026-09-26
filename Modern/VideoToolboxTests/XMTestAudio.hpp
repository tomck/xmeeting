#pragma once
#include <cstdint>

// A generated-tone / sample-counter fixture. Never opens real audio hardware.
namespace xmeeting::test {
struct AudioSamples { std::uint64_t blocks = 0, audibleBlocks = 0; };
void resetAudioSamples();
AudioSamples audioSamples(bool caller);
}
