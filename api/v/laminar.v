// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Laminar zig API — Pipeline orchestration client.
module laminar

pub enum StageState {
	pending
	running
	succeeded
	failed
	skipped
}

pub struct Stage {
pub:
	name    string
	state   StageState
	retries int
}

fn C.laminar_can_transition(from int, to int) int
fn C.laminar_clamp_retries(count int) int

// can_transition checks if a stage state transition is valid.
pub fn can_transition(from StageState, to StageState) bool {
	return C.laminar_can_transition(int(from), int(to)) == 1
}

// clamp_retries ensures retry count is within bounds [0, 10].
pub fn clamp_retries(count int) int {
	return C.laminar_clamp_retries(count)
}
