// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for `rtl/machine/cadr_phase_gen.sv`, taken from muir's own
//! `clock::Behavioral` --- the model the `chip` engine runs --- put on the grid.
//!
//! One line per tick of the grid: the inputs the tick was driven with, then
//! the six signals the generator puts on the board.  The testbench reads the
//! same file, drives the DUT with the inputs and compares the outputs, so the
//! stimulus has exactly one definition and it is this one.
//!
//! The generator is driven the way `Chip::tick` drives it: ask what the board
//! looks like, take every event due, put the outputs back.  `pass` carries
//! time across a tick with no event in it, `held` when nothing is due because
//! `-HANG` or `RESET` is holding the generator rather than because the next
//! transition has not come round yet.
//!
//! **THE RING ON THE GRID IS [`GridRing`], AND ITS OFFSETS ARE `Behavioral`'S.**
//! muir's `TimingModel::Fpga` says what a whole microcycle is on the grid ---
//! the tap rounded up and the restart rounded up after it --- and says nothing
//! about the instants inside it, because `rtl` has no ring.  `Behavioral`
//! keeps the board's own nanoseconds and has no model to choose.  So the ring
//! here is `Behavioral`'s scheduler with every offset put through
//! `TimingModel::Fpga.triggered` FROM ITS OWN TRIGGER: `TPTSE`, `-TPR60`,
//! SELECT and the tap from `-TPR0`, the write pulses and the restart from the
//! end of the read phase.  The offsets are not copied: [`Offsets::measure`]
//! runs `Behavioral` and reads them off its outputs, so a muir that moves one
//! moves this trace.  And every cycle the ring completes is asserted against
//! `TimingModel::Fpga.cycle_ns`, which is muir's own statement of the grid.

mod machine_axis;

use muir::clock::{self, Behavioral, Clock, Inputs, Outputs, Speed, TimingModel};

/// MIT's grid in nanoseconds, the one `cadr_tick_pkg::TICK_NS` names: a tick
/// of the trace.  muir's `clock::GRID_NS` is the grid its `fpga` timing model
/// keeps, and the two are asserted equal.
const TICK_NS: u64 = 10;

/// How many ticks the trace runs for. At normal speed a microcycle is 15
/// ticks, so this is some hundreds of cycles.
const TICKS: u64 = 12_000;

/// The model every instant below is put on the grid with.
const GRID: TimingModel = TimingModel::Fpga;

/// `Behavioral`'s own offsets, in its own nanoseconds.
#[derive(Clone, Copy, Debug)]
struct Offsets {
    /// From `-TPR0`: `TPTSE` cleared and set, and SELECT, where the tap is
    /// chosen.
    tse_off: u64,
    tse_on: u64,
    select: u64,
    /// From the end of the read phase: the write pulse on, the control
    /// store's pulse off, the write pulse off, and the next `-TPR0`.
    wp_on: u64,
    wpiram_off: u64,
    wp_off: u64,
    restart: u64,
}

/// One cycle of `Behavioral` at constant inputs from power-on, as the instants
/// of each output's transitions in its SECOND cycle (the first has no `TPTSE`
/// fall to see, `TPTSE` coming up low), and the tap it chose.
fn second_cycle(switch_ilong_at: Option<u64>) -> (u64, Vec<(u64, Outputs)>) {
    let mut clk = Behavioral::new();
    let mut out = Outputs::default();
    let mut seen = Vec::new();
    let mut starts = 0u64;
    let mut start = 0u64;
    let base = Inputs { machrun: true, hang: false, ilong: false, speed: Speed::Normal, reset: false };
    loop {
        let at = clk.next_at(base).expect("the ring runs");
        let inputs = match switch_ilong_at {
            Some(x) if starts == 2 && at >= start + x => Inputs { ilong: true, ..base },
            _ => base,
        };
        let before = out;
        out = clk.advance(inputs).1;
        let now = clk.time_ns();
        if out.tpclk && !before.tpclk {
            starts += 1;
            if starts == 2 {
                start = now;
            } else if starts == 3 {
                return (start, seen);
            }
        }
        if starts == 2 && out != before {
            seen.push((now - start, out));
        }
    }
}

impl Offsets {
    fn measure() -> Offsets {
        let (_, seen) = second_cycle(None);
        let first = |f: &dyn Fn(&Outputs) -> bool| {
            seen.iter().find(|(_, o)| f(o)).map(|&(t, _)| t).expect("a transition in the cycle")
        };
        let tse_off = first(&|o| !o.tptse);
        let tse_on = seen.iter().find(|&&(t, o)| t > tse_off && o.tptse).map(|&(t, _)| t).unwrap();
        let read = first(&|o| !o.tpclk);
        let wp_on = first(&|o| o.tpwp);
        let wpiram_off = seen.iter().find(|&&(t, o)| t > read && !o.tpwpiram).map(|&(t, _)| t).unwrap();
        let wp_off = seen.iter().find(|&&(t, o)| t > wp_on && !o.tpwp).map(|&(t, _)| t).unwrap();
        assert_eq!(read, u64::from(Speed::Normal.read_phase_ns(false)), "the tap is not the table's");
        let restart = u64::from(Speed::Normal.cycle_ns(false)) - read;
        // SELECT is when the tap is chosen, which no output shows: the
        // earliest instant at which -ILONG going up still lengthens the cycle
        // it went up in.
        let long = u64::from(Speed::Normal.read_phase_ns(true));
        let select = (0..read)
            .find(|&x| {
                let (_, s) = second_cycle(Some(x));
                s.iter().find(|(_, o)| !o.tpclk).map(|&(t, _)| t) != Some(long)
            })
            .expect("-ILONG is taken somewhere in the read phase");
        let select = select - 1;
        Offsets {
            tse_off,
            tse_on,
            select,
            wp_on: wp_on - read,
            wpiram_off: wpiram_off - read,
            wp_off: wp_off - read,
            restart,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ev {
    CycleStart,
    TseOn,
    TseOff,
    ReadEnd,
    WpIramOff,
    WpOn,
    WpOff,
    Select,
}

/// `Behavioral`'s scheduler with each offset on the grid from its trigger.
/// `advance`, `next_at`, `pass` and `phase_ns` are `Behavioral`'s own, line
/// for line; what differs is only when `start_cycle` and `pick_tap` put the
/// events.
struct GridRing {
    off: Offsets,
    time: u64,
    cycle_start: u64,
    out: Outputs,
    pending: Vec<(u64, Ev)>,
    /// The cycle in flight's tap, for the assertion against muir's own cycle.
    chosen: Option<(Speed, bool)>,
}

impl GridRing {
    fn new(off: Offsets) -> GridRing {
        GridRing { off, time: 0, cycle_start: 0, out: Outputs::default(), pending: vec![(0, Ev::CycleStart)], chosen: None }
    }

    fn schedule(&mut self, at: u64, ev: Ev) {
        let i = self.pending.partition_point(|&(t, _)| t <= at);
        self.pending.insert(i, (at, ev));
    }

    fn start_cycle(&mut self) {
        let t0 = self.time;
        if let Some((speed, ilong)) = self.chosen.take() {
            assert_eq!(
                t0 - self.cycle_start,
                u64::from(GRID.cycle_ns(speed, ilong)),
                "a cycle on the grid is not TimingModel::Fpga's"
            );
        }
        self.cycle_start = t0;
        self.schedule(t0 + GRID.triggered(self.off.tse_off), Ev::TseOff);
        self.schedule(t0 + GRID.triggered(self.off.tse_on), Ev::TseOn);
        self.schedule(t0 + GRID.triggered(self.off.select), Ev::Select);
    }

    fn pick_tap(&mut self, inputs: Inputs) {
        let t0 = self.cycle_start;
        let r = t0 + GRID.triggered(u64::from(inputs.speed.read_phase_ns(inputs.ilong)));
        self.chosen = Some((inputs.speed, inputs.ilong));
        self.schedule(r, Ev::ReadEnd);
        self.schedule(r + GRID.triggered(self.off.wpiram_off), Ev::WpIramOff);
        self.schedule(r + GRID.triggered(self.off.wp_on), Ev::WpOn);
        self.schedule(r + GRID.triggered(self.off.wp_off.min(self.off.restart)), Ev::WpOff);
        self.schedule(r + GRID.triggered(self.off.restart), Ev::CycleStart);
    }

    fn advance(&mut self, inputs: Inputs) -> Outputs {
        if inputs.reset {
            self.out = Outputs::default();
            self.pending.clear();
            self.pending.push((self.time, Ev::CycleStart));
            self.chosen = None;
            return self.out;
        }
        let Some(&(at, ev)) = self.pending.first() else { return self.out };
        if inputs.hang && ev == Ev::CycleStart {
            return self.out;
        }
        self.pending.remove(0);
        self.time = at;
        match ev {
            Ev::CycleStart => {
                self.out.tpclk = true;
                self.start_cycle();
            }
            Ev::TseOn => self.out.tptse = true,
            Ev::TseOff => self.out.tptse = false,
            Ev::Select => self.pick_tap(inputs),
            Ev::ReadEnd => {
                self.out.tpclk = false;
                self.out.tpwpiram = true;
            }
            Ev::WpIramOff => self.out.tpwpiram = false,
            Ev::WpOn => self.out.tpwp = true,
            Ev::WpOff => self.out.tpwp = false,
        }
        self.out
    }

    fn next_at(&self, inputs: Inputs) -> Option<u64> {
        if inputs.reset {
            return None;
        }
        let &(at, ev) = self.pending.first()?;
        if inputs.hang && ev == Ev::CycleStart { None } else { Some(at) }
    }

    fn pass(&mut self, until: u64, held: bool) {
        assert!(until >= self.time, "time does not run backwards");
        if held {
            let dt = until - self.time;
            for e in &mut self.pending {
                e.0 += dt;
            }
            // A cycle held off at -TPR0 is longer than its tap says, and
            // that is -HANG's doing and not the grid's.
            self.chosen = None;
        } else {
            assert!(
                self.pending.first().is_none_or(|&(at, _)| until <= at),
                "passed a transition without taking it"
            );
        }
        self.time = until;
    }

    fn phase_ns(&self) -> u64 {
        self.time - self.cycle_start
    }
}

/// The inputs at one tick.
#[derive(Clone, Copy)]
struct Drive {
    reset: bool,
    hang: bool,
    ilong: bool,
    speed: Speed,
}

/// A deterministic stimulus, so the trace is the same on every machine and
/// the file can be regenerated and diffed.
///
/// It is not random noise: each segment is meant to reach something. Reset
/// first, then each speed and each ILONG on its own, then `-HANG`, then
/// everything moving at once.
///
/// Reset is held only before the first cycle, but that does not avoid the
/// `-TPR60` artifact: `apply_clock` derives it from `phase_ns`, which is
/// `time - cycle_start`, and reset moves neither `cycle_start` nor the clock.
/// Time runs on, so even a reset held from power-on sweeps `phase_ns` through
/// 60..100 and emits a read tap --- here at ticks 11 to 18. The testbench
/// therefore does not compare `-TPR60` while `RESET` is high.
fn drive(tick: u64) -> Drive {
    // A small LCG, so this file needs no dependency either.
    let mut s = tick.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
    let mut next = || {
        s = s.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (s >> 33) as u32
    };

    // Ticks 0..20: reset held, then released. Nothing else is exercised
    // while it is down.
    if tick < 20 {
        return Drive { reset: true, hang: false, ilong: false, speed: Speed::Normal };
    }

    let t = tick - 20;

    // Each speed and each ILONG in turn, a few cycles at a time, so every one
    // of the seven taps is reached with no other input moving. 220 ticks is
    // long enough for several cycles at the slowest.
    if t < 8 * 220 {
        let seg = (t / 220) as u32;
        let speed = match seg / 2 {
            0 => Speed::Fast,
            1 => Speed::Normal,
            2 => Speed::Slow,
            _ => Speed::ExtraSlow,
        };
        return Drive { reset: false, hang: false, ilong: seg % 2 == 1, speed };
    }

    let t = t - 8 * 220;

    // -HANG, on and off in runs of a few ticks to a few cycles, so the park
    // at the boundary is entered from every phase and left again.
    if t < 3_000 {
        let hang = (t / 7) % 5 == 0 || (t / 61) % 9 == 0;
        return Drive { reset: false, hang, ilong: (t / 313) % 2 == 1, speed: Speed::Normal };
    }

    // Everything moving at once, including speed and ILONG changing inside a
    // cycle --- which is what SELECT_NS at 65 ns is there to settle.
    let v = next();
    let speed = match v & 3 {
        0 => Speed::ExtraSlow,
        1 => Speed::Slow,
        2 => Speed::Normal,
        _ => Speed::Fast,
    };
    Drive { reset: false, hang: v & 0x30 == 0, ilong: v & 0x40 != 0, speed }
}

impl Drive {
    fn inputs(self) -> Inputs {
        Inputs {
            // MACHRUN gates -CLK0 on the board at CLOCK2 1D10, not in the
            // generator: `advance` never reads it, and the RTL has no port
            // for it.
            machrun: true,
            hang: self.hang,
            ilong: self.ilong,
            speed: self.speed,
            reset: self.reset,
        }
    }
}

fn main() {
    assert_eq!(TICK_NS, clock::GRID_NS, "the trace's grid is not the one muir's fpga model keeps");
    // `--machine quux --sync-cycle-ticks K [--sync-ilong-ticks L]` writes
    // QUUX's generator instead (`sync_main`); with no flag this is the CADR's
    // trace, byte for byte what it always was.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let timing = machine_axis::take_timing(which, &mut args);
    if let Some(a) = args.first() {
        eprintln!(
            "phase_gen: unknown argument `{a}`; usage: phase_gen \
             [--machine quux --sync-cycle-ticks K [--sync-ilong-ticks L]]"
        );
        std::process::exit(2);
    }
    if which == machine_axis::Which::Quux {
        sync_main(timing);
        return;
    }
    let off = Offsets::measure();
    // Every offset lands where `cadr_phase_gen.sv` puts its constant, and
    // SELECT inside the ordering the fabric relies on.
    assert!(off.tse_off < off.tse_on && off.select < u64::from(Speed::Fast.read_phase_ns(false)));
    let mut clk = GridRing::new(off);
    let mut out = Outputs::default();

    println!("# tick rst hang ilong speed | tpclk n_tpclk tptse n_tpwp n_tpwpiram n_tpr60");
    println!("# generated by golden/src/phase_gen.rs from muir's clock::Behavioral on the {TICK_NS} ns grid");
    println!(
        "# offsets from -TPR0: tptse off {} on {}, select {}; from the tap: wp on {}, wpiram off {}, wp off {}, restart {}",
        off.tse_off, off.tse_on, off.select, off.wp_on, off.wpiram_off, off.wp_off, off.restart
    );

    // -TPR60 as chip.rs puts it on the board, from the phase: a tap of the
    // same line at 60 ns, forty wide, both put on the grid from -TPR0.
    let tpr60_on = GRID.triggered(60);
    let tpr60_off = GRID.triggered(60 + u64::from(clock::TPR_PULSE_NS));

    for tick in 0..TICKS {
        let now = tick * TICK_NS;
        let d = drive(tick);
        let inputs = d.inputs();

        // Every event due at or before now.
        while let Some(at) = clk.next_at(inputs) {
            if at > now {
                break;
            }
            out = clk.advance(inputs);
        }

        // Reset is not an event: `advance` under it clears the outputs and
        // leaves a CycleStart pending at the current time, and `next_at`
        // answers None for as long as it is held. So it is taken here.
        let held = if inputs.reset {
            out = clk.advance(inputs);
            true
        } else {
            clk.next_at(inputs).is_none()
        };

        // A held generator is held for the *whole* of this tick, so what it
        // has pending belongs to the next one. Passing only to `now` would
        // anchor the restarted cycle at the tick reset or `-HANG` was last
        // seen, and `start_cycle` schedules the rest of the cycle from there
        // --- putting every later event a tick off where the fabric has it.
        clk.pass(if held { now + TICK_NS } else { now }, held);

        let phase_ns = clk.phase_ns();
        let tpr60 = (tpr60_on..tpr60_off).contains(&phase_ns);

        let b = |v: bool| u8::from(v);
        println!(
            "{tick} {} {} {} {} {} {} {} {} {} {}",
            b(d.reset),
            b(d.hang),
            b(d.ilong),
            d.speed as u8,
            // The board's own names and senses: the two write-pulse latches
            // and -TPR60 are active low.
            b(out.tpclk),
            b(!out.tpclk),
            b(out.tptse),
            b(!out.tpwp),
            b(!out.tpwpiram),
            b(!tpr60),
        );
    }
}

/// How many ticks QUUX's trace runs for: some hundreds of microcycles at
/// three to five ticks each.
const SYNC_TICKS: u64 = 3_000;

/// **QUUX'S GENERATOR, `TimingModel::Sync`**: a microcycle of K ticks, and
/// K + L for an `ILONG` instruction, with nothing inside it --- no taps, no
/// SELECT, no `TPTSE`, no write pulses and no `-TPR60` --- and `-HANG`
/// meaning nothing, QUUX having no hung microcycle.  So the trace is the
/// instants `TPCLK` rises at, one tick each, and each microcycle's length is
/// `TimingModel::cycle_ns` of the `ILONG` standing in it, which is muir's own
/// statement of the model and not a copy of it.
///
/// **WHERE `ILONG` IS READ.**  On the machine `-ILONG` is `IR<45>`, and `IR`
/// moves on the edge that ends the tick `TPCLK` rose in; so the stimulus
/// changes `ILONG` only on the tick after a rise, and holds it for the whole
/// of the microcycle, as `IR` holds.  A generator that read it on the rise's
/// own tick would take the instruction before's.  Reset comes up twice, at
/// the start and part way through, and `-HANG` moves throughout, so a
/// generator that minded it is caught.  Columns are the CADR trace's, with
/// the outputs QUUX has no use for at their idle values.
fn sync_main(timing: TimingModel) {
    let TimingModel::Sync { cycle_ticks, ilong_ticks } = timing else {
        unreachable!("QUUX's generator is taken on its synchronous microcycle");
    };
    println!("# tick rst hang ilong speed | tpclk n_tpclk tptse n_tpwp n_tpwpiram n_tpr60");
    println!(
        "# generated by golden/src/phase_gen.rs from muir's TimingModel::Sync on the {TICK_NS} ns grid, \
         machine: quux, timing: sync {cycle_ticks} {ilong_ticks}"
    );
    let mut s: u64 = 0x2545_f491_4f6c_dd1d;
    let mut next = || {
        s = s.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (s >> 33) as u32
    };
    // The tick the current microcycle's `TPCLK` rose on, and when the next
    // rises; `None` while reset holds the generator.
    let mut start: Option<u64> = None;
    let mut next_start = 0u64;
    let mut ilong = false;
    let mut lengths = [0u64; 2];
    for tick in 0..SYNC_TICKS {
        let reset = tick < 5 || (1_500..1_507).contains(&tick);
        let hang = next() % 3 == 0;
        let mut tpclk = false;
        if reset {
            start = None;
        } else {
            match start {
                None => {
                    start = Some(tick);
                    tpclk = true;
                }
                Some(_) if tick == next_start => {
                    start = Some(tick);
                    tpclk = true;
                }
                Some(st) => {
                    // The tick after the rise: `IR` has moved, and with it
                    // `ILONG`, which then stands for the whole microcycle.
                    if tick == st + 1 {
                        ilong = next() % 3 == 0;
                        let ns = u64::from(timing.cycle_ns(Speed::Normal, ilong));
                        assert_eq!(ns % TICK_NS, 0, "a microcycle off the grid");
                        next_start = st + ns / TICK_NS;
                        lengths[usize::from(ilong)] += 1;
                    }
                }
            }
        }
        // The write pulse: low over a microcycle's last tick, the tick
        // before the next rise, so that it ends on the edge the boundary's
        // tick starts with; the control store's is the boundary's tick.
        let last = !reset && start.is_some() && !tpclk && tick + 1 == next_start;
        let b = |v: bool| u8::from(v);
        // The speed column is QUUX's one rate, normal; nothing reads it.
        println!(
            "{tick} {} {} {} {} {} {} 0 {} {} 1",
            b(reset),
            b(hang),
            b(ilong),
            Speed::Normal as u8,
            b(tpclk),
            b(!tpclk),
            b(!last),
            b(!tpclk)
        );
    }
    eprintln!(
        "phase_gen: QUUX at sync {cycle_ticks} {ilong_ticks}: {} microcycles of {} ticks, {} with ILONG",
        lengths[0], cycle_ticks, lengths[1]
    );
}
