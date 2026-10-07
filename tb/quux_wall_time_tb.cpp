// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's wall clocks against wall time at one tick length, `TICK_PS`
// picoseconds (the harness's parameter, which it reports):
//
//   - the microsecond clock: each increment to n lands within half a tick of
//     n microseconds after the tick it started counting;
//   - interval timer 0, periodic at 7 microseconds: rise n lands within a
//     tick and a half of 7n microseconds after the tick that turned it on;
//   - the real-time clock: seconds and nanoseconds, set at a known instant,
//     equal that instant plus the ticks since, times the tick, to the
//     nanosecond below, at every tick, across a carry into the seconds.
//
// Over 40 ms of wall time, so that a microsecond counted in whole ticks of
// the wrong length is off by many microseconds.  Prints one line, and fails
// on the first disagreement.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vquux_wall_time_harness.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vquux_wall_time_harness;
  d->eval();
  const int64_t tick_ps = d->tick_ps;
  uint64_t t = 0;
  auto step = [&]() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    ++t;
    d->edge_tick = (t % 4) == 3;
  };
  d->rst = 1; d->edge_tick = 0; d->pg_we = 0; d->rtc_we_seconds = 0; d->rtc_we_fraction = 0;
  for (int i = 0; i < 4; ++i) step();
  d->rst = 0;

  // The microsecond clock starts counting once its power-on edges are past,
  // `cadr_tick_pkg::POWER_ON_EDGES` (2) after the reset falls at tick 4: each
  // increment to n is then the tick nearest n microseconds after tick 6.
  const int64_t us_ps = 1000000;
  const int64_t usec_start = 4 + 2;
  uint32_t last_usec = d->usec;
  int64_t worst_us = 0;

  // The timer: period 7, then on, with the interrupt enable.
  const int64_t period = 7;
  int64_t timer_on = -1, rises = 0, worst_tm = 0;
  bool irq_was = false, clear_next = false;

  // The real-time clock: the fraction staged 20 us short of a second, then
  // the seconds; the count starts from the tick the seconds land.
  const uint32_t sec0 = 100, frac0 = 999980000;
  int64_t rtc_set = -1, worst_rtc = 0;

  const int64_t run_ps = 40LL * 1000000000LL;  // 40 ms
  const int64_t ticks = run_ps / tick_ps;
  int fails = 0;
  for (int64_t i = 0; i < ticks && fails < 5; ++i) {
    d->pg_we = 0; d->rtc_we_seconds = 0; d->rtc_we_fraction = 0;
    if (i == 10) { d->pg_we = 1; d->pg_idx = 1; d->pg_wdata = period; }
    if (i == 12) { d->pg_we = 1; d->pg_idx = 0; d->pg_wdata = 0x101; timer_on = (int64_t)t; }
    if (i == 14) { d->rtc_we_fraction = 1; d->rtc_wdata = frac0; }
    if (i == 16) { d->rtc_we_seconds = 1; d->rtc_wdata = sec0; rtc_set = (int64_t)t; }
    if (clear_next) { d->pg_we = 1; d->pg_idx = 0; d->pg_wdata = 0x103; clear_next = false; }
    d->eval();
    // The timer's rise shows in the tick it happens, before its edge.
    bool irq_now = d->irq;
    if (irq_now && !irq_was && timer_on >= 0) {
      ++rises;
      int64_t err = ((int64_t)t - timer_on) * tick_ps - rises * period * us_ps;
      if (std::llabs(err) > worst_tm) worst_tm = std::llabs(err);
      // A rise is the last tick of its period, a tick before the instant, and
      // the period's ticks are the nearest whole ones: half a tick more.
      if (std::llabs(err) > tick_ps + tick_ps / 2) {
        std::printf("FAIL: timer rise %lld at tick %llu, %lld ps from %lld us\n", (long long)rises,
                    (unsigned long long)t, (long long)err, (long long)(rises * period));
        ++fails;
      }
      clear_next = true;
    }
    irq_was = irq_now;
    step();
    // After the edge: the microsecond clock and the real-time clock.
    uint32_t u = d->usec;
    if (u != last_usec) {
      int64_t err = ((int64_t)t - usec_start) * tick_ps - (int64_t)u * us_ps;
      if (std::llabs(err) > worst_us) worst_us = std::llabs(err);
      if (u != last_usec + 1 || std::llabs(err) > tick_ps / 2) {
        std::printf("FAIL: microsecond %u at tick %llu, %lld ps from wall time\n", u,
                    (unsigned long long)t, (long long)err);
        ++fails;
      }
      last_usec = u;
    }
    if (rtc_set >= 0 && (int64_t)t > rtc_set) {
      // The tick the seconds land in is the write's; the count runs from the next.
      int64_t want_ns = (int64_t)frac0 + ((int64_t)t - rtc_set - 1) * tick_ps / 1000;
      int64_t got_ns = ((int64_t)d->rtc_seconds - sec0) * 1000000000LL + d->rtc_fraction;
      int64_t err = got_ns - want_ns;
      if (std::llabs(err) > worst_rtc) worst_rtc = std::llabs(err);
      if (err != 0 && fails < 5) {
        std::printf("FAIL: real-time clock %u s %u ns at tick %llu, %lld ns from wall time\n",
                    d->rtc_seconds, d->rtc_fraction, (unsigned long long)t, (long long)err);
        ++fails;
      }
    }
  }
  int64_t want_rises = ((int64_t)t - timer_on) * tick_ps / (period * us_ps);
  if (std::llabs(rises - want_rises) > 1 || d->rtc_seconds != sec0 + 1) {
    std::printf("FAIL: %lld timer rises where wall time gives %lld, seconds %u\n",
                (long long)rises, (long long)want_rises, d->rtc_seconds);
    ++fails;
  }
  std::printf("wall_time: %s at %lld ps a tick: %llu ticks, %u microseconds (worst %lld ps), "
              "%lld timer rises (worst %lld ps), the real-time clock to the ns (worst %lld ns)\n",
              fails ? "FAILED" : "ok", (long long)tick_ps, (unsigned long long)t, last_usec,
              (long long)worst_us, (long long)rises, (long long)worst_tm, (long long)worst_rtc);
  delete d;
  return fails ? 1 : 0;
}
