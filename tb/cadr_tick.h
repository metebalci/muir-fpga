// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT'S GRID, FOR THE TESTBENCHES.
//
// `rtl/machine/cadr_tick_pkg.sv` is the same constant for the fabric, and its
// header is where the argument lives: the grid is the conversion from MIT's
// drawings into ticks, it is NOT the length of a tick, and rounding is always
// up.  This file exists because the two sides have to agree and cannot share
// a literal across the language boundary --- twenty-one testbenches each wrote
// the grid out as a `5`, so a change to the fabric's grid would have left
// every reference comparison silently converting at the old one.
//
// **THE TWO MUST MOVE TOGETHER.**  A testbench turns a reference instant in
// nanoseconds into the tick it expects the fabric to act on, so a grid here
// that differs from the fabric's does not fail to build: it compares a
// correct design against the wrong instant, which is the shape of failure
// this project is least able to see.  `tools/grid_check.py`, run as
// `grid.pass`, is what fails instead.
//
// Each testbench keeps its own constant and its own type --- `int`, `long`,
// `unsigned` --- and derives it from this one, so no format specifier and no
// arithmetic width changes with the include.

#ifndef CADR_TICK_H
#define CADR_TICK_H

// MIT's grid, in nanoseconds.  Equal to `cadr_tick_pkg::TICK_NS`.
constexpr long kGridNs = 10;

// Nanoseconds to ticks, rounded UP: the fabric can only act on a clock edge,
// so an instant between two of them is taken at the first edge at or after
// it.  Equal to `cadr_tick_pkg::ticks`.
constexpr long GridTicks(long ns) { return (ns + kGridNs - 1) / kGridNs; }

// The same constant in the two other types call sites need, so that turning a
// tick count into nanoseconds does not change an expression's width or its
// format specifier.
constexpr unsigned long long kGridNsU = static_cast<unsigned long long>(kGridNs);
constexpr double kGridNsD = static_cast<double>(kGridNs);

// **muir's t = 0 IS THIS MANY EDGES AFTER THE RESET EDGE**, in the whole
// machine and so in every standalone check that compares against a trace
// dated from muir's t = 0: the reset edge and one idle edge come before row 0.
// Equal to `cadr_tick_pkg::POWER_ON_EDGES`, which says why; a count of the
// fabric's edges and not an instant, so it is the same at any grid.
constexpr int kPowerOnEdges = 2;

#endif  // CADR_TICK_H
