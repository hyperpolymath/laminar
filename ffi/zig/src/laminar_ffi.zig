// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Laminar FFI — Pipeline orchestration C bridge.

const std = @import("std");

pub const StageState = enum(i32) { pending = 0, running = 1, succeeded = 2, failed = 3, skipped = 4 };

/// Check if a stage state transition is valid.
pub export fn laminar_can_transition(from: i32, to: i32) callconv(.C) i32 {
    // Matches Idris2 ValidTransition proof
    if (from == 0 and to == 1) return 1; // Pending → Running
    if (from == 1 and to == 2) return 1; // Running → Succeeded
    if (from == 1 and to == 3) return 1; // Running → Failed
    if (from == 0 and to == 4) return 1; // Pending → Skipped
    if (from == 3 and to == 1) return 1; // Failed → Running (retry)
    return 0;
}

/// Clamp retry count to [0, 10].
pub export fn laminar_clamp_retries(count: i32) callconv(.C) i32 {
    if (count < 0) return 0;
    if (count > 10) return 10;
    return count;
}

test "valid transitions" {
    try std.testing.expectEqual(@as(i32, 1), laminar_can_transition(0, 1));
    try std.testing.expectEqual(@as(i32, 1), laminar_can_transition(1, 2));
    try std.testing.expectEqual(@as(i32, 1), laminar_can_transition(3, 1));
    try std.testing.expectEqual(@as(i32, 0), laminar_can_transition(2, 1));
    try std.testing.expectEqual(@as(i32, 0), laminar_can_transition(4, 1));
}
