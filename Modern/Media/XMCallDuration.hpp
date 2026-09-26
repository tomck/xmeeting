#pragma once

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>

namespace xmeeting::media {

// The caller supplies monotonic seconds, so clock/time-zone changes do not
// alter an established call's duration. Ringing time is never counted.
class CallDuration {
 public:
  void reset() { started_ = running_ = false; elapsed_ = 0; }
  void start(double now) {
    if (started_) return;
    started_ = running_ = true;
    start_ = now;
  }
  void stop(double now) {
    if (running_) elapsed_ = elapsed(now);
    running_ = false;
  }
  bool running() const { return running_; }
  double elapsed(double now) const {
    return running_ ? std::max(0.0, now - start_) : elapsed_;
  }
  std::string display(double now) const {
    if (!started_) return "--:--";
    const double duration = elapsed(now);
    const auto seconds = static_cast<unsigned long long>(std::isfinite(duration)
        ? std::clamp(duration, 0.0, 315360000.0) : 0.0);
    char text[32];
    if (seconds >= 3600)
      std::snprintf(text, sizeof(text), "%llu:%02llu:%02llu", seconds / 3600, seconds / 60 % 60, seconds % 60);
    else
      std::snprintf(text, sizeof(text), "%02llu:%02llu", seconds / 60, seconds % 60);
    return text;
  }

 private:
  bool started_ = false, running_ = false;
  double start_ = 0, elapsed_ = 0;
};

} // namespace xmeeting::media
