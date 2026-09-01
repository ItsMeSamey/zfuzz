const std = @import("std");

pub const Match = struct {
    value: []const u8,
    score: i32,
    index: usize,
};

const anchors_per_side = 2;
const max_contract_query = 256;

const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i32 = score_match / 2;
const bonus_non_word: i32 = score_match / 2;
const bonus_camel_number: i32 = bonus_boundary + score_gap_extension;
const bonus_consecutive: i32 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i32 = 2;
const bonus_boundary_white: i32 = bonus_boundary + 2;
const bonus_boundary_delimiter: i32 = bonus_boundary + 1;

const CharClass = enum(u3) {
    white,
    non_word,
    delimiter,
    lower,
    upper,
    number,
};

/// Score one candidate. Higher is better. Null means the query is not an
/// ordered subsequence of the candidate.
///
/// ASCII matching is case-insensitive. The score prefers word boundaries,
/// camelCase boundaries, consecutive runs, and short gaps.
///
/// Time: O(query.len + candidate.len)
/// Space: O(1)
pub fn score(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (query.len > candidate.len) return null;

    var starts: [anchors_per_side]usize = undefined;
    var starts_len: usize = 0;
    const first = lower(query[0]);
    for (candidate, 0..) |c, i| {
        if (lower(c) != first) continue;
        starts[starts_len] = i;
        starts_len += 1;
        if (starts_len == anchors_per_side) break;
    }
    if (starts_len == 0) return null;

    var best: ?i32 = null;
    for (starts[0..starts_len]) |anchor| {
        const current = if (query.len <= max_contract_query)
            scoreFromStartContracted(query, candidate, anchor)
        else
            scoreForward(query, candidate, anchor);
        if (current) |value| updateBest(&best, value);
    }

    // For normal short fuzzy queries, also explore two alignments from the
    // opposite direction. This recovers most of the quality gap to dynamic
    // programming while retaining a fixed number of linear scans.
    if (query.len <= max_contract_query) {
        var ends: [anchors_per_side]usize = undefined;
        var ends_len: usize = 0;
        const last = lower(query[query.len - 1]);
        var i = candidate.len;
        while (i > 0 and ends_len < anchors_per_side) {
            i -= 1;
            if (lower(candidate[i]) != last) continue;
            ends[ends_len] = i;
            ends_len += 1;
        }

        for (ends[0..ends_len]) |anchor| {
            if (scoreFromEndContracted(query, candidate, anchor)) |value| {
                updateBest(&best, value);
            }
        }
    }

    return best;
}

fn updateBest(best: *?i32, value: i32) void {
    if (best.* == null or value > best.*.?) best.* = value;
}

/// Return the best `limit` matches, already sorted best-first.
/// The caller owns the returned slice.
///
/// Time: O(total candidate bytes + N log(limit) + limit log(limit))
/// Space: O(limit)
pub fn find(
    allocator: std.mem.Allocator,
    query: []const u8,
    candidates: []const []const u8,
    limit: usize,
) std.mem.Allocator.Error![]Match {
    const capacity = @min(limit, candidates.len);
    if (capacity == 0) return allocator.alloc(Match, 0);

    var heap = try allocator.alloc(Match, capacity);
    errdefer allocator.free(heap);
    var len: usize = 0;

    for (candidates, 0..) |candidate, index| {
        const candidate_score = score(query, candidate) orelse continue;
        const item: Match = .{
            .value = candidate,
            .score = candidate_score,
            .index = index,
        };

        if (len < capacity) {
            heap[len] = item;
            heapBubbleWorst(heap[0 .. len + 1], len);
            len += 1;
        } else if (better(item, heap[0])) {
            heap[0] = item;
            heapSiftWorst(heap[0..len], 0);
        }
    }

    heapSortBestFirst(heap[0..len]);
    if (len == capacity) return heap;
    return try allocator.realloc(heap, len);
}

fn scoreFromStartContracted(query: []const u8, candidate: []const u8, start: usize) ?i32 {
    var positions: [max_contract_query]usize = undefined;
    positions[0] = start;

    var q: usize = 1;
    var i = start + 1;
    while (q < query.len and i < candidate.len) : (i += 1) {
        if (lower(candidate[i]) == lower(query[q])) {
            positions[q] = i;
            q += 1;
        }
    }
    if (q != query.len) return null;

    q = query.len - 1;
    i = positions[q] + 1;
    while (i > start) {
        i -= 1;
        if (lower(candidate[i]) != lower(query[q])) continue;
        positions[q] = i;
        if (q == 0) break;
        q -= 1;
    }

    return scorePositions(candidate, positions[0..query.len]);
}

fn scoreFromEndContracted(query: []const u8, candidate: []const u8, end: usize) ?i32 {
    var positions: [max_contract_query]usize = undefined;
    var q = query.len - 1;
    positions[q] = end;

    var i = end;
    while (q > 0 and i > 0) {
        i -= 1;
        if (lower(candidate[i]) == lower(query[q - 1])) {
            q -= 1;
            positions[q] = i;
        }
    }
    if (q != 0) return null;

    // Tighten the alignment from the left while keeping this end anchor.
    q = 0;
    i = positions[0];
    while (q + 1 < query.len and i < end) {
        i += 1;
        if (lower(candidate[i]) == lower(query[q + 1])) {
            q += 1;
            positions[q] = i;
        }
    }
    if (q + 1 != query.len) return null;

    return scorePositions(candidate, positions[0..query.len]);
}

fn scoreForward(query: []const u8, candidate: []const u8, start: usize) ?i32 {
    var total: i32 = 0;
    var q: usize = 0;
    var i = start;
    var previous: ?usize = null;
    var consecutive: usize = 0;
    var first_bonus: i32 = 0;

    while (q < query.len and i < candidate.len) : (i += 1) {
        if (lower(candidate[i]) != lower(query[q])) continue;

        if (previous) |p| {
            const gap = i - p - 1;
            if (gap > 0) {
                total += score_gap_start + @as(i32, @intCast(gap - 1)) * score_gap_extension;
                consecutive = 0;
            }
        }

        total += score_match;
        var b = bonusAt(candidate, i);
        if (consecutive == 0) {
            first_bonus = b;
        } else {
            if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
            b = @max(b, @max(first_bonus, bonus_consecutive));
        }
        total += if (q == 0) b * bonus_first_char_multiplier else b;

        consecutive += 1;
        previous = i;
        q += 1;
    }

    return if (q == query.len) total else null;
}

fn scorePositions(candidate: []const u8, positions: []const usize) i32 {
    var total: i32 = 0;
    var previous: ?usize = null;
    var consecutive: usize = 0;
    var first_bonus: i32 = 0;

    for (positions, 0..) |position, q| {
        if (previous) |p| {
            const gap = position - p - 1;
            if (gap > 0) {
                total += score_gap_start + @as(i32, @intCast(gap - 1)) * score_gap_extension;
                consecutive = 0;
            }
        }

        total += score_match;
        var b = bonusAt(candidate, position);
        if (consecutive == 0) {
            first_bonus = b;
        } else {
            if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
            b = @max(b, @max(first_bonus, bonus_consecutive));
        }
        total += if (q == 0) b * bonus_first_char_multiplier else b;

        consecutive += 1;
        previous = position;
    }

    return total;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn charClass(c: u8) CharClass {
    if (c >= 'a' and c <= 'z') return .lower;
    if (c >= 'A' and c <= 'Z') return .upper;
    if (c >= '0' and c <= '9') return .number;
    return switch (c) {
        ' ', '\t', '\n', '\r', '\v', '\f' => .white,
        '/', ',', ':', ';', '|' => .delimiter,
        else => .non_word,
    };
}

fn bonusAt(candidate: []const u8, i: usize) i32 {
    const previous: CharClass = if (i == 0) .white else charClass(candidate[i - 1]);
    return bonusFor(previous, charClass(candidate[i]));
}

fn bonusFor(previous: CharClass, current: CharClass) i32 {
    if (current != .white) {
        switch (previous) {
            .white => return bonus_boundary_white,
            .delimiter => return bonus_boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        }
    }

    if ((previous == .lower and current == .upper) or
        (previous != .number and current == .number))
    {
        return bonus_camel_number;
    }

    return switch (current) {
        .non_word, .delimiter => bonus_non_word,
        .white => bonus_boundary_white,
        else => 0,
    };
}

fn better(a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.value.len != b.value.len) return a.value.len < b.value.len;
    return a.index < b.index;
}

// Root is the worst retained match, so replacing it is O(log K).
fn heapBubbleWorst(heap: []Match, start: usize) void {
    var child = start;
    while (child > 0) {
        const parent = (child - 1) / 2;
        if (!better(heap[parent], heap[child])) break;
        std.mem.swap(Match, &heap[parent], &heap[child]);
        child = parent;
    }
}

fn heapSiftWorst(heap: []Match, start: usize) void {
    var parent = start;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= heap.len) return;

        var worst = left;
        const right = left + 1;
        if (right < heap.len and better(heap[left], heap[right])) worst = right;
        if (!better(heap[parent], heap[worst])) return;

        std.mem.swap(Match, &heap[parent], &heap[worst]);
        parent = worst;
    }
}

fn heapSortBestFirst(heap: []Match) void {
    var end = heap.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Match, &heap[0], &heap[end]);
        heapSiftWorst(heap[0..end], 0);
    }
}

test "score requires an ordered subsequence" {
    try std.testing.expect(score("abc", "a_b_c") != null);
    try std.testing.expect(score("abc", "acb") == null);
}

test "score prefers consecutive and boundary matches" {
    const consecutive = score("fb", "fooBar").?;
    const sparse = score("fb", "f___b").?;
    try std.testing.expect(consecutive > sparse);

    const boundary = score("fb", "foo-bar").?;
    const buried = score("fb", "afxxb").?;
    try std.testing.expect(boundary > buried);
}

test "find returns only the requested best matches" {
    const candidates = [_][]const u8{
        "src/fuzzy_backend.zig",
        "foo_bar",
        "fzzzzb",
        "unrelated",
        "FooBar",
    };

    const matches = try find(std.testing.allocator, "fb", &candidates, 3);
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("FooBar", matches[0].value);
    try std.testing.expect(matches[0].score >= matches[1].score);
    try std.testing.expect(matches[1].score >= matches[2].score);
}

test "find uses original index as final stable tiebreak" {
    const candidates = [_][]const u8{ "abc", "abc", "abc" };
    const matches = try find(std.testing.allocator, "abc", &candidates, 3);
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches[0].index);
    try std.testing.expectEqual(@as(usize, 1), matches[1].index);
    try std.testing.expectEqual(@as(usize, 2), matches[2].index);
}
