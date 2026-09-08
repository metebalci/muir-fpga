// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The processor's port list, generated from `data/cables.txt`.
//!
//! The five flat cables are the processor's real boundary --- 92 wires, pin
//! for pin off MIT's wire lists --- so they are the module's ports. Both
//! implementations of the processor, the one ported from `rtl.rs` and the one
//! generated from `CADR.netlist`, plug into the same list, which is what
//! makes them interchangeable rather than merely similar.
//!
//! Direction is *derived*, not asserted: for each wire this asks the two
//! netlists which parts sit on the net at each end and how each of their pins
//! drives, through `part::pinout`. `cable.rs`'s prose table gives the same
//! answers for the nine signals it lists, and this agrees with it or fails.
//!
//! Writes `rtl/cadr_cables.svh` and, beside it, `rtl/cadr_cables.map` ---
//! every mangled identifier against the name MIT wrote, so a waveform can be
//! read against the drawing.

use std::collections::HashMap;
use std::fmt::Write as _;

use muir::netlist::{self, NetId, Netlist};
use muir::part::{self, Drive};

const MUIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../muir/data");

/// Which side of a cable wire can pull it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Side {
    /// Nothing on this board drives it: it only listens.
    Listens,
    /// One or more parts drive it, and all of them push-pull.
    Totem,
    /// One or more parts drive it and at least one can only pull low, so the
    /// wire is a wired-AND and needs its pull-up.
    Wired,
}

/// One of the 92 wires.
struct Wire {
    /// The name on the processor's drawings, which is the one used here.
    cpu_name: String,
    /// What the bus interface calls the same wire; the two readers spelt
    /// some of them differently, which is why the anchors and not the names
    /// are what find the net.
    busint_name: String,
    connector: String,
    cpu: Side,
    busint: Side,
}

/// A part pin named as `cables.txt` names one: page, reference, pin.
fn anchor_net(n: &Netlist, field: &str) -> Option<NetId> {
    let f: Vec<&str> = field.split_whitespace().collect();
    if f.len() != 3 {
        return None; // "-": the wire touches no part on this board
    }
    let (page, reference) = (f[0], f[1]);
    let pin: u8 = f[2].parse().ok()?;
    n.parts
        .iter()
        .find(|p| p.page == page && p.reference == reference && p.pins.iter().any(|&(q, _)| q == pin))
        .and_then(|p| p.pins.iter().find(|&&(q, _)| q == pin).map(|&(_, net)| net))
}

/// How the board holds the net: what its own parts can do to it.
fn side_of(n: &Netlist, net: Option<NetId>) -> Side {
    let Some(net) = net else { return Side::Listens };
    let mut any = false;
    let mut wired = false;
    for p in n.parts_on(net) {
        let Some(pinout) = part::pinout(&p.kind) else { continue };
        for &(pin, on) in &p.pins {
            if on != net {
                continue;
            }
            match pinout.drive_of(pin) {
                Some(Drive::Totem) => any = true,
                Some(Drive::OpenCollector | Drive::OpenEmitter | Drive::TriState) => {
                    any = true;
                    wired = true;
                }
                // A pull-up is not a driver, and neither is a connector pin.
                Some(Drive::PullUp | Drive::Passive) | None => {}
            }
        }
    }
    match (any, wired) {
        (false, _) => Side::Listens,
        (true, false) => Side::Totem,
        (true, true) => Side::Wired,
    }
}

/// A net name as a SystemVerilog identifier.
///
/// MIT's names are not identifiers: 592 of the CADR board's 2,549 nets begin
/// with `-` for active low, 42 carry a `.`, and a few are quoted because they
/// have spaces or a slash in them. The rules are reversible by the map file
/// written beside the header, which is what lets a waveform be read against
/// the drawing.
///
///   - the quoting SUDS adds for a name with a space in it comes off;
///   - a leading `-` becomes the prefix `n_`, which is the usual way to write
///     an active-low signal and keeps the sense visible;
///   - `.`, ` `, `/` and `>` become `_`;
///   - a name that would start with a digit takes an `x` in front.
fn mangle(name: &str) -> String {
    let name = name.trim().trim_matches('\'');
    let (prefix, rest) = match name.strip_prefix('-') {
        Some(rest) => ("n_", rest),
        None => ("", name),
    };
    let body: String = rest
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect();
    let lead = if body.starts_with(|c: char| c.is_ascii_digit()) { "x" } else { "" };
    format!("{prefix}{lead}{body}")
}

fn read(name: &str) -> String {
    let path = format!("{MUIR}/{name}");
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{path}: {e}\nmuir must be checked out beside muir-fpga"))
}

fn main() {
    let cpu = netlist::parse(&read("CADR.netlist")).expect("CADR.netlist");
    let busint = netlist::parse(&read("BUSINT.netlist")).expect("BUSINT.netlist");
    let table = read("cables.txt");

    let mut wires = Vec::new();
    for line in table.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('|').collect();
        assert_eq!(f.len(), 5, "cables.txt: expected five fields: {line}");
        // The cable, named by both its ends. The processor-side name alone is
        // ambiguous: `1AJ1` is the CADR board's connector *and* the ICMEM
        // board's, two of the five cables, and only the bus interface's header
        // tells them apart --- 1A-J1 to J11 is the CADR's twenty wires and
        // 1A-J1 to J08 the ICMEM's twelve. cables.txt's own header says which
        // meets which.
        let ends: Vec<&str> = f[0].split_whitespace().collect();
        assert!(ends.len() >= 3, "cables.txt: cannot read the connectors: {line}");
        let connector = format!("{}-{}", ends[0], ends[2]);
        wires.push(Wire {
            cpu_name: f[1].trim().to_string(),
            busint_name: f[3].trim().to_string(),
            connector,
            cpu: side_of(&cpu, anchor_net(&cpu, f[2])),
            busint: side_of(&busint, anchor_net(&busint, f[4])),
        });
    }
    assert_eq!(wires.len(), 92, "cables.txt should have 92 wires");

    // A mangled name that collided would silently join two nets, so it is an
    // error rather than a warning.
    let mut seen: HashMap<String, &str> = HashMap::new();
    for w in &wires {
        let id = mangle(&w.cpu_name);
        if let Some(other) = seen.insert(id.clone(), &w.cpu_name) {
            assert_eq!(other, w.cpu_name, "`{id}` is `{other}` and `{}`", w.cpu_name);
        }
    }

    // `cable.rs`'s own table, which this has to reproduce. Where the prose
    // and the netlists part, one of them is wrong and it is worth stopping.
    let expected: &[(&str, bool, bool)] = &[
        //  name        cpu drives  busint drives
        ("-MEMRQ", true, false),
        ("WRCYC", true, false),
        ("MEM0", true, true),
        ("MEM31", true, true),
        ("-MEMACK", false, true),
        ("-LOADMD", false, true),
        ("-MEMGRANT", false, true),
        ("-IGNPAR", false, true),
        ("MCLK7", true, false),
    ];
    for &(name, cpu_drives, busint_drives) in expected {
        let w = wires.iter().find(|w| w.cpu_name == name).unwrap_or_else(|| {
            panic!("cables.txt has no wire `{name}`, which cable.rs names");
        });
        assert_eq!(
            w.cpu != Side::Listens,
            cpu_drives,
            "`{name}`: cable.rs says the cpu {} drive it; the netlist says {:?}",
            if cpu_drives { "does" } else { "does not" },
            w.cpu
        );
        assert_eq!(
            w.busint != Side::Listens,
            busint_drives,
            "`{name}`: cable.rs says the interface {} drive it; the netlist says {:?}",
            if busint_drives { "does" } else { "does not" },
            w.busint
        );
    }

    // The header, from the processor's point of view.
    let mut sv = String::new();
    let mut map = String::new();
    writeln!(sv, "// SPDX-FileCopyrightText: 2026 Mete Balci").unwrap();
    writeln!(sv, "// SPDX-License-Identifier: AGPL-3.0-or-later").unwrap();
    writeln!(sv, "//").unwrap();
    writeln!(sv, "// GENERATED by golden/src/cables.rs from muir's data/cables.txt.").unwrap();
    writeln!(sv, "// Do not edit; run `make cables`.").unwrap();
    writeln!(sv, "//").unwrap();
    writeln!(sv, "// The processor's ports: the 92 wires on the five flat cables to the").unwrap();
    writeln!(sv, "// bus interface, from the processor's point of view.  A wire only the").unwrap();
    writeln!(sv, "// far end drives is an `input`; one only this end drives, an `output`;").unwrap();
    writeln!(sv, "// one both drive is carried as a value and an enable out, with the").unwrap();
    writeln!(sv, "// resolved wire back in, because fabric has no bus to fight over.").unwrap();
    writeln!(sv, "//").unwrap();
    writeln!(sv, "// Names are MIT's, mangled: a leading `-` is `n_`, and `.`, ` `, `/`").unwrap();
    writeln!(sv, "// and `>` are `_`.  cadr_cables.map has every one against its original.").unwrap();
    writeln!(sv).unwrap();

    writeln!(map, "# GENERATED by golden/src/cables.rs. identifier | MIT's name on the").unwrap();
    writeln!(map, "# processor drawings | on the bus interface's | cable | direction").unwrap();
    writeln!(map, "#").unwrap();
    writeln!(map, "# The cable is named by both ends because the processor end alone is").unwrap();
    writeln!(map, "# ambiguous: 1AJ1-J11 is the CADR board's connector and 1AJ1-J08 the").unwrap();
    writeln!(map, "# ICMEM board's. The five are 1AJ1-J11 (20 wires), 1AJ1-J08 (12),").unwrap();
    writeln!(map, "# 1BJ1-J12 (20), 1CJ1-J09 (20) and 3AJ1-J07 (20).").unwrap();

    let mut ins = 0;
    let mut outs = 0;
    let mut bidi = 0;
    let mut ports: Vec<String> = Vec::new();
    let mut driven: Vec<String> = Vec::new();

    for w in &wires {
        let id = mangle(&w.cpu_name);
        let cpu_drives = w.cpu != Side::Listens;
        let busint_drives = w.busint != Side::Listens;
        let dir = match (cpu_drives, busint_drives) {
            (true, true) => {
                bidi += 1;
                ports.push(format!("    output var logic {id}_o"));
                ports.push(format!("    output var logic {id}_oe"));
                driven.push(format!("{id}_o"));
                driven.push(format!("{id}_oe"));
                ports.push(format!("    input  var logic {id}_i   // {}", w.cpu_name));
                "both"
            }
            (true, false) => {
                outs += 1;
                ports.push(format!("    output var logic {id}     // {}", w.cpu_name));
                driven.push(id.clone());
                "out"
            }
            (false, true) => {
                ins += 1;
                ports.push(format!("    input  var logic {id}     // {}", w.cpu_name));
                "in"
            }
            // Neither board drives it. `-LM BOOT` is the one: the boot button
            // is outside both netlists.
            (false, false) => {
                ins += 1;
                ports.push(format!(
                    "    input  var logic {id}     // {} (neither board drives it)",
                    w.cpu_name
                ));
                "in"
            }
        };
        writeln!(map, "{id} | {} | {} | {} | {dir}", w.cpu_name, w.busint_name, w.connector).unwrap();
    }

    // A comma after every port but the last, so the header is the whole of a
    // port list once `clk` and `rst` have been declared ahead of it. The
    // comment has to follow the comma, not precede it.
    for (i, port) in ports.iter().enumerate() {
        let last = i + 1 == ports.len();
        let (decl, note) = match port.split_once("  // ") {
            Some((d, n)) => (d.trim_end(), Some(n)),
            None => (port.trim_end(), None),
        };
        let decl = format!("{decl}{}", if last { "" } else { "," });
        match note {
            Some(note) => writeln!(sv, "{decl:<34}// {note}").unwrap(),
            None => writeln!(sv, "{decl}").unwrap(),
        }
    }

    // A module that is nothing but the port list, so that `verilator --lint-only`
    // proves the header parses, every identifier is legal and no two collide.
    // It is a lint harness and not a design: the outputs are tied off.
    let mut stub = String::new();
    writeln!(stub, "// SPDX-FileCopyrightText: 2026 Mete Balci").unwrap();
    writeln!(stub, "// SPDX-License-Identifier: AGPL-3.0-or-later").unwrap();
    writeln!(stub, "//").unwrap();
    writeln!(stub, "// GENERATED by golden/src/cables.rs.  Do not edit; run `make cables`.").unwrap();
    writeln!(stub, "//").unwrap();
    writeln!(stub, "// Nothing but cadr_cables.svh, so that lint reads the port list.").unwrap();
    writeln!(stub).unwrap();
    writeln!(stub, "`default_nettype none").unwrap();
    writeln!(stub).unwrap();
    writeln!(stub, "/* verilator lint_off UNUSEDSIGNAL */").unwrap();
    writeln!(stub, "module cadr_cables_lint (").unwrap();
    writeln!(stub, "    input  var logic clk,").unwrap();
    writeln!(stub, "    input  var logic rst,").unwrap();
    writeln!(stub, "`include \"cadr_cables.svh\"").unwrap();
    writeln!(stub, ");").unwrap();
    for name in &driven {
        writeln!(stub, "  assign {name} = 1'b0;").unwrap();
    }
    writeln!(stub, "endmodule").unwrap();
    writeln!(stub, "/* verilator lint_on UNUSEDSIGNAL */").unwrap();
    writeln!(stub).unwrap();
    writeln!(stub, "`default_nettype wire").unwrap();

    std::fs::write("rtl/cadr_cables.svh", &sv).expect("write rtl/cadr_cables.svh");
    std::fs::write("rtl/cadr_cables.map", &map).expect("write rtl/cadr_cables.map");
    std::fs::write("rtl/cadr_cables_lint.sv", &stub).expect("write rtl/cadr_cables_lint.sv");

    eprintln!(
        "cadr_cables: {} wires --- {ins} in, {outs} out, {bidi} both ways",
        wires.len()
    );
}
