const std = @import("std");

const signature_classes = 64;
const signature_levels = 2;
const signature_planes = signature_classes * signature_levels;

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

/// Internal preprocessed query view.
const Query = struct {
    bytes: []const u8,
    classes: []const u6,
    planes: []const u8,
    use_cache: bool,
    impossible: bool,
};

const Entry = struct {
    offset: usize,
    len: usize,
};

const BonusCaps = [2]u64;

const StageMatch = struct {
    entry: usize,
    score: i32,
};

/// Preprocessed candidate array.
///
/// Candidate text is copied into the searchable representation during init,
/// so the input slices do not need to remain alive. Search is intentionally
/// stateful and allocation-free after its internal shortlist has reached the
/// required size; one Index should not be searched concurrently from multiple
/// threads.
pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    lower_bytes: []u8,
    bonuses: []u8,
    bonus_caps: []BonusCaps,

    words: usize,
    planes: []u64,
    plane_frequency: [signature_planes]usize,

    max_len: usize,
    dp: []i32,
    position_scratch: []usize,
    stage: []StageMatch,

    query_bytes: []u8,
    query_classes: []u6,
    query_planes: [signature_classes]u8,
    previous_query: []u8,
    previous_query_len: usize,
    survivors: []u64,
    next_survivors: []u64,
    seed_bits: []u64,
    previous_stage: []usize,
    previous_stage_len: usize,

    fn init(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error!Index {
        var total_bytes: usize = 0;
        var max_len: usize = 0;
        for (values) |value| {
            total_bytes += value.len;
            max_len = @max(max_len, value.len);
        }

        const entries = try allocator.alloc(Entry, values.len);
        errdefer allocator.free(entries);

        const lower_bytes = try allocator.alloc(u8, total_bytes);
        errdefer allocator.free(lower_bytes);

        const bonuses = try allocator.alloc(u8, total_bytes);
        errdefer allocator.free(bonuses);

        const bonus_caps = try allocator.alloc(BonusCaps, values.len);
        errdefer allocator.free(bonus_caps);

        const words = (values.len + 63) / 64;
        const planes = try allocator.alloc(u64, signature_planes * words);
        errdefer allocator.free(planes);
        @memset(planes, 0);

        const dp = try allocator.alloc(i32, max_len * 4);
        errdefer allocator.free(dp);

        const position_scratch = try allocator.alloc(usize, max_len);
        errdefer allocator.free(position_scratch);

        const initial_stage_len = @min(values.len, 16);
        const stage = try allocator.alloc(StageMatch, initial_stage_len);
        errdefer allocator.free(stage);

        const query_bytes = try allocator.alloc(u8, max_len);
        errdefer allocator.free(query_bytes);

        const query_classes = try allocator.alloc(u6, max_len);
        errdefer allocator.free(query_classes);

        const previous_query = try allocator.alloc(u8, max_len);
        errdefer allocator.free(previous_query);

        const survivors = try allocator.alloc(u64, words);
        errdefer allocator.free(survivors);
        @memset(survivors, 0);

        const next_survivors = try allocator.alloc(u64, words);
        errdefer allocator.free(next_survivors);
        @memset(next_survivors, 0);

        const seed_bits = try allocator.alloc(u64, words);
        errdefer allocator.free(seed_bits);
        @memset(seed_bits, 0);

        const previous_stage = try allocator.alloc(usize, initial_stage_len);
        errdefer allocator.free(previous_stage);

        var plane_frequency = [_]usize{0} ** signature_planes;
        var offset: usize = 0;

        for (values, 0..) |value, row| {
            entries[row] = .{
                .offset = offset,
                .len = value.len,
            };

            var counts = [_]u8{0} ** signature_classes;
            var bonus_categories = [_]u2{0} ** signature_classes;
            var previous: CharClass = .white;

            for (value, 0..) |c, i| {
                const folded = lower(c);
                lower_bytes[offset + i] = folded;

                const current = charClass(c);
                const raw_bonus = bonusFor(previous, current);
                bonuses[offset + i] = @intCast(raw_bonus);
                previous = current;

                const class: usize = @intCast(signatureClass(folded));
                if (counts[class] < signature_levels) counts[class] += 1;
                bonus_categories[class] = @max(bonus_categories[class], bonusCategory(raw_bonus));
            }

            var caps: BonusCaps = .{ 0, 0 };
            for (bonus_categories, 0..) |category, class| {
                const cap_word = class / 32;
                const shift: u6 = @intCast((class & 31) * 2);
                caps[cap_word] |= @as(u64, category) << shift;
            }
            bonus_caps[row] = caps;

            if (words != 0) {
                const word = row / 64;
                const row_bit = @as(u64, 1) << @intCast(row & 63);
                for (counts, 0..) |count, class| {
                    if (count >= 1) {
                        const plane = class;
                        planes[plane * words + word] |= row_bit;
                        plane_frequency[plane] += 1;
                    }
                    if (count >= 2) {
                        const plane = signature_classes + class;
                        planes[plane * words + word] |= row_bit;
                        plane_frequency[plane] += 1;
                    }
                }
            }

            offset += value.len;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .lower_bytes = lower_bytes,
            .bonuses = bonuses,
            .bonus_caps = bonus_caps,
            .words = words,
            .planes = planes,
            .plane_frequency = plane_frequency,
            .max_len = max_len,
            .dp = dp,
            .position_scratch = position_scratch,
            .stage = stage,
            .query_bytes = query_bytes,
            .query_classes = query_classes,
            .query_planes = undefined,
            .previous_query = previous_query,
            .previous_query_len = 0,
            .survivors = survivors,
            .next_survivors = next_survivors,
            .seed_bits = seed_bits,
            .previous_stage = previous_stage,
            .previous_stage_len = 0,
        };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.previous_stage);
        self.allocator.free(self.seed_bits);
        self.allocator.free(self.next_survivors);
        self.allocator.free(self.survivors);
        self.allocator.free(self.previous_query);
        self.allocator.free(self.query_classes);
        self.allocator.free(self.query_bytes);
        self.allocator.free(self.stage);
        self.allocator.free(self.position_scratch);
        self.allocator.free(self.dp);
        self.allocator.free(self.planes);
        self.allocator.free(self.bonus_caps);
        self.allocator.free(self.bonuses);
        self.allocator.free(self.lower_bytes);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Preprocess a query into Index-owned scratch memory.
    ///
    /// This always folds the full query once. A query longer than every
    /// candidate is marked impossible immediately.
    fn compileQuery(self: *Index, text: []const u8) Query {
        if (text.len > self.max_len) {
            return .{
                .bytes = self.query_bytes[0..0],
                .classes = self.query_classes[0..0],
                .planes = self.query_planes[0..0],
                .use_cache = false,
                .impossible = true,
            };
        }

        var use_cache = self.previous_query_len != 0 and text.len >= self.previous_query_len;
        var once: u64 = 0;
        var twice: u64 = 0;

        for (text, 0..) |c, i| {
            const folded = lower(c);
            self.query_bytes[i] = folded;
            self.query_classes[i] = signatureClass(folded);

            if (use_cache and i < self.previous_query_len and folded != self.previous_query[i]) {
                use_cache = false;
            }

            const class = self.query_classes[i];
            const bit = @as(u64, 1) << class;
            if ((once & bit) != 0) {
                twice |= bit;
            } else {
                once |= bit;
            }
        }

        const plane_count = self.compilePlanes(once, twice, &self.query_planes);

        return .{
            .bytes = self.query_bytes[0..text.len],
            .classes = self.query_classes[0..text.len],
            .planes = self.query_planes[0..plane_count],
            .use_cache = use_cache,
            .impossible = false,
        };
    }

    /// Search the preprocessed array and write candidate indices into `out`.
    /// The returned slice aliases `out` and is sorted best-first.
    ///
    /// Scores use fzf V2 for the supported bytewise ASCII-folding mode. Score
    /// ties prefer shorter candidates, then original array order. Preprocessed
    /// signatures reject impossible rows, prefix extensions
    /// reuse the previous exact subsequence survivor set, and a safe score
    /// upper bound skips V2 dynamic programming when a row cannot enter top-K.
    pub fn search(self: *Index, text: []const u8, out: []usize) std.mem.Allocator.Error![]usize {
        if (out.len == 0 or self.entries.len == 0) return out[0..0];

        const q = self.compileQuery(text);

        if (q.impossible) {
            self.resetHistory();
            return out[0..0];
        }

        if (q.bytes.len == 0) {
            self.resetHistory();
            const len = @min(out.len, self.entries.len);
            for (0..len) |i| out[i] = i;
            return out[0..len];
        }

        const top_k = @min(out.len, self.entries.len);
        try self.ensureStage(top_k);

        @memset(self.next_survivors, 0);
        @memset(self.seed_bits, 0);

        var stage_len: usize = 0;

        // On a prefix extension, score the previous exact top-K first. This is
        // correctness-neutral but quickly establishes a strong lower bound for
        // branch-and-bound pruning on the remaining rows.
        if (q.use_cache and self.previous_stage_len != 0) {
            const seed_len = @min(self.previous_stage_len, top_k);
            for (self.previous_stage[0..seed_len]) |entry_index| {
                if (!self.rowPasses(entry_index, q.planes, true)) continue;

                const word = entry_index / 64;
                const row_bit = @as(u64, 1) << @intCast(entry_index & 63);
                self.seed_bits[word] |= row_bit;

                const entry = self.entries[entry_index];
                if (q.bytes.len > entry.len) continue;
                if (!self.subsequence(&q, entry)) continue;
                self.next_survivors[word] |= row_bit;

                self.addStage(.{
                    .entry = entry_index,
                    .score = self.scoreV2FromFirst(&q, entry),
                }, top_k, &stage_len);
            }
        }

        var word: usize = 0;
        while (word < self.words) : (word += 1) {
            var bits = self.planes[@as(usize, @intCast(q.planes[0])) * self.words + word];

            var p: usize = 1;
            while (p < q.planes.len and bits != 0) : (p += 1) {
                bits &= self.planes[@as(usize, @intCast(q.planes[p])) * self.words + word];
            }

            if (q.use_cache) bits &= self.survivors[word];
            bits &= ~self.seed_bits[word];

            while (bits != 0) {
                const bit_index: usize = @intCast(@ctz(bits));
                const row_bit = @as(u64, 1) << @intCast(bit_index);
                bits &= bits - 1;

                const entry_index = word * 64 + bit_index;
                if (entry_index >= self.entries.len) continue;

                const entry = self.entries[entry_index];
                if (q.bytes.len > entry.len) continue;

                // This linear scan is exact and also prepares fzf V2's first
                // feasible position for each query byte, so DP does not repeat
                // the subsequence prefilter.
                if (!self.subsequence(&q, entry)) continue;
                self.next_survivors[word] |= row_bit;

                if (stage_len == top_k and
                    self.scoreUpperBound(&q, self.bonus_caps[entry_index]) < self.stage[0].score)
                {
                    continue;
                }

                self.addStage(.{
                    .entry = entry_index,
                    .score = self.scoreV2FromFirst(&q, entry),
                }, top_k, &stage_len);
            }
        }

        std.mem.swap([]u64, &self.survivors, &self.next_survivors);
        @memcpy(self.previous_query[0..q.bytes.len], q.bytes);
        self.previous_query_len = q.bytes.len;

        if (stage_len == 0) {
            self.previous_stage_len = 0;
            return out[0..0];
        }

        stageSortBestFirst(self.entries, self.stage[0..stage_len]);

        self.previous_stage_len = stage_len;
        for (self.stage[0..stage_len], 0..) |stage_item, i| {
            self.previous_stage[i] = stage_item.entry;
            out[i] = stage_item.entry;
        }
        return out[0..stage_len];
    }

    fn addStage(self: *Index, item: StageMatch, desired_stage: usize, stage_len: *usize) void {
        if (stage_len.* < desired_stage) {
            self.stage[stage_len.*] = item;
            stageBubbleWorst(self.entries, self.stage[0 .. stage_len.* + 1], stage_len.*);
            stage_len.* += 1;
        } else if (betterStage(self.entries, item, self.stage[0])) {
            self.stage[0] = item;
            stageSiftWorst(self.entries, self.stage[0..stage_len.*], 0);
        }
    }

    fn rowPasses(self: *const Index, entry_index: usize, planes: []const u8, use_cache: bool) bool {
        const word = entry_index / 64;
        const row_bit = @as(u64, 1) << @intCast(entry_index & 63);
        if (use_cache and (self.survivors[word] & row_bit) == 0) return false;

        for (planes) |plane| {
            if ((self.planes[@as(usize, @intCast(plane)) * self.words + word] & row_bit) == 0) return false;
        }
        return true;
    }

    fn resetHistory(self: *Index) void {
        self.previous_query_len = 0;
        self.previous_stage_len = 0;
        @memset(self.survivors, 0);
        @memset(self.next_survivors, 0);
        @memset(self.seed_bits, 0);
    }

    fn ensureStage(self: *Index, needed: usize) std.mem.Allocator.Error!void {
        if (needed <= self.stage.len) return;
        self.stage = try self.allocator.realloc(self.stage, needed);
        self.previous_stage = try self.allocator.realloc(self.previous_stage, needed);
    }

    fn compilePlanes(self: *const Index, once: u64, twice: u64, ids: *[signature_classes]u8) usize {
        var len: usize = 0;
        var remaining = once;

        while (remaining != 0) {
            const class: u6 = @intCast(@ctz(remaining));
            const bit = @as(u64, 1) << class;
            const plane: usize = if ((twice & bit) != 0)
                signature_classes + @as(usize, @intCast(class))
            else
                @as(usize, @intCast(class));

            ids[len] = @intCast(plane);
            len += 1;
            remaining &= remaining - 1;
        }

        // Rarest planes first makes zero intersections short-circuit early.
        var i: usize = 1;
        while (i < len) : (i += 1) {
            const key = ids[i];
            const key_frequency = self.plane_frequency[@intCast(key)];
            var j = i;
            while (j > 0 and self.plane_frequency[@intCast(ids[j - 1])] > key_frequency) : (j -= 1) {
                ids[j] = ids[j - 1];
            }
            ids[j] = key;
        }

        return len;
    }

    fn candidateLower(self: *const Index, entry: Entry) []const u8 {
        return self.lower_bytes[entry.offset .. entry.offset + entry.len];
    }

    fn candidateBonuses(self: *const Index, entry: Entry) []const u8 {
        return self.bonuses[entry.offset .. entry.offset + entry.len];
    }

    /// Exact fzf V1 score for the supported bytewise ASCII-folding mode.
    fn scoreV1(self: *const Index, q: *const Query, entry: Entry) ?i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const m = q.bytes.len;

        if (m == 0) return 0;
        if (m > text.len) return null;

        var pattern_index: usize = 0;
        var start: ?usize = null;
        var end: usize = 0;

        for (text, 0..) |c, i| {
            if (c != q.bytes[pattern_index]) continue;
            if (start == null) start = i;
            pattern_index += 1;
            if (pattern_index == m) {
                end = i + 1;
                break;
            }
        }
        if (pattern_index != m) return null;

        var contracted_start = start.?;
        pattern_index = m;
        var i = end;
        while (i > contracted_start and pattern_index > 0) {
            i -= 1;
            if (text[i] != q.bytes[pattern_index - 1]) continue;
            pattern_index -= 1;
            if (pattern_index == 0) {
                contracted_start = i;
                break;
            }
        }

        var score: i32 = 0;
        pattern_index = 0;
        var in_gap = false;
        var consecutive: usize = 0;
        var first_bonus: i32 = 0;

        i = contracted_start;
        while (i < end) : (i += 1) {
            if (text[i] == q.bytes[pattern_index]) {
                score += score_match;
                var b: i32 = @intCast(bonus[i]);

                if (consecutive == 0) {
                    first_bonus = b;
                } else {
                    if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
                    b = @max(b, @max(first_bonus, bonus_consecutive));
                }

                score += if (pattern_index == 0) b * bonus_first_char_multiplier else b;
                in_gap = false;
                consecutive += 1;
                pattern_index += 1;
                if (pattern_index == m) break;
            } else {
                score += if (in_gap) score_gap_extension else score_gap_start;
                in_gap = true;
                consecutive = 0;
            }
        }

        return score;
    }

    /// Exact ordered-subsequence test. On success, also stores fzf V2's
    /// first feasible text position for every query byte in position_scratch.
    fn subsequence(self: *Index, q: *const Query, entry: Entry) bool {
        const text = self.candidateLower(entry);
        if (q.bytes.len == 0) return true;
        if (q.bytes.len > text.len) return false;

        var pattern_index: usize = 0;
        for (text, 0..) |c, i| {
            if (c != q.bytes[pattern_index]) continue;
            self.position_scratch[pattern_index] = i;
            pattern_index += 1;
            if (pattern_index == q.bytes.len) return true;
        }
        return false;
    }

    /// Safe upper bound for any fzf V2 alignment of this query/candidate.
    ///
    /// Candidate preprocessing stores the maximum raw fzf bonus for each of
    /// 64 folded character classes, rounded upward into {0, 8, 9, 10}. For a
    /// consecutive run, fzf can inherit a previous run-start bonus, so this
    /// deliberately carries the maximum bonus seen over the whole query. It
    /// also ignores all gap penalties. Both choices can only overestimate the
    /// achievable score, which makes pruning exact rather than heuristic.
    fn scoreUpperBound(self: *const Index, q: *const Query, caps: BonusCaps) i32 {
        _ = self;
        if (q.bytes.len == 0) return 0;

        var total: i32 = @as(i32, @intCast(q.bytes.len)) * score_match;
        var prefix_bonus = bonusCap(caps, q.classes[0]);
        total += prefix_bonus * bonus_first_char_multiplier;

        for (q.classes[1..]) |class| {
            prefix_bonus = @max(prefix_bonus, bonusCap(caps, class));
            total += @max(prefix_bonus, bonus_consecutive);
        }
        return total;
    }

    /// Exact fzf V2 score, assuming subsequence() already populated
    /// position_scratch for this query/candidate. Score-only needs two DP rows
    /// instead of fzf's full backtrace matrix.
    fn scoreV2FromFirst(self: *Index, q: *const Query, entry: Entry) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const m = q.bytes.len;
        const n = text.len;
        const first = self.position_scratch[0..m];

        var h0 = self.dp[0..n];
        const h1 = self.dp[self.max_len .. self.max_len + n];
        var c0 = self.dp[self.max_len * 2 .. self.max_len * 2 + n];
        const c1 = self.dp[self.max_len * 3 .. self.max_len * 3 + n];

        var in_gap = false;
        var previous_score: i32 = 0;
        var max_score: i32 = 0;
        const first_char = q.bytes[0];

        for (text, 0..) |c, j| {
            if (c == first_char) {
                h0[j] = score_match + @as(i32, @intCast(bonus[j])) * bonus_first_char_multiplier;
                c0[j] = 1;
                in_gap = false;
                if (m == 1) max_score = @max(max_score, h0[j]);
            } else {
                h0[j] = @max(previous_score + (if (in_gap) score_gap_extension else score_gap_start), 0);
                c0[j] = 0;
                in_gap = true;
            }
            previous_score = h0[j];
        }
        if (m == 1) return max_score;

        var previous_h: []i32 = h0;
        var previous_c: []i32 = c0;
        var current_h: []i32 = h1;
        var current_c: []i32 = c1;

        var pattern_index: usize = 1;
        while (pattern_index < m) : (pattern_index += 1) {
            const first_feasible = first[pattern_index];
            const pattern_char = q.bytes[pattern_index];
            in_gap = false;

            var j = first_feasible;
            while (j < n) : (j += 1) {
                const left: i32 = if (j > first_feasible) current_h[j - 1] else 0;
                const gap_score = left + (if (in_gap) score_gap_extension else score_gap_start);

                var match_score: i32 = -1_000_000_000;
                var consecutive: i32 = 0;

                if (text[j] == pattern_char and j > 0) {
                    match_score = previous_h[j - 1] + score_match;
                    var b: i32 = @intCast(bonus[j]);
                    consecutive = previous_c[j - 1] + 1;

                    if (consecutive > 1) {
                        const run_start = j + 1 - @as(usize, @intCast(consecutive));
                        const first_bonus: i32 = @intCast(bonus[run_start]);
                        if (b >= bonus_boundary and b > first_bonus) {
                            consecutive = 1;
                        } else {
                            b = @max(b, @max(bonus_consecutive, first_bonus));
                        }
                    }

                    if (match_score + b < gap_score) {
                        match_score += @intCast(bonus[j]);
                        consecutive = 0;
                    } else {
                        match_score += b;
                    }
                }

                current_c[j] = consecutive;
                in_gap = match_score < gap_score;
                const score = @max(@max(match_score, gap_score), 0);
                current_h[j] = score;

                if (pattern_index == m - 1) max_score = @max(max_score, score);
            }

            const temp_h = previous_h;
            previous_h = current_h;
            current_h = temp_h;

            const temp_c = previous_c;
            previous_c = current_c;
            current_c = temp_c;
        }

        return max_score;
    }

    /// Convenience wrapper used by parity tests.
    fn scoreV2(self: *Index, q: *const Query, entry: Entry) ?i32 {
        if (q.bytes.len == 0) return 0;
        if (!self.subsequence(q, entry)) return null;
        return self.scoreV2FromFirst(q, entry);
    }
};

/// Preprocess an immutable candidate array for repeated searching.
pub fn init(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error!Index {
    return Index.init(allocator, values);
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn signatureClass(c: u8) u6 {
    const folded = lower(c);
    if (folded >= 'a' and folded <= 'z') return @intCast(folded - 'a');
    if (folded >= '0' and folded <= '9') return @intCast(26 + folded - '0');

    return switch (folded) {
        ' ' => 36,
        '_' => 37,
        '-' => 38,
        '.' => 39,
        '/' => 40,
        '\\' => 41,
        ':' => 42,
        ';' => 43,
        ',' => 44,
        '|' => 45,
        '@' => 46,
        '#' => 47,
        '+' => 48,
        '=' => 49,
        '(' => 50,
        ')' => 51,
        '[' => 52,
        ']' => 53,
        '{' => 54,
        '}' => 55,
        else => if (folded < 32)
            56
        else if (folded < 48)
            57
        else if (folded < 65)
            58
        else if (folded < 97)
            59
        else if (folded < 127)
            60
        else if (folded == 127)
            61
        else if (folded < 192)
            62
        else
            63,
    };
}

fn bonusCategory(raw_bonus: i32) u2 {
    if (raw_bonus <= 0) return 0;
    if (raw_bonus <= 8) return 1;
    if (raw_bonus == 9) return 2;
    return 3;
}

fn bonusCap(caps: BonusCaps, class: u6) i32 {
    const class_index: usize = @intCast(class);
    const word = class_index / 32;
    const shift: u6 = @intCast((class_index & 31) * 2);
    const category: u2 = @truncate(caps[word] >> shift);
    return switch (category) {
        0 => 0,
        1 => 8,
        2 => 9,
        3 => 10,
    };
}

fn charClass(c: u8) CharClass {
    if (c >= 'a' and c <= 'z') return .lower;
    if (c >= 'A' and c <= 'Z') return .upper;
    if (c >= '0' and c <= '9') return .number;
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => .white,
        '/', ',', ':', ';', '|' => .delimiter,
        else => .non_word,
    };
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

fn betterStage(entries: []const Entry, a: StageMatch, b: StageMatch) bool {
    if (a.score != b.score) return a.score > b.score;
    const av = entries[a.entry];
    const bv = entries[b.entry];
    if (av.len != bv.len) return av.len < bv.len;
    return a.entry < b.entry;
}

fn stageBubbleWorst(entries: []const Entry, heap: []StageMatch, start: usize) void {
    var child = start;
    while (child > 0) {
        const parent = (child - 1) / 2;
        if (!betterStage(entries, heap[parent], heap[child])) break;
        std.mem.swap(StageMatch, &heap[parent], &heap[child]);
        child = parent;
    }
}

fn stageSiftWorst(entries: []const Entry, heap: []StageMatch, start: usize) void {
    var parent = start;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= heap.len) return;

        var worst = left;
        const right = left + 1;
        if (right < heap.len and betterStage(entries, heap[left], heap[right])) worst = right;
        if (!betterStage(entries, heap[parent], heap[worst])) return;

        std.mem.swap(StageMatch, &heap[parent], &heap[worst]);
        parent = worst;
    }
}

fn stageSortBestFirst(entries: []const Entry, heap: []StageMatch) void {
    var end = heap.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(StageMatch, &heap[0], &heap[end]);
        stageSiftWorst(entries, heap[0..end], 0);
    }
}

test "query preprocessing tracks one and two occurrences" {
    const values = [_][]const u8{"aab1"};
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const q = index.compileQuery("aab1");
    const a_twice: u8 = @intCast(signature_classes + @as(usize, @intCast(signatureClass('a'))));
    const b_once: u8 = @intCast(signatureClass('b'));
    const one_once: u8 = @intCast(signatureClass('1'));

    var has_a_twice = false;
    var has_b_once = false;
    var has_one_once = false;
    for (q.planes) |plane| {
        if (plane == a_twice) has_a_twice = true;
        if (plane == b_once) has_b_once = true;
        if (plane == one_once) has_one_once = true;
    }

    try std.testing.expectEqualStrings("aab1", q.bytes);
    try std.testing.expect(has_a_twice);
    try std.testing.expect(has_b_once);
    try std.testing.expect(has_one_once);
}

test "score ceiling never underestimates representative V2 scores" {
    const values = [_][]const u8{
        "fooBarbaz1",
        "foo bar baz",
        "/AutomatorDocument.icns",
        "/man1/zshcompctl.1",
        "/.oh-my-zsh/cache",
        "abcabcabc",
        "src/FrameBuffer.zig",
    };
    const queries = [_][]const u8{ "obz", "fbb", "rdoc", "zshc", "abc", "fb" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        for (index.entries, 0..) |entry, i| {
            const actual = index.scoreV2(&q, entry) orelse continue;
            const ceiling = index.scoreUpperBound(&q, index.bonus_caps[i]);
            try std.testing.expect(actual <= ceiling);
        }
    }
}

test "ported V1 and V2 match fzf scoring vectors" {
    const Case = struct { value: []const u8, q: []const u8, expected: i32 };
    const cases = [_]Case{
        .{ .value = "fooBarbaz1", .q = "oBZ", .expected = 16 * 3 + 7 - 3 - 3 },
        .{ .value = "foo bar baz", .q = "fbb", .expected = 16 * 3 + 10 * 2 + 10 * 2 + 2 * (-3) + 4 * (-1) },
        .{ .value = "/AutomatorDocument.icns", .q = "rdoc", .expected = 16 * 4 + 7 + 4 * 2 },
        .{ .value = "/man1/zshcompctl.1", .q = "zshc", .expected = 16 * 4 + 9 * 2 + 9 * 3 },
        .{ .value = "/.oh-my-zsh/cache", .q = "zshc", .expected = 16 * 4 + 8 * 2 + 8 * 2 - 3 + 9 },
        .{ .value = "foo/bar/baz", .q = "fbb", .expected = 16 * 3 + 10 * 2 + 9 * 2 + 2 * (-3) + 4 * (-1) },
        .{ .value = "fooBarBaz", .q = "fbb", .expected = 16 * 3 + 10 * 2 + 7 * 2 + 2 * (-3) + 2 * (-1) },
        .{ .value = "fooBar Baz", .q = "foob", .expected = 16 * 4 + 10 * 2 + 10 * 3 },
    };

    for (cases) |case| {
        const values = [_][]const u8{case.value};
        var index = try init(std.testing.allocator, &values);
        defer index.deinit();

        const q = index.compileQuery(case.q);
        const entry = index.entries[0];
        try std.testing.expectEqual(case.expected, index.scoreV1(&q, entry).?);
        try std.testing.expectEqual(case.expected, index.scoreV2(&q, entry).?);
    }
}

test "search filters impossible rows and returns V2-ranked results" {
    const values = [_][]const u8{
        "src/fuzzy_backend.zig",
        "foo_bar",
        "FooBar",
        "unrelated",
        "fzzzzb",
        "alpha",
    };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    var storage: [3]usize = undefined;
    const matches = try index.search("fb", &storage);

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(@as(usize, 2), matches[0]);
}

test "prefix extension reuses exact survivor cache and backspace resets it" {
    const values = [_][]const u8{
        "foo_bar",
        "FooBar",
        "far_baz",
        "unrelated",
        "football",
    };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    var storage: [5]usize = undefined;

    _ = try index.search("f", &storage);

    const extension = index.compileQuery("fb");
    try std.testing.expect(extension.use_cache);
    const cached = try index.search("fb", &storage);

    var fresh = try init(std.testing.allocator, &values);
    defer fresh.deinit();
    var fresh_storage: [5]usize = undefined;
    const uncached = try fresh.search("fb", &fresh_storage);

    try std.testing.expectEqualSlices(usize, uncached, cached);

    const backspace = index.compileQuery("f");
    try std.testing.expect(!backspace.use_cache);
}
