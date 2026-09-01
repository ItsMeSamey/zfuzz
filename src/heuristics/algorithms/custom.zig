const std = @import("std");

fn lowerBound(comptime I: type, values: []const I, needle: I) usize {
  var low: usize = 0;
  var high: usize = values.len;

  while (low < high) {
    const mid = low + (high - low) / 2;
    if (values[mid] < needle) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }

  return low;
}

fn absSigned(value: i128) i128 {
  return if (value < 0) -value else value;
}

fn absDiff(comptime I: type, a: I, b: I) i128 {
  return absSigned(@as(i128, @intCast(a)) - @as(i128, @intCast(b)));
}

fn asFloat(comptime F: type, value: anytype) F {
  return @floatFromInt(value);
}

/// Exact Zig port of go_fuzzy/heuristics/algorithms.FrequencyDistance.
///
/// This intentionally preserves the Go implementation's matching window,
/// normalization, edge cases, and search behavior, including cases where the
/// returned distance is greater than 1 (for example, a non-empty string versus
/// an empty string).
///
/// C = 256 (byte alphabet size)
/// Time complexity: O(a + b + C * log2(max(a, b)))
/// Space complexity: O(a + b + C)
///
/// `I` is the integer type used to store byte positions. Both input lengths
/// must fit in `I`.
pub fn FrequencyDistance(comptime I: type, comptime F: type, a_: []const u8, b_: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
  var a = a_;
  var b = b_;

  // Match Go: recurse with the longer string as a. Swapping is equivalent and
  // avoids another function call.
  if (a.len < b.len) {
    a = b_;
    b = a_;
  }

  if (b.len == 0) return asFloat(F, a.len);
  if (a.len == 1) return if (a[0] == b[0]) 0 else 1;

  // Go uses [256][]uint32 and appends positions while scanning each string.
  // Store those same sorted position lists in two flat allocations instead of
  // performing up to 512 small allocations.
  var a_counts = [_]usize{0} ** 256;
  var b_counts = [_]usize{0} ** 256;
  for (a) |c| a_counts[c] += 1;
  for (b) |c| b_counts[c] += 1;

  var a_offsets: [256]usize = undefined;
  var b_offsets: [256]usize = undefined;
  var a_cursor: usize = 0;
  var b_cursor: usize = 0;
  for (0..256) |c| {
    a_offsets[c] = a_cursor;
    b_offsets[c] = b_cursor;
    a_cursor += a_counts[c];
    b_cursor += b_counts[c];
  }

  const positions = try allocator.alloc(I, a.len + b.len);
  defer allocator.free(positions);

  const a_positions = positions[0..a.len];
  const b_positions = positions[a.len..];

  var a_write = a_offsets;
  var b_write = b_offsets;
  for (a, 0..) |c, i| {
    a_positions[a_write[c]] = @intCast(i);
    a_write[c] += 1;
  }
  for (b, 0..) |c, i| {
    b_positions[b_write[c]] = @intCast(i);
    b_write[c] += 1;
  }

  const norm: F = asFloat(F, a.len - 1);
  var distance: F = 0;

  for (0..256) |c| {
    var ia = a_positions[a_offsets[c] .. a_offsets[c] + a_counts[c]];
    var ib = b_positions[b_offsets[c] .. b_offsets[c] + b_counts[c]];

    if (ia.len == ib.len) {
      for (ia, ib) |pa, pb| {
        distance += asFloat(F, absDiff(I, pa, pb)) / norm;
      }
      continue;
    }

    if (ia.len < ib.len) {
      const tmp = ia;
      ia = ib;
      ib = tmp;
    }

    if (ib.len == 0) {
      distance += asFloat(F, ia.len);
      continue;
    }

    if (ib.len == 1) {
      distance += asFloat(F, ia.len - 1);
      const idx = lowerBound(I, ia, ib[0]);

      if (idx == ia.len or idx == ia.len - 1) {
        distance += asFloat(F, absDiff(I, ia[ia.len - 1], ib[0])) / norm;
      } else {
        // This is intentionally idx/idx+1, matching the Go implementation.
        distance += asFloat(F, @min(
          absDiff(I, ia[idx], ib[0]),
          absDiff(I, ia[idx + 1], ib[0]),
        )) / norm;
      }
      continue;
    }

    distance += asFloat(F, ia.len - ib.len);
    var start = lowerBound(I, ia, ib[0]);
    var end = lowerBound(I, ia, ib[ib.len - 1]);

    var c_start: i128 = 0;
    var c_end: i128 = 0;
    if (end >= ia.len - 1) {
      end = ia.len - 1;
      start = end - ib.len;
    } else if (start == 0) {
      end = ib.len;
    } else {
      c_start = @min(
        absDiff(I, ia[start], ib[0]),
        absDiff(I, ia[start + 1], ib[0]),
      );
      c_end = @min(
        absDiff(I, ia[end], ib[ib.len - 1]),
        absDiff(I, ia[end + 1], ib[ib.len - 1]),
      );
    }

    while (end - start < ib.len) {
      if (c_start > c_end) {
        end += 1;
        if (end == ia.len - 1) {
          start = end - ib.len;
          break;
        }
        c_end = @min(
          absDiff(I, ia[end], ib[ib.len - 1]),
          absDiff(I, ia[end + 1], ib[ib.len - 1]),
        );
      } else {
        start -= 1;
        if (start == 0) {
          end = ib.len;
          break;
        }
        c_start = @min(
          absDiff(I, ia[start], ib[0]),
          absDiff(I, ia[start + 1], ib[0]),
        );
      }
    }

    c_start = absDiff(I, ia[start], ib[0]);
    c_end = absDiff(I, ia[end], ib[ib.len - 1]);

    var partial_distance: F = 0;
    var j: usize = 1;
    while (j < ib.len - 1) : (j += 1) {
      const position_delta = @as(i128, @intCast(ia[start + j])) - @as(i128, @intCast(ib[j]));
      partial_distance += asFloat(F, @min(
        absSigned(position_delta - c_start),
        absSigned(position_delta - c_end),
      ));
    }
    partial_distance += asFloat(F, c_start + c_end);
    distance += partial_distance / norm;
  }

  return distance / asFloat(F, a.len + b.len);
}

const ParityCase = struct {
  a: []const u8,
  b: []const u8,
  distance: f64,
};

test "FrequencyDistance matches Go implementation" {
  // Expected values are generated by go_fuzzy/heuristics/algorithms.FrequencyDistance[float64].
  const cases = [_]ParityCase{
    .{ .a = "", .b = "", .distance = 0.0 },
    .{ .a = "a", .b = "", .distance = 1.0 },
    .{ .a = "abc", .b = "", .distance = 3.0 },
    .{ .a = "a", .b = "a", .distance = 0.0 },
    .{ .a = "a", .b = "b", .distance = 1.0 },
    .{ .a = "abb", .b = "bba", .distance = 0.33333333333333331 },
    .{ .a = "abc", .b = "acb", .distance = 0.16666666666666666 },
    .{ .a = "abc", .b = "bac", .distance = 0.16666666666666666 },
    .{ .a = "aabb", .b = "abab", .distance = 0.083333333333333329 },
    .{ .a = "aaaa", .b = "bbbb", .distance = 1.0 },
    .{ .a = "abc", .b = "abcd", .distance = 0.14285714285714285 },
    .{ .a = "abcd", .b = "abc", .distance = 0.14285714285714285 },
    .{ .a = "apple", .b = "apxle", .distance = 0.20000000000000001 },
    .{ .a = "apple", .b = "apxpl", .distance = 0.25 },
    .{ .a = "apple", .b = "axple", .distance = 0.20000000000000001 },
    .{ .a = "apple", .b = "bpple", .distance = 0.20000000000000001 },
    .{ .a = "hello", .b = "world", .distance = 0.67500000000000004 },
    .{ .a = "testing", .b = "test", .distance = 0.27272727272727271 },
    .{ .a = "test", .b = "testing", .distance = 0.27272727272727271 },
    .{ .a = "aaaaa", .b = "aaaba", .distance = 0.20000000000000001 },
    .{ .a = "aaaba", .b = "aaaaa", .distance = 0.20000000000000001 },
    .{ .a = "aaaaa", .b = "aabba", .distance = 0.42499999999999999 },
    .{ .a = "aabba", .b = "aaaaa", .distance = 0.42499999999999999 },
    .{ .a = "abcde", .b = "edcba", .distance = 0.29999999999999999 },
    .{ .a = "microsoft", .b = "mitsubishi", .distance = 0.62573099415204669 },
    .{ .a = "intention", .b = "execution", .distance = 0.4513888888888889 },
    .{ .a = "aaaa", .b = "aaa", .distance = 0.19047619047619047 },
    .{ .a = "aaa", .b = "aaaa", .distance = 0.19047619047619047 },
    .{ .a = "cat", .b = "act", .distance = 0.16666666666666666 },
    .{ .a = "dog", .b = "god", .distance = 0.33333333333333331 },
    .{ .a = "listen", .b = "silent", .distance = 0.13333333333333333 },
  };

  for (cases) |case| {
    const actual = try FrequencyDistance(u32, f64, case.a, case.b, std.testing.allocator);
    try std.testing.expectApproxEqAbs(case.distance, actual, 1e-12);
  }
}

test "FrequencyDistance float32 matches Go operation order" {
  const actual = try FrequencyDistance(u32, f32, "microsoft", "mitsubishi", std.testing.allocator);
  try std.testing.expectApproxEqAbs(@as(f32, 0.625730991), actual, 1e-7);
}

test {
  std.testing.refAllDeclsRecursive(@This());
}
