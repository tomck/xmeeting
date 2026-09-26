#include "XMCallDuration.hpp"
#include <cstdlib>
#include <iostream>

void require(bool condition, const char* message) {
  if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

int main() {
  xmeeting::media::CallDuration duration;
  require(duration.display(500) == "--:--", "Idle or ringing was counted as call time");
  duration.start(500);
  require(duration.display(500.9) == "00:00", "Timer rounded up");
  require(duration.display(565.1) == "01:05", "Minute formatting failed");
  duration.start(560);
  require(duration.display(565.1) == "01:05", "Duplicate establishment reset the timer");
  require(duration.display(4167) == "1:01:07", "Hour formatting failed");
  duration.stop(566);
  require(!duration.running() && duration.display(9999) == "01:06", "Hangup did not freeze elapsed time");
  duration.stop(9999);
  require(duration.display(9999) == "01:06", "Duplicate hangup changed elapsed time");
  duration.reset();
  require(duration.display(9999) == "--:--", "Redial reused the previous duration");
  duration.start(10000);
  require(duration.display(10002) == "00:02", "Redial did not get a fresh clock");
  require(duration.display(9999) == "00:00", "Negative duration was not clamped");
  std::cout << "PASS: call timer establishment, hangup, redial, and formatting\n";
}
