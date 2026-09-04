const std = @import("std");
const unicode_cli = @import("unicode_tables.zig");

const signature_classes = 64;
const signature_levels = 2;
const signature_planes = signature_classes * signature_levels;
const last_slots = 24;
const exact_signature_classes = 56;
const single_cache_limit = 64;

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
    plane_offsets: []const usize,
    cap_word_mask: u2,
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

const IndexedPosition = struct {
    first: u8,
    last: u8,
};

const lower_lut: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (0..256) |i| table[i] = lower(@intCast(i));
    break :blk table;
};
const signature_lut: [256]u6 = blk: {
    var table: [256]u6 = undefined;
    for (0..256) |i| table[i] = signatureClass(@intCast(i));
    break :blk table;
};
const char_class_lut: [256]CharClass = blk: {
    var table: [256]CharClass = undefined;
    for (0..256) |i| table[i] = charClass(@intCast(i));
    break :blk table;
};
const bonus_lut: [6][6]u8 = blk: {
    var table: [6][6]u8 = undefined;
    for (0..6) |previous| {
        for (0..6) |current| {
            table[previous][current] = @intCast(bonusFor(@enumFromInt(previous), @enumFromInt(current)));
        }
    }
    break :blk table;
};

fn makeBoundBonusTable(comptime m: usize) [1 << (2 * m)]u8 {
    @setEvalBranchQuota(100000);
    var out: [1 << (2 * m)]u8 = undefined;
    for (0..out.len) |packed_value| {
        var x = packed_value;
        var prefix: i32 = 0;
        var total: i32 = 0;
        for (0..m) |i| {
            const category: u2 = @truncate(x);
            x >>= 2;
            const b: i32 = switch (category) {
                0 => 0,
                1 => 8,
                2 => 9,
                3 => 10,
            };
            prefix = @max(prefix, b);
            total += if (i == 0)
                prefix * bonus_first_char_multiplier
            else
                @max(prefix, bonus_consecutive);
        }
        out[packed_value] = @intCast(total);
    }
    return out;
}

const bound_bonus3 = makeBoundBonusTable(3);
const bound_bonus4 = makeBoundBonusTable(4);
const bound_bonus5 = makeBoundBonusTable(5);
const bound_bonus6 = makeBoundBonusTable(6);

fn categoryBonusValue(category: u2) u8 {
    return switch (category) {
        0 => 0,
        1 => 8,
        2 => 9,
        3 => 10,
    };
}

fn makeBoundFirst4Sum() [256]u8 {
    @setEvalBranchQuota(20000);
    var out: [256]u8 = undefined;
    for (0..256) |packed_value| {
        var x = packed_value;
        var prefix: u2 = 0;
        var total: u8 = 0;
        for (0..4) |i| {
            const category: u2 = @truncate(x);
            x >>= 2;
            prefix = @max(prefix, category);
            const b = categoryBonusValue(prefix);
            total += if (i == 0) b * bonus_first_char_multiplier else @max(b, bonus_consecutive);
        }
        out[packed_value] = total;
    }
    return out;
}

fn makeBoundFirst4Out() [256]u8 {
    @setEvalBranchQuota(10000);
    var out: [256]u8 = undefined;
    for (0..256) |packed_value| {
        var x = packed_value;
        var prefix: u2 = 0;
        for (0..4) |_| {
            const category: u2 = @truncate(x);
            x >>= 2;
            prefix = @max(prefix, category);
        }
        out[packed_value] = prefix;
    }
    return out;
}

fn makeBoundNextSum(comptime count: usize) [4][1 << (2 * count)]u8 {
    @setEvalBranchQuota(100000);
    var out: [4][1 << (2 * count)]u8 = undefined;
    for (0..4) |incoming| {
        for (0..out[incoming].len) |packed_value| {
            var x = packed_value;
            var prefix: u2 = @intCast(incoming);
            var total: u8 = 0;
            for (0..count) |_| {
                const category: u2 = @truncate(x);
                x >>= 2;
                prefix = @max(prefix, category);
                total += @max(categoryBonusValue(prefix), bonus_consecutive);
            }
            out[incoming][packed_value] = total;
        }
    }
    return out;
}

const bound_first4_sum = makeBoundFirst4Sum();
const bound_first4_out = makeBoundFirst4Out();
const bound_next3_sum = makeBoundNextSum(3);
const bound_next4_sum = makeBoundNextSum(4);

fn bonusCategoryRaw(caps: BonusCaps, class: u6) u2 {
    const class_index: usize = @intCast(class);
    const word = class_index >> 5;
    const shift: u6 = @intCast((class_index & 31) * 2);
    return @truncate(caps[word] >> shift);
}

fn packedBoundIndex(comptime m: usize, caps: BonusCaps, classes: []const u6) usize {
    var index: usize = 0;
    inline for (0..m) |i| {
        index |= @as(usize, bonusCategoryRaw(caps, classes[i])) << @intCast(2 * i);
    }
    return index;
}

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
    last_positions: []IndexedPosition,
    last_slot_for_class: [exact_signature_classes]u8,
    single_top: []usize,
    single_top_len: [exact_signature_classes]u8,

    words: usize,
    planes: []u64,
    plane_frequency: [signature_planes]usize,

    max_len: usize,
    dp: []i16,
    position_scratch: []usize,
    last_position_scratch: []usize,
    stage: []StageMatch,

    query_bytes: []u8,
    query_classes: []u6,
    query_planes: [signature_classes]u8,
    query_plane_offsets: [signature_classes]usize,
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

        var slot_frequency = [_]usize{0} ** exact_signature_classes;
        const slot_sample_count = @min(values.len, 2048);
        for (0..slot_sample_count) |sample_index| {
            const value = values[sample_index * values.len / slot_sample_count];
            var seen_exact: u64 = 0;
            for (value) |c| {
                const class: usize = @intCast(signature_lut[c]);
                if (class < exact_signature_classes) seen_exact |= @as(u64, 1) << @intCast(class);
            }
            while (seen_exact != 0) {
                const class: usize = @intCast(@ctz(seen_exact));
                seen_exact &= seen_exact - 1;
                slot_frequency[class] += 1;
            }
        }

        var last_slot_for_class = [_]u8{0xff} ** exact_signature_classes;
        var selected_count: usize = 0;
        while (selected_count < last_slots) : (selected_count += 1) {
            var best_class: usize = 0;
            var best_frequency: usize = 0;
            for (0..exact_signature_classes) |class| {
                if (last_slot_for_class[class] != 0xff) continue;
                const frequency = slot_frequency[class];
                if (frequency > best_frequency) {
                    best_frequency = frequency;
                    best_class = class;
                }
            }
            last_slot_for_class[best_class] = @intCast(selected_count);
        }
        var last_slot_for_byte = [_]u8{0xff} ** 256;
        for (0..256) |byte_value| {
            const class: usize = @intCast(signatureClass(@intCast(byte_value)));
            if (class < exact_signature_classes) last_slot_for_byte[byte_value] = last_slot_for_class[class];
        }

        const entries = try allocator.alloc(Entry, values.len);
        errdefer allocator.free(entries);

        const lower_bytes = try allocator.alloc(u8, total_bytes);
        errdefer allocator.free(lower_bytes);

        const bonuses = try allocator.alloc(u8, total_bytes);
        errdefer allocator.free(bonuses);

        const bonus_caps = try allocator.alloc(BonusCaps, values.len);
        errdefer allocator.free(bonus_caps);

        const last_positions = try allocator.alloc(IndexedPosition, last_slots * values.len);
        errdefer allocator.free(last_positions);
        @memset(last_positions, .{ .first = 0xff, .last = 0xff });

        const single_stage = try allocator.alloc(StageMatch, exact_signature_classes * single_cache_limit);
        defer allocator.free(single_stage);
        var single_top_len = [_]u8{0} ** exact_signature_classes;

        const words = (values.len + 63) / 64;
        const planes = try allocator.alloc(u64, signature_planes * words);
        errdefer allocator.free(planes);
        @memset(planes, 0);

        const dp = try allocator.alloc(i16, max_len * 4);
        errdefer allocator.free(dp);

        const position_scratch = try allocator.alloc(usize, max_len);
        errdefer allocator.free(position_scratch);

        const last_position_scratch = try allocator.alloc(usize, max_len);
        errdefer allocator.free(last_position_scratch);

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

            var once: u64 = 0;
            var twice: u64 = 0;
            var caps: BonusCaps = .{ 0, 0 };
            var single_scores = [_]u8{0} ** exact_signature_classes;
            var previous: CharClass = .white;

            for (value, 0..) |c, i| {
                const folded = lower_lut[c];
                lower_bytes[offset + i] = folded;

                const current = char_class_lut[c];
                const raw_bonus: i32 = bonus_lut[@intFromEnum(previous)][@intFromEnum(current)];
                bonuses[offset + i] = @intCast(raw_bonus);
                previous = current;

                const class: usize = @intCast(signature_lut[c]);
                const class_bit = @as(u64, 1) << @intCast(class);
                const first_class_occurrence = (once & class_bit) == 0;
                if (first_class_occurrence) {
                    once |= class_bit;
                } else {
                    twice |= class_bit;
                }

                const slot = last_slot_for_byte[folded];
                if (slot != 0xff and value.len < 256) {
                    const meta = &last_positions[@as(usize, slot) * values.len + row];
                    const pos: u8 = @intCast(i);
                    if (first_class_occurrence) meta.first = pos;
                    meta.last = pos;
                }

                const cap_word = class / 32;
                const cap_shift: u6 = @intCast((class & 31) * 2);
                const category = bonusCategory(raw_bonus);
                const old_category: u2 = @truncate(caps[cap_word] >> cap_shift);
                if (category > old_category) {
                    const mask = @as(u64, 3) << cap_shift;
                    caps[cap_word] = (caps[cap_word] & ~mask) | (@as(u64, category) << cap_shift);
                }

                if (class < exact_signature_classes) {
                    // A raw bonus >= boundary settles scoreV2Single at this
                    // first strong occurrence. Before that, only the maximum
                    // weak occurrence matters.
                    if (single_scores[class] < score_match + bonus_boundary * bonus_first_char_multiplier) {
                        const one_score: u8 = @intCast(score_match + raw_bonus * bonus_first_char_multiplier);
                        if (raw_bonus >= bonus_boundary or one_score > single_scores[class]) {
                            single_scores[class] = one_score;
                        }
                    }
                }
            }

            var remaining_single = once & ((@as(u64, 1) << exact_signature_classes) - 1);
            while (remaining_single != 0) {
                const class: usize = @intCast(@ctz(remaining_single));
                remaining_single &= remaining_single - 1;
                const segment = single_stage[class * single_cache_limit .. (class + 1) * single_cache_limit];
                var segment_len: usize = single_top_len[class];
                const item: StageMatch = .{ .entry = row, .score = single_scores[class] };
                if (segment_len < single_cache_limit) {
                    segment[segment_len] = item;
                    stageBubbleWorst(entries, segment[0 .. segment_len + 1], segment_len);
                    segment_len += 1;
                    single_top_len[class] = @intCast(segment_len);
                } else if (betterStage(entries, item, segment[0])) {
                    segment[0] = item;
                    stageSiftWorst(entries, segment, 0);
                }
            }

            bonus_caps[row] = caps;

            if (words != 0) {
                const word = row / 64;
                const row_bit = @as(u64, 1) << @intCast(row & 63);

                var remaining_once = once;
                while (remaining_once != 0) {
                    const class: usize = @intCast(@ctz(remaining_once));
                    remaining_once &= remaining_once - 1;
                    planes[class * words + word] |= row_bit;
                    plane_frequency[class] += 1;
                }

                var remaining_twice = twice;
                while (remaining_twice != 0) {
                    const class: usize = @intCast(@ctz(remaining_twice));
                    remaining_twice &= remaining_twice - 1;
                    const plane = signature_classes + class;
                    planes[plane * words + word] |= row_bit;
                    plane_frequency[plane] += 1;
                }
            }

            offset += value.len;
        }

        const single_top = try allocator.alloc(usize, exact_signature_classes * single_cache_limit);
        errdefer allocator.free(single_top);
        @memset(single_top, 0);
        for (0..exact_signature_classes) |class| {
            const len: usize = single_top_len[class];
            const segment = single_stage[class * single_cache_limit .. class * single_cache_limit + len];
            stageSortBestFirst(entries, segment);
            for (segment, 0..) |item, i| single_top[class * single_cache_limit + i] = item.entry;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .lower_bytes = lower_bytes,
            .bonuses = bonuses,
            .bonus_caps = bonus_caps,
            .last_positions = last_positions,
            .last_slot_for_class = last_slot_for_class,
            .single_top = single_top,
            .single_top_len = single_top_len,
            .words = words,
            .planes = planes,
            .plane_frequency = plane_frequency,
            .max_len = max_len,
            .dp = dp,
            .position_scratch = position_scratch,
            .last_position_scratch = last_position_scratch,
            .stage = stage,
            .query_bytes = query_bytes,
            .query_classes = query_classes,
            .query_planes = undefined,
            .query_plane_offsets = undefined,
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
        self.allocator.free(self.last_position_scratch);
        self.allocator.free(self.position_scratch);
        self.allocator.free(self.dp);
        self.allocator.free(self.planes);
        self.allocator.free(self.single_top);
        self.allocator.free(self.last_positions);
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
                .plane_offsets = self.query_plane_offsets[0..0],
                .cap_word_mask = 0,
                .use_cache = false,
                .impossible = true,
            };
        }

        var use_cache = self.previous_query_len != 0 and text.len >= self.previous_query_len;
        var once: u64 = 0;
        var twice: u64 = 0;
        var cap_word_mask: u2 = 0;

        for (text, 0..) |c, i| {
            const folded = lower(c);
            self.query_bytes[i] = folded;
            self.query_classes[i] = signatureClass(folded);

            if (use_cache and i < self.previous_query_len and folded != self.previous_query[i]) {
                use_cache = false;
            }

            const class = self.query_classes[i];
            cap_word_mask |= @as(u2, 1) << @intCast(@as(usize, @intCast(class)) >> 5);
            const bit = @as(u64, 1) << class;
            if ((once & bit) != 0) {
                twice |= bit;
            } else {
                once |= bit;
            }
        }

        const plane_count = self.compilePlanes(once, twice, &self.query_planes);
        for (self.query_planes[0..plane_count], 0..) |plane, i| {
            self.query_plane_offsets[i] = @as(usize, @intCast(plane)) * self.words;
        }

        return .{
            .bytes = self.query_bytes[0..text.len],
            .classes = self.query_classes[0..text.len],
            .planes = self.query_planes[0..plane_count],
            .plane_offsets = self.query_plane_offsets[0..plane_count],
            .cap_word_mask = cap_word_mask,
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
        const first_class: usize = @intCast(q.classes[0]);
        const first_slot: u8 = if (first_class < exact_signature_classes) self.last_slot_for_class[first_class] else 0xff;
        const last_class: usize = @intCast(q.classes[q.classes.len - 1]);
        const last_slot: u8 = if (last_class < exact_signature_classes) self.last_slot_for_class[last_class] else 0xff;

        if (q.bytes.len == 1 and top_k <= single_cache_limit) {
            const class: usize = @intCast(signatureClass(q.bytes[0]));
            if (class < exact_signature_classes) {
                const cached_len: usize = self.single_top_len[class];
                const result_len = @min(top_k, cached_len);
                const cached = self.single_top[class * single_cache_limit .. class * single_cache_limit + result_len];
                @memcpy(out[0..result_len], cached);

                // For an exact signature class, its once-plane is exactly the
                // complete one-byte subsequence survivor set. Preserve normal
                // prefix-extension caching without scanning candidate text.
                if (self.words != 0) {
                    const plane = self.planes[class * self.words .. (class + 1) * self.words];
                    @memcpy(self.survivors, plane);
                    @memset(self.next_survivors, 0);
                    @memset(self.seed_bits, 0);
                }
                self.previous_query[0] = q.bytes[0];
                self.previous_query_len = 1;
                self.previous_stage_len = result_len;
                @memcpy(self.previous_stage[0..result_len], cached);
                return out[0..result_len];
            }
        }

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
                if (!self.subsequenceIndexed(&q, entry, entry_index, first_slot, entry.len)) continue;
                self.next_survivors[word] |= row_bit;

                self.addStage(.{
                    .entry = entry_index,
                    .score = self.scoreV2IndexedFromFirst(&q, entry, entry_index),
                }, top_k, &stage_len);
            }
        }

        var word: usize = 0;
        while (word < self.words) : (word += 1) {
            var bits = self.planes[q.plane_offsets[0] + word];

            var p: usize = 1;
            while (p < q.plane_offsets.len and bits != 0) : (p += 1) {
                bits &= self.planes[q.plane_offsets[p] + word];
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

                // The precomputed bonus ceiling needs no candidate scan. Once
                // top-K is full, use it before the ordered-subsequence pass.
                // Rows skipped here stay in the prefix cache as "possible";
                // that cache is allowed to be a superset, so future prefix
                // extensions remain exact.
                var subsequence_end = entry.len;
                var packed6: u16 = 0;
                if (stage_len == top_k) {
                    var upper: i32 = undefined;
                    if (q.bytes.len == 6) {
                        packed6 = @intCast(packedBoundIndex(6, self.bonus_caps[entry_index], q.classes));
                        upper = 6 * score_match + @as(i32, bound_bonus6[packed6]);
                    } else {
                        upper = self.scoreUpperBound(&q, self.bonus_caps[entry_index]);
                    }
                    if (q.bytes.len >= 4) {
                        var final_last: u8 = 0xff;
                        upper = self.endpointSpanUpperBoundWithLast(&q, entry, entry_index, first_slot, last_slot, self.bonus_caps[entry_index], upper, &final_last);
                        if (final_last != 0xff) subsequence_end = @as(usize, final_last) + 1;
                    }
                    const worst = self.stage[0];
                    const worst_entry = self.entries[worst.entry];
                    if (upper < worst.score or
                        (upper == worst.score and
                            (entry.len > worst_entry.len or
                                (entry.len == worst_entry.len and entry_index > worst.entry))))
                    {
                        self.next_survivors[word] |= row_bit;
                        continue;
                    }
                }

                if (q.bytes.len == 1) {
                    const score = self.scoreV2Single(&q, entry) orelse continue;
                    self.next_survivors[word] |= row_bit;
                    self.addStage(.{ .entry = entry_index, .score = score }, top_k, &stage_len);
                    continue;
                }
                if (q.bytes.len == 2) {
                    const score = self.scoreV2TwoIndexedOrdered(&q, entry, entry_index, first_slot) orelse continue;
                    self.next_survivors[word] |= row_bit;
                    self.addStage(.{ .entry = entry_index, .score = score }, top_k, &stage_len);
                    continue;
                }

                // Longer queries still use the exact subsequence pass to
                // populate the first-feasible position of every query byte.
                if (!self.subsequenceIndexed(&q, entry, entry_index, first_slot, subsequence_end)) continue;
                self.next_survivors[word] |= row_bit;

                var score: i32 = undefined;
                if (q.bytes.len == 6 and stage_len == top_k) {
                    self.prepareLastPositions(&q, entry, entry_index);
                    const tightened = self.gapAwareUpperPrepared6(&q, packed6);
                    if (tightened < self.stage[0].score) continue;
                    score = self.scoreV2SixPreparedFromFirst(&q, entry);
                } else if (q.bytes.len >= 7 and q.bytes.len <= 1000 and stage_len == top_k) {
                    self.prepareLastPositions(&q, entry, entry_index);
                    const tightened = self.gapAwareUpperPrepared(&q, self.bonus_caps[entry_index]);
                    if (tightened < self.stage[0].score) continue;
                    score = if (q.bytes.len <= 8 and entry.len <= 64)
                        self.scoreV2Sparse64Prepared(&q, entry)
                    else
                        self.scoreV2GeneralFromFirst(&q, entry, null, true);
                } else {
                    score = self.scoreV2IndexedFromFirst(&q, entry, entry_index);
                }

                self.addStage(.{
                    .entry = entry_index,
                    .score = score,
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
        if (m == 1) {
            const match_index = std.mem.findScalar(u8, text, q.bytes[0]) orelse return null;
            return score_match + @as(i32, @intCast(bonus[match_index])) * bonus_first_char_multiplier;
        }

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

    fn subsequenceIndexed(self: *Index, q: *const Query, entry: Entry, entry_index: usize, first_slot: u8, text_end: usize) bool {
        const text = self.candidateLower(entry);
        if (q.bytes.len == 0) return true;
        if (q.bytes.len > text.len) return false;
        var pattern_index: usize = 0;
        var text_start: usize = 0;
        if (self.indexedFirstPositionForSlot(entry, entry_index, first_slot)) |position| {
            self.position_scratch[0] = position;
            pattern_index = 1;
            if (pattern_index == q.bytes.len) return true;
            text_start = position + 1;
        }
        if (text_start >= text_end) return false;
        for (text[text_start..text_end], text_start..) |c, i| {
            if (c != q.bytes[pattern_index]) continue;
            self.position_scratch[pattern_index] = i;
            pattern_index += 1;
            if (pattern_index == q.bytes.len) return true;
        }
        return false;
    }

    /// Tighten an existing score ceiling using only endpoint occurrence metadata.
    ///
    /// Any ordered alignment must start no later than the candidate's last
    /// occurrence of q[0] and end no earlier than its first occurrence of
    /// q[m-1]. If those endpoints force more span than m matched bytes can
    /// occupy, every alignment contains at least that many gap bytes. Charging
    /// them as one gap run is the least-negative possible fzf gap penalty, so
    /// subtracting it from an already-safe ceiling remains an upper bound.
    fn endpointSpanUpperBound(
        self: *const Index,
        q: *const Query,
        entry: Entry,
        entry_index: usize,
        first_slot: u8,
        last_slot: u8,
        caps: BonusCaps,
        upper: i32,
    ) i32 {
        var ignored_last: u8 = 0xff;
        return self.endpointSpanUpperBoundWithLast(q, entry, entry_index, first_slot, last_slot, caps, upper, &ignored_last);
    }

    fn endpointSpanUpperBoundWithLast(
        self: *const Index,
        q: *const Query,
        entry: Entry,
        entry_index: usize,
        first_slot: u8,
        last_slot: u8,
        caps: BonusCaps,
        upper: i32,
        final_last: *u8,
    ) i32 {
        if (entry.len >= 256 or first_slot == 0xff or last_slot == 0xff) return upper;

        const first_meta = self.last_positions[@as(usize, first_slot) * self.entries.len + entry_index];
        const last_meta = self.last_positions[@as(usize, last_slot) * self.entries.len + entry_index];
        final_last.* = last_meta.last;
        if (first_meta.last == 0xff or last_meta.first == 0xff) return upper;
        if (last_meta.first <= first_meta.last) return upper;

        const forced_span = @as(usize, last_meta.first) - @as(usize, first_meta.last) + 1;
        if (forced_span <= q.bytes.len) return upper;
        const forced_gap = forced_span - q.bytes.len;
        const gap_cost = -score_gap_start + @as(i32, @intCast(forced_gap - 1)) * -score_gap_extension;
        const first_upper = score_match + bonusCap(caps, q.classes[0]) * bonus_first_char_multiplier;
        return upper - @min(gap_cost, first_upper);
    }

    fn packedBoundIndexWord(comptime m: usize, caps_word: u64, classes: []const u6, comptime word: usize) usize {
        var index: usize = 0;
        inline for (0..m) |i| {
            const class_index: usize = @intCast(classes[i]);
            const local_class = class_index - word * 32;
            const shift: u6 = @intCast(local_class * 2);
            const category: u2 = @truncate(caps_word >> shift);
            index |= @as(usize, category) << @intCast(2 * i);
        }
        return index;
    }

    noinline fn scoreUpperBound78(q: *const Query, caps: BonusCaps) i32 {
        const m = q.bytes.len;
        const packed_index = if (q.cap_word_mask == 1)
            (if (m == 7) packedBoundIndexWord(7, caps[0], q.classes, 0) else packedBoundIndexWord(8, caps[0], q.classes, 0))
        else if (q.cap_word_mask == 2)
            (if (m == 7) packedBoundIndexWord(7, caps[1], q.classes, 1) else packedBoundIndexWord(8, caps[1], q.classes, 1))
        else if (m == 7)
            packedBoundIndex(7, caps, q.classes)
        else
            packedBoundIndex(8, caps, q.classes);
        const low = packed_index & 0xff;
        const first_sum = bound_first4_sum[low];
        const incoming: usize = bound_first4_out[low];
        const tail_sum = if (m == 7)
            bound_next3_sum[incoming][(packed_index >> 8) & 0x3f]
        else
            bound_next4_sum[incoming][packed_index >> 8];
        return @as(i32, @intCast(m)) * score_match + @as(i32, first_sum) + @as(i32, tail_sum);
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

        switch (q.bytes.len) {
            3 => return 3 * score_match + @as(i32, bound_bonus3[packedBoundIndex(3, caps, q.classes)]),
            4 => return 4 * score_match + @as(i32, bound_bonus4[packedBoundIndex(4, caps, q.classes)]),
            5 => return 5 * score_match + @as(i32, bound_bonus5[packedBoundIndex(5, caps, q.classes)]),
            6 => return 6 * score_match + @as(i32, bound_bonus6[packedBoundIndex(6, caps, q.classes)]),
            7, 8 => return scoreUpperBound78(q, caps),
            else => {},
        }
        return scoreUpperBoundGeneric(q, caps);
    }

    fn scoreV2Single(self: *const Index, q: *const Query, entry: Entry) ?i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const pattern_char = q.bytes[0];
        var found = false;
        var max_score: i32 = 0;

        // Match fzf V2's forward single-byte fast path exactly: once we hit a
        // word-boundary-class bonus, the forward result is settled and later
        // occurrences are deliberately ignored.
        for (text, bonus) |c, b| {
            if (c != pattern_char) continue;
            found = true;
            const raw_bonus: i32 = @intCast(b);
            const score = score_match + raw_bonus * bonus_first_char_multiplier;
            max_score = @max(max_score, score);
            if (raw_bonus >= bonus_boundary) return score;
        }
        return if (found) max_score else null;
    }

    /// Fused score-only fzf V2 path for two-byte queries. This is the same two
    /// DP rows as the general algorithm, but both rows are carried as scalar
    /// running state in one pass instead of materializing/reading four arrays.
    fn scoreV2TwoFromFirst(self: *const Index, q: *const Query, entry: Entry) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const last_col = std.mem.findScalarLast(u8, text, q.bytes[1]).?;

        return self.scoreV2TwoWindow(q, text, bonus, first0, first1, last_col);
    }

    fn scoreV2TwoIndexedOrdered(self: *Index, q: *const Query, entry: Entry, entry_index: usize, first_slot: u8) ?i32 {
        const first0 = self.indexedFirstPositionForSlot(entry, entry_index, first_slot) orelse {
            if (!self.subsequenceIndexed(q, entry, entry_index, first_slot, entry.len)) return null;
            return self.scoreV2TwoIndexed(q, entry, entry_index);
        };
        self.position_scratch[0] = first0;

        const class: usize = @intCast(q.classes[1]);
        if (entry.len < 256 and class < exact_signature_classes) {
            const slot = self.last_slot_for_class[class];
            if (slot != 0xff) {
                const meta = self.last_positions[@as(usize, slot) * self.entries.len + entry_index];
                if (meta.last == 0xff or @as(usize, meta.last) <= first0) return null;
                const last_col: usize = meta.last;
                var first1: usize = undefined;
                if (@as(usize, meta.first) > first0) {
                    first1 = meta.first;
                } else {
                    const text = self.candidateLower(entry);
                    var j = first0 + 1;
                    while (text[j] != q.bytes[1]) : (j += 1) {}
                    first1 = j;
                }
                self.position_scratch[1] = first1;
                return self.scoreV2TwoWindow(q, self.candidateLower(entry), self.candidateBonuses(entry), first0, first1, last_col);
            }
        }

        if (!self.subsequenceIndexed(q, entry, entry_index, first_slot, entry.len)) return null;
        return self.scoreV2TwoIndexed(q, entry, entry_index);
    }

    fn scoreV2TwoIndexed(self: *const Index, q: *const Query, entry: Entry, entry_index: usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const last_col = blk: {
            const class: usize = @intCast(signatureClass(q.bytes[1]));
            if (class < exact_signature_classes and entry.len < 256) {
                const slot = self.last_slot_for_class[class];
                if (slot != 0xff) {
                    const stored = self.last_positions[@as(usize, slot) * self.entries.len + entry_index].last;
                    if (stored != 0xff) break :blk @as(usize, stored);
                }
            }
            break :blk std.mem.findScalarLast(u8, text, q.bytes[1]).?;
        };

        return self.scoreV2TwoWindow(q, text, bonus, first0, first1, last_col);
    }

    inline fn scoreV2TwoWindow(
        self: *const Index,
        q: *const Query,
        text: []const u8,
        bonus: []const u8,
        first0: usize,
        first1: usize,
        last_col: usize,
    ) i32 {
        _ = self;
        const p0 = q.bytes[0];
        const p1 = q.bytes[1];
        const match_score: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const first_multiplier: i16 = bonus_first_char_multiplier;

        var h0_prev: i16 = 0;
        var c0_prev: i16 = 0;
        var b_prev: i16 = 0;
        var in_gap0 = false;

        // Before first1, only row zero can contribute. Keep this separate so
        // the main two-row loop has no first-column gating branch.
        var j = first0;
        while (j < first1) : (j += 1) {
            const c = text[j];
            var h0_cur: i16 = undefined;
            var c0_cur: i16 = 0;
            if (c == p0) {
                const raw_bonus: i16 = @intCast(bonus[j]);
                h0_cur = match_score + raw_bonus * first_multiplier;
                c0_cur = 1;
                b_prev = raw_bonus;
                in_gap0 = false;
            } else {
                h0_cur = @max(h0_prev + (if (in_gap0) gap_extension else gap_start), 0);
                in_gap0 = true;
            }
            h0_prev = h0_cur;
            c0_prev = c0_cur;
        }

        // first1 is known to match p1 from the ordered-subsequence pass. Seed
        // the final row once, then run the branch-free steady-state window.
        {
            const c = text[first1];
            const raw_bonus: i16 = @intCast(bonus[first1]);
            var h0_cur: i16 = undefined;
            var c0_cur: i16 = 0;
            if (c == p0) {
                h0_cur = match_score + raw_bonus * first_multiplier;
                c0_cur = 1;
                b_prev = raw_bonus;
                in_gap0 = false;
            } else {
                h0_cur = @max(h0_prev + (if (in_gap0) gap_extension else gap_start), 0);
                in_gap0 = true;
            }

            var b = raw_bonus;
            const consecutive = c0_prev + 1;
            if (consecutive > 1 and !(b >= boundary and b > b_prev)) {
                b = @max(b, @max(consecutive_bonus, b_prev));
            }
            var h1_prev = h0_prev + match_score + b;
            var in_gap1 = false;
            var max_score = h1_prev;

            h0_prev = h0_cur;
            c0_prev = c0_cur;

            j = first1 + 1;
            while (j <= last_col) : (j += 1) {
                const ch = text[j];

                h0_cur = undefined;
                c0_cur = 0;
                if (ch == p0) {
                    const raw0: i16 = @intCast(bonus[j]);
                    h0_cur = match_score + raw0 * first_multiplier;
                    c0_cur = 1;
                    b_prev = raw0;
                    in_gap0 = false;
                } else {
                    h0_cur = @max(h0_prev + (if (in_gap0) gap_extension else gap_start), 0);
                    in_gap0 = true;
                }

                const gap_score: i16 = h1_prev + (if (in_gap1) gap_extension else gap_start);
                var match_value: i16 = 0;
                if (ch == p1) {
                    const raw1: i16 = @intCast(bonus[j]);
                    match_value = h0_prev + match_score;
                    var match_bonus = raw1;
                    const run = c0_prev + 1;
                    if (run > 1 and !(match_bonus >= boundary and match_bonus > b_prev)) {
                        match_bonus = @max(match_bonus, @max(consecutive_bonus, b_prev));
                    }
                    if (match_value + match_bonus < gap_score) {
                        match_value += raw1;
                    } else {
                        match_value += match_bonus;
                    }
                }

                in_gap1 = match_value < gap_score;
                h1_prev = @max(@max(match_value, gap_score), 0);
                max_score = @max(max_score, h1_prev);
                h0_prev = h0_cur;
                c0_prev = c0_cur;
            }
            return @intCast(max_score);
        }
    }

    fn scoreV2ThreeFromFirst(self: *Index, q: *const Query, entry: Entry, last_hint: ?usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const first2 = self.position_scratch[2];

        var reverse_pattern: usize = 3;
        var reverse_col = text.len;
        var last2: usize = undefined;
        if (last_hint) |position| {
            last2 = position;
            reverse_pattern = 2;
            reverse_col = position;
        }
        var last1: usize = undefined;
        while (reverse_pattern != 1) {
            reverse_col -= 1;
            if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
            reverse_pattern -= 1;
            if (reverse_pattern == 2) last2 = reverse_col else last1 = reverse_col;
        }

        const p0 = q.bytes[0];
        const p1 = q.bytes[1];
        const p2 = q.bytes[2];
        const match_score: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const first_multiplier: i16 = bonus_first_char_multiplier;

        var h0: i16 = 0;
        var c0: i16 = 0;
        var gap0 = false;
        var j = first0;

        // Row zero is the only live row before first1.
        while (j < first1) : (j += 1) {
            const ch = text[j];
            if (ch == p0) {
                h0 = match_score + @as(i16, @intCast(bonus[j])) * first_multiplier;
                c0 = 1;
                gap0 = false;
            } else {
                h0 = @max(h0 + (if (gap0) gap_extension else gap_start), 0);
                c0 = 0;
                gap0 = true;
            }
        }

        // first1 is guaranteed by the forward subsequence pass. Seed row one
        // from the previous row-zero column, then advance row zero at first1.
        const raw1_seed: i16 = @intCast(bonus[first1]);
        var b1_seed = raw1_seed;
        var c1 = c0 + 1;
        if (c1 > 1) {
            const run_start = first1 + 1 - @as(usize, @intCast(c1));
            const first_bonus: i16 = @intCast(bonus[run_start]);
            if (b1_seed >= boundary and b1_seed > first_bonus) {
                c1 = 1;
            } else {
                b1_seed = @max(b1_seed, @max(consecutive_bonus, first_bonus));
            }
        }
        var h1 = h0 + match_score + b1_seed;
        var gap1 = false;

        if (first1 < last1) {
            const ch = text[first1];
            if (ch == p0) {
                h0 = match_score + raw1_seed * first_multiplier;
                c0 = 1;
                gap0 = false;
            } else {
                h0 = @max(h0 + (if (gap0) gap_extension else gap_start), 0);
                c0 = 0;
                gap0 = true;
            }
        }

        j = first1 + 1;
        const both_end = @min(first2, last1);
        while (j < both_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);

            const gap_score1 = h1 + (if (gap1) gap_extension else gap_start);
            var match1: i16 = -16_000;
            var next_c1: i16 = 0;
            if (ch == p1) {
                match1 = h0 + match_score;
                var b = raw;
                next_c1 = c0 + 1;
                if (next_c1 > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(next_c1));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (b >= boundary and b > first_bonus) next_c1 = 1 else b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match1 + b < gap_score1) {
                    match1 += raw;
                    next_c1 = 0;
                } else match1 += b;
            }
            gap1 = match1 < gap_score1;
            h1 = @max(@max(match1, gap_score1), 0);
            c1 = next_c1;

            if (ch == p0) {
                h0 = match_score + raw * first_multiplier;
                c0 = 1;
                gap0 = false;
            } else {
                h0 = @max(h0 + (if (gap0) gap_extension else gap_start), 0);
                c0 = 0;
                gap0 = true;
            }
        }

        // If row zero's latest useful column precedes first2, finish row one
        // alone up to the first feasible row-two match.
        while (j < first2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            const gap_score1 = h1 + (if (gap1) gap_extension else gap_start);
            var match1: i16 = -16_000;
            var next_c1: i16 = 0;
            if (ch == p1) {
                match1 = h0 + match_score;
                var b = raw;
                next_c1 = c0 + 1;
                if (next_c1 > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(next_c1));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (b >= boundary and b > first_bonus) next_c1 = 1 else b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match1 + b < gap_score1) {
                    match1 += raw;
                    next_c1 = 0;
                } else match1 += b;
            }
            gap1 = match1 < gap_score1;
            h1 = @max(@max(match1, gap_score1), 0);
            c1 = next_c1;
        }

        // Seed the final row at its first feasible match before advancing lower
        // rows at the same text column; V2 rows consume the previous column.
        const raw2_seed: i16 = @intCast(bonus[first2]);
        var b2_seed = raw2_seed;
        var c2 = c1 + 1;
        if (c2 > 1) {
            const run_start = first2 + 1 - @as(usize, @intCast(c2));
            const first_bonus: i16 = @intCast(bonus[run_start]);
            if (b2_seed >= boundary and b2_seed > first_bonus) {
                c2 = 1;
            } else {
                b2_seed = @max(b2_seed, @max(consecutive_bonus, first_bonus));
            }
        }
        var h2 = h1 + match_score + b2_seed;
        var gap2 = false;
        var max_score = h2;
        if (first2 == last2) return @intCast(max_score);

        // Advance row one at first2. It remains live through last2 - 1.
        {
            const ch = text[first2];
            const raw = raw2_seed;
            const gap_score1 = h1 + (if (gap1) gap_extension else gap_start);
            var match1: i16 = -16_000;
            var next_c1: i16 = 0;
            if (ch == p1) {
                match1 = h0 + match_score;
                var b = raw;
                next_c1 = c0 + 1;
                if (next_c1 > 1) {
                    const run_start = first2 + 1 - @as(usize, @intCast(next_c1));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (b >= boundary and b > first_bonus) next_c1 = 1 else b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match1 + b < gap_score1) {
                    match1 += raw;
                    next_c1 = 0;
                } else match1 += b;
            }
            gap1 = match1 < gap_score1;
            h1 = @max(@max(match1, gap_score1), 0);
            c1 = next_c1;

            if (first2 < last1) {
                if (ch == p0) {
                    h0 = match_score + raw * first_multiplier;
                    c0 = 1;
                    gap0 = false;
                } else {
                    h0 = @max(h0 + (if (gap0) gap_extension else gap_start), 0);
                    c0 = 0;
                    gap0 = true;
                }
            }
        }

        j = first2 + 1;
        while (j < last1) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);

            const gap_score2 = h2 + (if (gap2) gap_extension else gap_start);
            var match2: i16 = -16_000;
            if (ch == p2) {
                match2 = h1 + match_score;
                var b = raw;
                const run = c1 + 1;
                if (run > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(run));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (!(b >= boundary and b > first_bonus)) b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match2 + b < gap_score2) match2 += raw else match2 += b;
            }
            gap2 = match2 < gap_score2;
            h2 = @max(@max(match2, gap_score2), 0);
            max_score = @max(max_score, h2);

            const gap_score1 = h1 + (if (gap1) gap_extension else gap_start);
            var match1: i16 = -16_000;
            var next_c1: i16 = 0;
            if (ch == p1) {
                match1 = h0 + match_score;
                var b = raw;
                next_c1 = c0 + 1;
                if (next_c1 > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(next_c1));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (b >= boundary and b > first_bonus) next_c1 = 1 else b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match1 + b < gap_score1) {
                    match1 += raw;
                    next_c1 = 0;
                } else match1 += b;
            }
            gap1 = match1 < gap_score1;
            h1 = @max(@max(match1, gap_score1), 0);
            c1 = next_c1;

            if (ch == p0) {
                h0 = match_score + raw * first_multiplier;
                c0 = 1;
                gap0 = false;
            } else {
                h0 = @max(h0 + (if (gap0) gap_extension else gap_start), 0);
                c0 = 0;
                gap0 = true;
            }
        }

        while (j < last2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);

            const gap_score2 = h2 + (if (gap2) gap_extension else gap_start);
            var match2: i16 = -16_000;
            if (ch == p2) {
                match2 = h1 + match_score;
                var b = raw;
                const run = c1 + 1;
                if (run > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(run));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (!(b >= boundary and b > first_bonus)) b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match2 + b < gap_score2) match2 += raw else match2 += b;
            }
            gap2 = match2 < gap_score2;
            h2 = @max(@max(match2, gap_score2), 0);
            max_score = @max(max_score, h2);

            const gap_score1 = h1 + (if (gap1) gap_extension else gap_start);
            var match1: i16 = -16_000;
            var next_c1: i16 = 0;
            if (ch == p1) {
                match1 = h0 + match_score;
                var b = raw;
                next_c1 = c0 + 1;
                if (next_c1 > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(next_c1));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (b >= boundary and b > first_bonus) next_c1 = 1 else b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match1 + b < gap_score1) {
                    match1 += raw;
                    next_c1 = 0;
                } else match1 += b;
            }
            gap1 = match1 < gap_score1;
            h1 = @max(@max(match1, gap_score1), 0);
            c1 = next_c1;
        }

        // last2 is final-row-only: lower rows cannot feed a later column.
        {
            const ch = text[last2];
            const raw: i16 = @intCast(bonus[last2]);
            const gap_score2 = h2 + (if (gap2) gap_extension else gap_start);
            var match2: i16 = -16_000;
            if (ch == p2) {
                match2 = h1 + match_score;
                var b = raw;
                const run = c1 + 1;
                if (run > 1) {
                    const run_start = last2 + 1 - @as(usize, @intCast(run));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (!(b >= boundary and b > first_bonus)) b = @max(b, @max(consecutive_bonus, first_bonus));
                }
                if (match2 + b < gap_score2) match2 += raw else match2 += b;
            }
            h2 = @max(@max(match2, gap_score2), 0);
            max_score = @max(max_score, h2);
        }
        return @intCast(max_score);
    }

    inline fn advanceV2FirstState(
        ch: u8,
        pattern: u8,
        raw_bonus: i16,
        h: *i16,
        consecutive: *i16,
        in_gap: *bool,
    ) void {
        const match_score: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const first_multiplier: i16 = bonus_first_char_multiplier;
        if (ch == pattern) {
            h.* = match_score + raw_bonus * first_multiplier;
            consecutive.* = 1;
            in_gap.* = false;
        } else {
            h.* = @max(h.* + (if (in_gap.*) gap_extension else gap_start), 0);
            consecutive.* = 0;
            in_gap.* = true;
        }
    }

    inline fn advanceV2RowState(
        ch: u8,
        pattern: u8,
        raw_bonus: i16,
        bonus: []const u8,
        column: usize,
        lower_h: i16,
        lower_consecutive: i16,
        h: *i16,
        consecutive: *i16,
        in_gap: *bool,
    ) void {
        const match_score: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const gap_score: i16 = h.* + (if (in_gap.*) gap_extension else gap_start);
        var match_value: i16 = -16_000;
        var run: i16 = 0;
        if (ch == pattern) {
            match_value = lower_h + match_score;
            var b = raw_bonus;
            run = lower_consecutive + 1;
            if (run > 1) {
                const run_start = column + 1 - @as(usize, @intCast(run));
                const first_bonus: i16 = @intCast(bonus[run_start]);
                if (b >= boundary and b > first_bonus) {
                    run = 1;
                } else {
                    b = @max(b, @max(consecutive_bonus, first_bonus));
                }
            }
            if (match_value + b < gap_score) {
                match_value += raw_bonus;
                run = 0;
            } else {
                match_value += b;
            }
        }

        consecutive.* = run;
        in_gap.* = match_value < gap_score;
        h.* = @max(@max(match_value, gap_score), 0);
    }

    fn scoreV2FourFromFirst(self: *Index, q: *const Query, entry: Entry, last_hint: ?usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const first2 = self.position_scratch[2];
        const first3 = self.position_scratch[3];

        var last: [4]usize = undefined;
        var reverse_pattern: usize = 4;
        var reverse_col = text.len;
        if (last_hint) |position| {
            last[3] = position;
            reverse_pattern = 3;
            reverse_col = position;
        }
        while (reverse_pattern != 1) {
            reverse_col -= 1;
            if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
            reverse_pattern -= 1;
            last[reverse_pattern] = reverse_col;
        }
        const last1 = last[1];
        const last2 = last[2];
        const last3 = last[3];

        const p0 = q.bytes[0];
        const p1 = q.bytes[1];
        const p2 = q.bytes[2];
        const p3 = q.bytes[3];

        var h0: i16 = 0;
        var h1: i16 = 0;
        var h2: i16 = 0;
        var h3: i16 = 0;
        var c0: i16 = 0;
        var c1: i16 = 0;
        var c2: i16 = 0;
        var c3: i16 = 0;
        var gap0 = false;
        var gap1 = false;
        var gap2 = false;
        var gap3 = false;

        var j = first0;
        while (j < first1) : (j += 1) {
            const raw: i16 = @intCast(bonus[j]);
            advanceV2FirstState(text[j], p0, raw, &h0, &c0, &gap0);
        }

        // Seed row one before advancing row zero at the same column.
        {
            const raw: i16 = @intCast(bonus[first1]);
            advanceV2RowState(text[first1], p1, raw, bonus, first1, h0, c0, &h1, &c1, &gap1);
            if (first1 < last1) advanceV2FirstState(text[first1], p0, raw, &h0, &c0, &gap0);
        }

        j = first1 + 1;
        const row01_end = @min(first2, last1);
        while (j < row01_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < first2) : (j += 1) {
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(text[j], p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }

        // Seed row two from the previous row-one column.
        {
            const ch = text[first2];
            const raw: i16 = @intCast(bonus[first2]);
            advanceV2RowState(ch, p2, raw, bonus, first2, h1, c1, &h2, &c2, &gap2);
            if (first2 < last2) advanceV2RowState(ch, p1, raw, bonus, first2, h0, c0, &h1, &c1, &gap1);
            if (first2 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first2 + 1;
        const row012_end = @min(first3, last1);
        while (j < row012_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const row12_end = @min(first3, last2);
        while (j < row12_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < first3) : (j += 1) {
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(text[j], p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }

        // Seed the final row. If its first feasible match is also its last,
        // no lower row can influence another final-row column.
        {
            const ch = text[first3];
            const raw: i16 = @intCast(bonus[first3]);
            advanceV2RowState(ch, p3, raw, bonus, first3, h2, c2, &h3, &c3, &gap3);
            if (first3 == last3) return @intCast(h3);
            advanceV2RowState(ch, p2, raw, bonus, first3, h1, c1, &h2, &c2, &gap2);
            if (first3 < last2) advanceV2RowState(ch, p1, raw, bonus, first3, h0, c0, &h1, &c1, &gap1);
            if (first3 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        var max_score = h3;
        j = first3 + 1;
        while (j < last1) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            max_score = @max(max_score, h3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < last2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            max_score = @max(max_score, h3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < last3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            max_score = @max(max_score, h3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        {
            const raw: i16 = @intCast(bonus[last3]);
            advanceV2RowState(text[last3], p3, raw, bonus, last3, h2, c2, &h3, &c3, &gap3);
            max_score = @max(max_score, h3);
        }
        return @intCast(max_score);
    }

    fn scoreV2FiveFromFirst(self: *Index, q: *const Query, entry: Entry, last_hint: ?usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const first2 = self.position_scratch[2];
        const first3 = self.position_scratch[3];
        const first4 = self.position_scratch[4];

        var last: [5]usize = undefined;
        var reverse_pattern: usize = 5;
        var reverse_col = text.len;
        if (last_hint) |position| {
            last[4] = position;
            reverse_pattern = 4;
            reverse_col = position;
        }
        while (reverse_pattern != 1) {
            reverse_col -= 1;
            if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
            reverse_pattern -= 1;
            last[reverse_pattern] = reverse_col;
        }
        const last1 = last[1];
        const last2 = last[2];
        const last3 = last[3];
        const last4 = last[4];

        const p0 = q.bytes[0];
        const p1 = q.bytes[1];
        const p2 = q.bytes[2];
        const p3 = q.bytes[3];
        const p4 = q.bytes[4];

        var h0: i16 = 0;
        var h1: i16 = 0;
        var h2: i16 = 0;
        var h3: i16 = 0;
        var h4: i16 = 0;
        var c0: i16 = 0;
        var c1: i16 = 0;
        var c2: i16 = 0;
        var c3: i16 = 0;
        var c4: i16 = 0;
        var gap0 = false;
        var gap1 = false;
        var gap2 = false;
        var gap3 = false;
        var gap4 = false;

        var j = first0;
        while (j < first1) : (j += 1) {
            const raw: i16 = @intCast(bonus[j]);
            advanceV2FirstState(text[j], p0, raw, &h0, &c0, &gap0);
        }

        // Activate row 1 before lower rows at the same text column.
        {
            const ch = text[first1];
            const raw: i16 = @intCast(bonus[first1]);
            advanceV2RowState(ch, p1, raw, bonus, first1, h0, c0, &h1, &c1, &gap1);
            if (first1 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first1 + 1;
        const phase1_0_end = @min(first2, last1);
        while (j < phase1_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < first2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }

        // Activate row 2 before lower rows at the same text column.
        {
            const ch = text[first2];
            const raw: i16 = @intCast(bonus[first2]);
            advanceV2RowState(ch, p2, raw, bonus, first2, h1, c1, &h2, &c2, &gap2);
            if (first2 < last2) advanceV2RowState(ch, p1, raw, bonus, first2, h0, c0, &h1, &c1, &gap1);
            if (first2 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first2 + 1;
        const phase2_0_end = @min(first3, last1);
        while (j < phase2_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase2_1_end = @min(first3, last2);
        while (j < phase2_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < first3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }

        // Activate row 3 before lower rows at the same text column.
        {
            const ch = text[first3];
            const raw: i16 = @intCast(bonus[first3]);
            advanceV2RowState(ch, p3, raw, bonus, first3, h2, c2, &h3, &c3, &gap3);
            if (first3 < last3) advanceV2RowState(ch, p2, raw, bonus, first3, h1, c1, &h2, &c2, &gap2);
            if (first3 < last2) advanceV2RowState(ch, p1, raw, bonus, first3, h0, c0, &h1, &c1, &gap1);
            if (first3 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first3 + 1;
        const phase3_0_end = @min(first4, last1);
        while (j < phase3_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase3_1_end = @min(first4, last2);
        while (j < phase3_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        const phase3_2_end = @min(first4, last3);
        while (j < phase3_2_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        while (j < first4) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }

        // Activate row 4 before lower rows at the same text column.
        {
            const ch = text[first4];
            const raw: i16 = @intCast(bonus[first4]);
            advanceV2RowState(ch, p4, raw, bonus, first4, h3, c3, &h4, &c4, &gap4);
            if (first4 == last4) return @intCast(h4);
            if (first4 < last4) advanceV2RowState(ch, p3, raw, bonus, first4, h2, c2, &h3, &c3, &gap3);
            if (first4 < last3) advanceV2RowState(ch, p2, raw, bonus, first4, h1, c1, &h2, &c2, &gap2);
            if (first4 < last2) advanceV2RowState(ch, p1, raw, bonus, first4, h0, c0, &h1, &c1, &gap1);
            if (first4 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        var max_score = h4;
        j = first4 + 1;
        while (j < last1) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            max_score = @max(max_score, h4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < last2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            max_score = @max(max_score, h4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < last3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            max_score = @max(max_score, h4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        while (j < last4) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            max_score = @max(max_score, h4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }
        {
            const j_final = last4;
            const ch = text[j_final];
            const raw: i16 = @intCast(bonus[j_final]);
            advanceV2RowState(ch, p4, raw, bonus, j_final, h3, c3, &h4, &c4, &gap4);
            max_score = @max(max_score, h4);
        }
        return @intCast(max_score);
    }

    fn scoreV2SixFromFirst(self: *Index, q: *const Query, entry: Entry, last_hint: ?usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const first2 = self.position_scratch[2];
        const first3 = self.position_scratch[3];
        const first4 = self.position_scratch[4];
        const first5 = self.position_scratch[5];

        var last: [6]usize = undefined;
        var reverse_pattern: usize = 6;
        var reverse_col = text.len;
        if (last_hint) |position| {
            last[5] = position;
            reverse_pattern = 5;
            reverse_col = position;
        }
        while (reverse_pattern != 1) {
            reverse_col -= 1;
            if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
            reverse_pattern -= 1;
            last[reverse_pattern] = reverse_col;
        }
        const last1 = last[1];
        const last2 = last[2];
        const last3 = last[3];
        const last4 = last[4];
        const last5 = last[5];

        const p0 = q.bytes[0];
        const p1 = q.bytes[1];
        const p2 = q.bytes[2];
        const p3 = q.bytes[3];
        const p4 = q.bytes[4];
        const p5 = q.bytes[5];

        var h0: i16 = 0;
        var h1: i16 = 0;
        var h2: i16 = 0;
        var h3: i16 = 0;
        var h4: i16 = 0;
        var h5: i16 = 0;
        var c0: i16 = 0;
        var c1: i16 = 0;
        var c2: i16 = 0;
        var c3: i16 = 0;
        var c4: i16 = 0;
        var c5: i16 = 0;
        var gap0 = false;
        var gap1 = false;
        var gap2 = false;
        var gap3 = false;
        var gap4 = false;
        var gap5 = false;

        var j = first0;
        while (j < first1) : (j += 1) {
            const raw: i16 = @intCast(bonus[j]);
            advanceV2FirstState(text[j], p0, raw, &h0, &c0, &gap0);
        }

        // Activate row 1 before lower rows at the same text column.
        {
            const ch = text[first1];
            const raw: i16 = @intCast(bonus[first1]);
            advanceV2RowState(ch, p1, raw, bonus, first1, h0, c0, &h1, &c1, &gap1);
            if (first1 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first1 + 1;
        const phase1_0_end = @min(first2, last1);
        while (j < phase1_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < first2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }

        // Activate row 2 before lower rows at the same text column.
        {
            const ch = text[first2];
            const raw: i16 = @intCast(bonus[first2]);
            advanceV2RowState(ch, p2, raw, bonus, first2, h1, c1, &h2, &c2, &gap2);
            if (first2 < last2) advanceV2RowState(ch, p1, raw, bonus, first2, h0, c0, &h1, &c1, &gap1);
            if (first2 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first2 + 1;
        const phase2_0_end = @min(first3, last1);
        while (j < phase2_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase2_1_end = @min(first3, last2);
        while (j < phase2_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < first3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }

        // Activate row 3 before lower rows at the same text column.
        {
            const ch = text[first3];
            const raw: i16 = @intCast(bonus[first3]);
            advanceV2RowState(ch, p3, raw, bonus, first3, h2, c2, &h3, &c3, &gap3);
            if (first3 < last3) advanceV2RowState(ch, p2, raw, bonus, first3, h1, c1, &h2, &c2, &gap2);
            if (first3 < last2) advanceV2RowState(ch, p1, raw, bonus, first3, h0, c0, &h1, &c1, &gap1);
            if (first3 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first3 + 1;
        const phase3_0_end = @min(first4, last1);
        while (j < phase3_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase3_1_end = @min(first4, last2);
        while (j < phase3_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        const phase3_2_end = @min(first4, last3);
        while (j < phase3_2_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        while (j < first4) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }

        // Activate row 4 before lower rows at the same text column.
        {
            const ch = text[first4];
            const raw: i16 = @intCast(bonus[first4]);
            advanceV2RowState(ch, p4, raw, bonus, first4, h3, c3, &h4, &c4, &gap4);
            if (first4 < last4) advanceV2RowState(ch, p3, raw, bonus, first4, h2, c2, &h3, &c3, &gap3);
            if (first4 < last3) advanceV2RowState(ch, p2, raw, bonus, first4, h1, c1, &h2, &c2, &gap2);
            if (first4 < last2) advanceV2RowState(ch, p1, raw, bonus, first4, h0, c0, &h1, &c1, &gap1);
            if (first4 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first4 + 1;
        const phase4_0_end = @min(first5, last1);
        while (j < phase4_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase4_1_end = @min(first5, last2);
        while (j < phase4_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        const phase4_2_end = @min(first5, last3);
        while (j < phase4_2_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        const phase4_3_end = @min(first5, last4);
        while (j < phase4_3_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }
        while (j < first5) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
        }

        // Activate row 5 before lower rows at the same text column.
        {
            const ch = text[first5];
            const raw: i16 = @intCast(bonus[first5]);
            advanceV2RowState(ch, p5, raw, bonus, first5, h4, c4, &h5, &c5, &gap5);
            if (first5 == last5) return @intCast(h5);
            if (first5 < last5) advanceV2RowState(ch, p4, raw, bonus, first5, h3, c3, &h4, &c4, &gap4);
            if (first5 < last4) advanceV2RowState(ch, p3, raw, bonus, first5, h2, c2, &h3, &c3, &gap3);
            if (first5 < last3) advanceV2RowState(ch, p2, raw, bonus, first5, h1, c1, &h2, &c2, &gap2);
            if (first5 < last2) advanceV2RowState(ch, p1, raw, bonus, first5, h0, c0, &h1, &c1, &gap1);
            if (first5 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        var max_score = h5;
        j = first5 + 1;
        while (j < last1) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < last2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < last3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        while (j < last4) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }
        while (j < last5) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
        }
        {
            const j_final = last5;
            const ch = text[j_final];
            const raw: i16 = @intCast(bonus[j_final]);
            advanceV2RowState(ch, p5, raw, bonus, j_final, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
        }
        return @intCast(max_score);
    }

    fn scoreV2SixPreparedFromFirst(self: *Index, q: *const Query, entry: Entry) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const first2 = self.position_scratch[2];
        const first3 = self.position_scratch[3];
        const first4 = self.position_scratch[4];
        const first5 = self.position_scratch[5];

        const last1 = self.last_position_scratch[1];
        const last2 = self.last_position_scratch[2];
        const last3 = self.last_position_scratch[3];
        const last4 = self.last_position_scratch[4];
        const last5 = self.last_position_scratch[5];

        const p0 = q.bytes[0];
        const p1 = q.bytes[1];
        const p2 = q.bytes[2];
        const p3 = q.bytes[3];
        const p4 = q.bytes[4];
        const p5 = q.bytes[5];

        var h0: i16 = 0;
        var h1: i16 = 0;
        var h2: i16 = 0;
        var h3: i16 = 0;
        var h4: i16 = 0;
        var h5: i16 = 0;
        var c0: i16 = 0;
        var c1: i16 = 0;
        var c2: i16 = 0;
        var c3: i16 = 0;
        var c4: i16 = 0;
        var c5: i16 = 0;
        var gap0 = false;
        var gap1 = false;
        var gap2 = false;
        var gap3 = false;
        var gap4 = false;
        var gap5 = false;

        var j = first0;
        while (j < first1) : (j += 1) {
            const raw: i16 = @intCast(bonus[j]);
            advanceV2FirstState(text[j], p0, raw, &h0, &c0, &gap0);
        }

        // Activate row 1 before lower rows at the same text column.
        {
            const ch = text[first1];
            const raw: i16 = @intCast(bonus[first1]);
            advanceV2RowState(ch, p1, raw, bonus, first1, h0, c0, &h1, &c1, &gap1);
            if (first1 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first1 + 1;
        const phase1_0_end = @min(first2, last1);
        while (j < phase1_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < first2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }

        // Activate row 2 before lower rows at the same text column.
        {
            const ch = text[first2];
            const raw: i16 = @intCast(bonus[first2]);
            advanceV2RowState(ch, p2, raw, bonus, first2, h1, c1, &h2, &c2, &gap2);
            if (first2 < last2) advanceV2RowState(ch, p1, raw, bonus, first2, h0, c0, &h1, &c1, &gap1);
            if (first2 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first2 + 1;
        const phase2_0_end = @min(first3, last1);
        while (j < phase2_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase2_1_end = @min(first3, last2);
        while (j < phase2_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < first3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }

        // Activate row 3 before lower rows at the same text column.
        {
            const ch = text[first3];
            const raw: i16 = @intCast(bonus[first3]);
            advanceV2RowState(ch, p3, raw, bonus, first3, h2, c2, &h3, &c3, &gap3);
            if (first3 < last3) advanceV2RowState(ch, p2, raw, bonus, first3, h1, c1, &h2, &c2, &gap2);
            if (first3 < last2) advanceV2RowState(ch, p1, raw, bonus, first3, h0, c0, &h1, &c1, &gap1);
            if (first3 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first3 + 1;
        const phase3_0_end = @min(first4, last1);
        while (j < phase3_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase3_1_end = @min(first4, last2);
        while (j < phase3_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        const phase3_2_end = @min(first4, last3);
        while (j < phase3_2_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        while (j < first4) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }

        // Activate row 4 before lower rows at the same text column.
        {
            const ch = text[first4];
            const raw: i16 = @intCast(bonus[first4]);
            advanceV2RowState(ch, p4, raw, bonus, first4, h3, c3, &h4, &c4, &gap4);
            if (first4 < last4) advanceV2RowState(ch, p3, raw, bonus, first4, h2, c2, &h3, &c3, &gap3);
            if (first4 < last3) advanceV2RowState(ch, p2, raw, bonus, first4, h1, c1, &h2, &c2, &gap2);
            if (first4 < last2) advanceV2RowState(ch, p1, raw, bonus, first4, h0, c0, &h1, &c1, &gap1);
            if (first4 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        j = first4 + 1;
        const phase4_0_end = @min(first5, last1);
        while (j < phase4_0_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        const phase4_1_end = @min(first5, last2);
        while (j < phase4_1_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        const phase4_2_end = @min(first5, last3);
        while (j < phase4_2_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        const phase4_3_end = @min(first5, last4);
        while (j < phase4_3_end) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }
        while (j < first5) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
        }

        // Activate row 5 before lower rows at the same text column.
        {
            const ch = text[first5];
            const raw: i16 = @intCast(bonus[first5]);
            advanceV2RowState(ch, p5, raw, bonus, first5, h4, c4, &h5, &c5, &gap5);
            if (first5 == last5) return @intCast(h5);
            if (first5 < last5) advanceV2RowState(ch, p4, raw, bonus, first5, h3, c3, &h4, &c4, &gap4);
            if (first5 < last4) advanceV2RowState(ch, p3, raw, bonus, first5, h2, c2, &h3, &c3, &gap3);
            if (first5 < last3) advanceV2RowState(ch, p2, raw, bonus, first5, h1, c1, &h2, &c2, &gap2);
            if (first5 < last2) advanceV2RowState(ch, p1, raw, bonus, first5, h0, c0, &h1, &c1, &gap1);
            if (first5 < last1) advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }

        var max_score = h5;
        j = first5 + 1;
        while (j < last1) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
            advanceV2FirstState(ch, p0, raw, &h0, &c0, &gap0);
        }
        while (j < last2) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
            advanceV2RowState(ch, p1, raw, bonus, j, h0, c0, &h1, &c1, &gap1);
        }
        while (j < last3) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
            advanceV2RowState(ch, p2, raw, bonus, j, h1, c1, &h2, &c2, &gap2);
        }
        while (j < last4) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
            advanceV2RowState(ch, p3, raw, bonus, j, h2, c2, &h3, &c3, &gap3);
        }
        while (j < last5) : (j += 1) {
            const ch = text[j];
            const raw: i16 = @intCast(bonus[j]);
            advanceV2RowState(ch, p5, raw, bonus, j, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
            advanceV2RowState(ch, p4, raw, bonus, j, h3, c3, &h4, &c4, &gap4);
        }
        {
            const j_final = last5;
            const ch = text[j_final];
            const raw: i16 = @intCast(bonus[j_final]);
            advanceV2RowState(ch, p5, raw, bonus, j_final, h4, c4, &h5, &c5, &gap5);
            max_score = @max(max_score, h5);
        }
        return @intCast(max_score);
    }

    /// Compile-time-unrolled score-only V2 kernel for the small-pattern cases
    /// where scalar row state is faster than candidate-sized DP buffers.
    fn scoreV2SmallFromFirst(self: *Index, comptime M: usize, q: *const Query, entry: Entry, last_hint: ?usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first = self.position_scratch[0..M];
        const last = self.last_position_scratch[0..M];

        var reverse_pattern: usize = M;
        var reverse_col = text.len;
        if (last_hint) |position| {
            last[M - 1] = position;
            reverse_pattern = M - 1;
            reverse_col = position;
        }
        // last[0] is never consumed by the small DP: row zero is bounded by
        // last[1]. Stop once that bound is known instead of scanning farther
        // backward just to materialize an unused position.
        while (reverse_pattern != 1) {
            reverse_col -= 1;
            if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
            reverse_pattern -= 1;
            last[reverse_pattern] = reverse_col;
        }

        var h = [_]i16{0} ** M;
        var consecutive = [_]i16{0} ** M;
        var in_gap = [_]bool{false} ** M;

        const match_score: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const first_multiplier: i16 = bonus_first_char_multiplier;

        var max_score: i16 = 0;
        var j = first[0];
        while (j <= last[M - 1]) : (j += 1) {
            const char = text[j];
            const raw_bonus: i16 = @intCast(bonus[j]);

            inline for (1..M) |reverse_index| {
                const i = M - reverse_index;
                const row_end = if (i + 1 < M) last[i + 1] - 1 else last[i];
                if (j >= first[i] and j <= row_end) {
                    const left: i16 = if (j > first[i]) h[i] else 0;
                    const gap_score: i16 = left + (if (in_gap[i]) gap_extension else gap_start);
                    var match_value: i16 = -16_000;
                    var run: i16 = 0;

                    if (char == q.bytes[i]) {
                        match_value = h[i - 1] + match_score;
                        var b = raw_bonus;
                        run = consecutive[i - 1] + 1;
                        if (run > 1) {
                            const run_start = j + 1 - @as(usize, @intCast(run));
                            const first_bonus: i16 = @intCast(bonus[run_start]);
                            if (b >= boundary and b > first_bonus) {
                                run = 1;
                            } else {
                                b = @max(b, @max(consecutive_bonus, first_bonus));
                            }
                        }
                        if (match_value + b < gap_score) {
                            match_value += raw_bonus;
                            run = 0;
                        } else {
                            match_value += b;
                        }
                    }

                    consecutive[i] = run;
                    in_gap[i] = match_value < gap_score;
                    h[i] = @max(@max(match_value, gap_score), 0);
                    if (i == M - 1) max_score = @max(max_score, h[i]);
                }
            }

            if (j < last[1]) {
                if (char == q.bytes[0]) {
                    h[0] = match_score + raw_bonus * first_multiplier;
                    consecutive[0] = 1;
                    in_gap[0] = false;
                } else {
                    h[0] = @max(h[0] + (if (in_gap[0]) gap_extension else gap_start), 0);
                    consecutive[0] = 0;
                    in_gap[0] = true;
                }
            }
        }

        return @intCast(max_score);
    }

    fn scoreV2SmallPreparedFromFirst(self: *Index, comptime M: usize, q: *const Query, entry: Entry) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first = self.position_scratch[0..M];
        const last = self.last_position_scratch[0..M];

        var h = [_]i16{0} ** M;
        var consecutive = [_]i16{0} ** M;
        var in_gap = [_]bool{false} ** M;

        const match_score: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const first_multiplier: i16 = bonus_first_char_multiplier;

        var max_score: i16 = 0;
        var j = first[0];
        while (j <= last[M - 1]) : (j += 1) {
            const char = text[j];
            const raw_bonus: i16 = @intCast(bonus[j]);

            inline for (1..M) |reverse_index| {
                const i = M - reverse_index;
                const row_end = if (i + 1 < M) last[i + 1] - 1 else last[i];
                if (j >= first[i] and j <= row_end) {
                    const left: i16 = if (j > first[i]) h[i] else 0;
                    const gap_score: i16 = left + (if (in_gap[i]) gap_extension else gap_start);
                    var match_value: i16 = -16_000;
                    var run: i16 = 0;

                    if (char == q.bytes[i]) {
                        match_value = h[i - 1] + match_score;
                        var b = raw_bonus;
                        run = consecutive[i - 1] + 1;
                        if (run > 1) {
                            const run_start = j + 1 - @as(usize, @intCast(run));
                            const first_bonus: i16 = @intCast(bonus[run_start]);
                            if (b >= boundary and b > first_bonus) {
                                run = 1;
                            } else {
                                b = @max(b, @max(consecutive_bonus, first_bonus));
                            }
                        }
                        if (match_value + b < gap_score) {
                            match_value += raw_bonus;
                            run = 0;
                        } else {
                            match_value += b;
                        }
                    }

                    consecutive[i] = run;
                    in_gap[i] = match_value < gap_score;
                    h[i] = @max(@max(match_value, gap_score), 0);
                    if (i == M - 1) max_score = @max(max_score, h[i]);
                }
            }

            if (j < last[1]) {
                if (char == q.bytes[0]) {
                    h[0] = match_score + raw_bonus * first_multiplier;
                    consecutive[0] = 1;
                    in_gap[0] = false;
                } else {
                    h[0] = @max(h[0] + (if (in_gap[0]) gap_extension else gap_start), 0);
                    consecutive[0] = 0;
                    in_gap[0] = true;
                }
            }
        }

        return @intCast(max_score);
    }

    /// General exact score-only fzf V2 DP. Kept separate from the small-query
    /// kernels both as the 7+ byte production path and as a parity reference.
    fn sparseGapScore(score: i16, consecutive: i16, distance: usize) i16 {
        if (distance == 0) return score;
        const distance_i: i16 = @intCast(distance);
        const penalty = if (consecutive != 0) distance_i + 2 else distance_i;
        return @max(score - penalty, 0);
    }

    /// Exact sparse V2 DP for prepared 7/8-byte queries on candidates that fit
    /// in a u64 position mask. Dense V2 updates every feasible column even when
    /// the row character does not match. Between match columns those cells are
    /// only a deterministic gap decay, so keep state at match columns and
    /// reconstruct the score at j-1 analytically for the next row.
    fn scoreV2Sparse64Prepared(self: *Index, q: *const Query, entry: Entry) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const m = q.bytes.len;
        const first = self.position_scratch[0..m];
        const last = self.last_position_scratch[0..m];
        std.debug.assert((m == 7 or m == 8) and text.len <= 64);

        var previous = self.dp[0 .. text.len * 2];
        var current = self.dp[text.len * 2 .. text.len * 4];

        const match_score_base: i16 = score_match;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const first_multiplier: i16 = bonus_first_char_multiplier;

        // First row. Only q[0] occurrences need materialized state; scores in
        // between are recoverable as gap decay from the latest occurrence.
        var previous_mask: u64 = 0;
        const first_char = q.bytes[0];
        var j = first[0];
        while (j < last[1]) : (j += 1) {
            if (text[j] != first_char) continue;
            const bit = @as(u64, 1) << @intCast(j);
            previous_mask |= bit;
            const cell = j * 2;
            previous[cell] = match_score_base + @as(i16, @intCast(bonus[j])) * first_multiplier;
            previous[cell + 1] = 1;
        }

        var max_score: i16 = 0;
        var pattern_index: usize = 1;
        while (pattern_index < m) : (pattern_index += 1) {
            const pattern_char = q.bytes[pattern_index];
            const row_end = if (pattern_index + 1 < m) last[pattern_index + 1] - 1 else last[pattern_index];
            var current_mask: u64 = 0;
            var have_current = false;
            var current_pos: usize = 0;
            var current_score: i16 = 0;
            var current_consecutive: i16 = 0;

            j = first[pattern_index];
            while (j <= row_end) : (j += 1) {
                if (text[j] != pattern_char) continue;

                const gap_score: i16 = if (have_current)
                    sparseGapScore(current_score, current_consecutive, j - current_pos)
                else
                    0;

                // A feasible row match always has a previous-row occurrence
                // before it. Find the latest one in O(1) from the sparse mask.
                const before_mask = previous_mask & ((@as(u64, 1) << @intCast(j)) - 1);
                std.debug.assert(before_mask != 0);
                const previous_pos: usize = 63 - @as(usize, @intCast(@clz(before_mask)));
                const previous_cell = previous_pos * 2;
                const distance = (j - 1) - previous_pos;
                const previous_score = sparseGapScore(previous[previous_cell], previous[previous_cell + 1], distance);
                const previous_consecutive: i16 = if (distance == 0) previous[previous_cell + 1] else 0;

                var match_value = previous_score + match_score_base;
                var b: i16 = @intCast(bonus[j]);
                var consecutive = previous_consecutive + 1;
                if (consecutive > 1) {
                    const run_start = j + 1 - @as(usize, @intCast(consecutive));
                    const first_bonus: i16 = @intCast(bonus[run_start]);
                    if (b >= boundary and b > first_bonus) {
                        consecutive = 1;
                    } else {
                        b = @max(b, @max(consecutive_bonus, first_bonus));
                    }
                }
                if (match_value + b < gap_score) {
                    match_value += @intCast(bonus[j]);
                    consecutive = 0;
                } else {
                    match_value += b;
                }

                const score = @max(match_value, gap_score);
                if (pattern_index == m - 1) {
                    max_score = @max(max_score, score);
                } else {
                    const cell = j * 2;
                    current[cell] = score;
                    current[cell + 1] = consecutive;
                    current_mask |= @as(u64, 1) << @intCast(j);
                }
                have_current = true;
                current_pos = j;
                current_score = score;
                current_consecutive = consecutive;
            }

            previous_mask = current_mask;
            const temp = previous;
            previous = current;
            current = temp;
        }
        return @intCast(max_score);
    }

    fn scoreV2GeneralFromFirst(self: *Index, q: *const Query, entry: Entry, last_hint: ?usize, last_prepared: bool) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const m = q.bytes.len;
        const n = text.len;
        const first = self.position_scratch[0..m];

        if (m == 1) return self.scoreV2Single(q, entry).?;
        if (m == 2) return self.scoreV2TwoFromFirst(q, entry);
        if (m > 1000) return self.scoreV1(q, entry).?;

        const last = self.last_position_scratch[0..m];
        if (!last_prepared) {
            var reverse_pattern = m;
            var reverse_col = n;
            if (last_hint) |position| {
                last[m - 1] = position;
                reverse_pattern = m - 1;
                reverse_col = position;
            }
            while (reverse_pattern != 0) {
                reverse_col -= 1;
                if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
                reverse_pattern -= 1;
                last[reverse_pattern] = reverse_col;
            }
        }

        const first_col = first[0];
        var previous = self.dp[0 .. n * 2];
        var current = self.dp[n * 2 .. n * 4];

        const match_score_base: i16 = score_match;
        const gap_start: i16 = score_gap_start;
        const gap_extension: i16 = score_gap_extension;
        const boundary: i16 = bonus_boundary;
        const consecutive_bonus: i16 = bonus_consecutive;
        const first_multiplier: i16 = bonus_first_char_multiplier;

        var in_gap = false;
        var previous_score: i16 = 0;
        var max_score: i16 = 0;
        const first_char = q.bytes[0];

        var first_row_col = first_col;
        while (first_row_col < last[1]) : (first_row_col += 1) {
            const c = text[first_row_col];
            const cell = first_row_col * 2;
            if (c == first_char) {
                previous[cell] = match_score_base + @as(i16, @intCast(bonus[first_row_col])) * first_multiplier;
                previous[cell + 1] = 1;
                in_gap = false;
            } else {
                previous[cell] = @max(previous_score + (if (in_gap) gap_extension else gap_start), 0);
                previous[cell + 1] = 0;
                in_gap = true;
            }
            previous_score = previous[cell];
        }

        var pattern_index: usize = 1;
        while (pattern_index < m) : (pattern_index += 1) {
            const first_feasible = first[pattern_index];
            const pattern_char = q.bytes[pattern_index];
            in_gap = false;

            var j = first_feasible;
            const row_end = if (pattern_index + 1 < m) last[pattern_index + 1] - 1 else last[pattern_index];
            while (j <= row_end) : (j += 1) {
                const cell = j * 2;
                const left: i16 = if (j > first_feasible) current[cell - 2] else 0;
                const gap_score = left + (if (in_gap) gap_extension else gap_start);

                var match_value: i16 = -16_000;
                var consecutive: i16 = 0;
                if (text[j] == pattern_char and j > 0) {
                    const prev_cell = cell - 2;
                    match_value = previous[prev_cell] + match_score_base;
                    var b: i16 = @intCast(bonus[j]);
                    consecutive = previous[prev_cell + 1] + 1;
                    if (consecutive > 1) {
                        const run_start = j + 1 - @as(usize, @intCast(consecutive));
                        const first_bonus: i16 = @intCast(bonus[run_start]);
                        if (b >= boundary and b > first_bonus) {
                            consecutive = 1;
                        } else {
                            b = @max(b, @max(consecutive_bonus, first_bonus));
                        }
                    }
                    if (match_value + b < gap_score) {
                        match_value += @intCast(bonus[j]);
                        consecutive = 0;
                    } else {
                        match_value += b;
                    }
                }
                current[cell + 1] = consecutive;
                in_gap = match_value < gap_score;
                const score: i16 = @max(@max(match_value, gap_score), 0);
                current[cell] = score;
                if (pattern_index == m - 1) max_score = @max(max_score, score);
            }
            const temp = previous;
            previous = current;
            current = temp;
        }
        return @intCast(max_score);
    }

    fn prepareLastPositions(self: *Index, q: *const Query, entry: Entry, entry_index: usize) void {
        const text = self.candidateLower(entry);
        const m = q.bytes.len;
        const last = self.last_position_scratch[0..m];
        var reverse_pattern = m;
        var reverse_col = text.len;
        if (self.indexedLastPosition(entry, entry_index, q.classes[m - 1])) |position| {
            last[m - 1] = position;
            reverse_pattern = m - 1;
            reverse_col = position;
        }
        while (reverse_pattern != 0) {
            reverse_col -= 1;
            if (text[reverse_col] != q.bytes[reverse_pattern - 1]) continue;
            reverse_pattern -= 1;
            last[reverse_pattern] = reverse_col;
        }
    }

    fn gapAwareUpperPrepared6(self: *const Index, q: *const Query, packed_bits: u16) i32 {
        std.debug.assert(q.bytes.len == 6);
        var categories: u16 = packed_bits;
        var prefix_category: u2 = @truncate(categories);
        categories >>= 2;
        var upper = score_match + @as(i32, categoryBonusValue(prefix_category)) * bonus_first_char_multiplier;
        for (1..6) |i| {
            const latest_previous = self.last_position_scratch[i - 1];
            const earliest_current = self.position_scratch[i];
            if (latest_previous + 1 < earliest_current) {
                const gap = earliest_current - latest_previous - 1;
                const penalty = score_gap_start + @as(i32, @intCast(gap - 1)) * score_gap_extension;
                upper = @max(0, upper + penalty);
            }
            const category: u2 = @truncate(categories);
            categories >>= 2;
            prefix_category = @max(prefix_category, category);
            upper += score_match + @max(@as(i32, categoryBonusValue(prefix_category)), bonus_consecutive);
        }
        return upper;
    }

    fn gapAwareUpperPrepared(self: *const Index, q: *const Query, caps: BonusCaps) i32 {
        var prefix_bonus = bonusCap(caps, q.classes[0]);
        const first_upper = score_match + prefix_bonus * bonus_first_char_multiplier;
        var upper = first_upper;
        var base_upper = first_upper;
        for (1..q.bytes.len) |i| {
            const latest_previous = self.last_position_scratch[i - 1];
            const earliest_current = self.position_scratch[i];
            if (latest_previous + 1 < earliest_current) {
                const gap = earliest_current - latest_previous - 1;
                const penalty = score_gap_start + @as(i32, @intCast(gap - 1)) * score_gap_extension;
                upper = @max(0, upper + penalty);
            }
            prefix_bonus = @max(prefix_bonus, bonusCap(caps, q.classes[i]));
            const match_upper = score_match + @max(prefix_bonus, bonus_consecutive);
            upper += match_upper;
            base_upper += match_upper;
        }

        // Forward greedy fixes the earliest feasible final match; reverse
        // greedy fixes the latest feasible first match. Every alignment spans
        // at least that interval, hence contains at least span-m gap bytes.
        // Charge those bytes as one gap run, the least-negative arrangement,
        // and cap the reduction by the maximum first-match prefix because V2
        // floors a sufficiently damaged prefix at zero.
        const latest_first = self.last_position_scratch[0];
        const earliest_last = self.position_scratch[q.bytes.len - 1];
        if (earliest_last >= latest_first) {
            const span = earliest_last - latest_first + 1;
            if (span > q.bytes.len) {
                const forced_gap = span - q.bytes.len;
                const gap_cost = -score_gap_start + @as(i32, @intCast(forced_gap - 1)) * -score_gap_extension;
                const span_upper = base_upper - @min(gap_cost, first_upper);
                upper = @min(upper, span_upper);
            }
        }
        return upper;
    }

    fn indexedLastPosition(self: *const Index, entry: Entry, entry_index: usize, class_value: u6) ?usize {
        if (entry.len >= 256) return null;
        const class: usize = @intCast(class_value);
        if (class >= exact_signature_classes) return null;
        const slot = self.last_slot_for_class[class];
        if (slot == 0xff) return null;
        const stored = self.last_positions[@as(usize, slot) * self.entries.len + entry_index].last;
        return if (stored == 0xff) null else @as(usize, stored);
    }

    fn indexedFirstPositionForSlot(self: *const Index, entry: Entry, entry_index: usize, slot: u8) ?usize {
        if (slot == 0xff or entry.len >= 256) return null;
        const stored = self.last_positions[@as(usize, slot) * self.entries.len + entry_index].first;
        return if (stored == 0xff) null else @as(usize, stored);
    }

    fn scoreV2IndexedFromFirst(self: *Index, q: *const Query, entry: Entry, entry_index: usize) i32 {
        if (q.bytes.len == 1) return self.scoreV2Single(q, entry).?;
        if (q.bytes.len == 2) return self.scoreV2TwoIndexed(q, entry, entry_index);
        const last_hint = self.indexedLastPosition(entry, entry_index, q.classes[q.classes.len - 1]);
        return switch (q.bytes.len) {
            3 => self.scoreV2ThreeFromFirst(q, entry, last_hint),
            4 => self.scoreV2FourFromFirst(q, entry, last_hint),
            5 => self.scoreV2FiveFromFirst(q, entry, last_hint),
            6 => self.scoreV2SixFromFirst(q, entry, last_hint),
            else => self.scoreV2GeneralFromFirst(q, entry, last_hint, false),
        };
    }

    fn scoreV2FromFirst(self: *Index, q: *const Query, entry: Entry) i32 {
        return switch (q.bytes.len) {
            3 => self.scoreV2ThreeFromFirst(q, entry, null),
            4 => self.scoreV2FourFromFirst(q, entry, null),
            5 => self.scoreV2FiveFromFirst(q, entry, null),
            6 => self.scoreV2SixFromFirst(q, entry, null),
            else => self.scoreV2GeneralFromFirst(q, entry, null, false),
        };
    }

    /// Convenience wrapper used by parity tests.
    fn scoreV2(self: *Index, q: *const Query, entry: Entry) ?i32 {
        if (q.bytes.len == 0) return 0;
        if (q.bytes.len > entry.len) return null;
        if (q.bytes.len == 1) return self.scoreV2Single(q, entry);
        if (!self.subsequence(q, entry)) return null;
        if (q.bytes.len == 2) return self.scoreV2TwoFromFirst(q, entry);
        return self.scoreV2FromFirst(q, entry);
    }
};

/// Preprocess an immutable candidate array for repeated searching.
pub fn init(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error!Index {
    return Index.init(allocator, values);
}

/// Internal CLI hook. This is intentionally not re-exported by root.zig.
/// It returns the exact folded V2/V1-fallback score used by Index.search.
pub fn scoreFoldedForCli(index: *Index, query: []const u8, entry_index: usize) ?i32 {
    if (entry_index >= index.entries.len) return null;
    const q = index.compileQuery(query);
    if (q.impossible) return null;
    return index.scoreV2(&q, index.entries[entry_index]);
}

/// Internal CLI scoring result. Kept in the engine module so the executable can
/// implement fzf's extended-query ranking without widening the public facade.
pub const CliMatch = struct {
    score: i32,
    start: usize,
    end: usize,
};

pub const CliScheme = enum { default, path, history };

fn cliByteEq(candidate: u8, pattern: u8, case_sensitive: bool) bool {
    return if (case_sensitive) candidate == pattern else lower_lut[candidate] == lower_lut[pattern];
}

fn cliSubsequence(candidate: []const u8, pattern: []const u8, case_sensitive: bool) bool {
    if (pattern.len == 0) return true;
    var p: usize = 0;
    for (candidate) |c| {
        if (cliByteEq(c, pattern[p], case_sensitive)) {
            p += 1;
            if (p == pattern.len) return true;
        }
    }
    return false;
}

fn cliSchemeCharClass(c: u8, scheme: CliScheme) CharClass {
    if (c >= 'a' and c <= 'z') return .lower;
    if (c >= 'A' and c <= 'Z') return .upper;
    if (c >= '0' and c <= '9') return .number;
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => .white,
        '/' => .delimiter,
        ',', ':', ';', '|' => if (scheme == .path) .non_word else .delimiter,
        else => .non_word,
    };
}

fn cliSchemeBonusFor(previous: CharClass, current: CharClass, scheme: CliScheme) i32 {
    const boundary_white: i32 = if (scheme == .default) bonus_boundary_white else bonus_boundary;
    const boundary_delimiter: i32 = if (scheme == .history) bonus_boundary else bonus_boundary_delimiter;
    if (current != .white) {
        switch (previous) {
            .white => return boundary_white,
            .delimiter => return boundary_delimiter,
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
        .white => boundary_white,
        else => 0,
    };
}

fn cliSchemeBonusAt(index: *const Index, entry: Entry, candidate: []const u8, pos: usize, scheme: CliScheme) i32 {
    if (scheme == .default) return @intCast(index.candidateBonuses(entry)[pos]);
    const current = cliSchemeCharClass(candidate[pos], scheme);
    const previous: CharClass = if (pos == 0)
        (if (scheme == .path) .delimiter else .white)
    else
        cliSchemeCharClass(candidate[pos - 1], scheme);
    return cliSchemeBonusFor(previous, current, scheme);
}

fn cliCalculateScoreScheme(index: *const Index, entry: Entry, candidate: []const u8, pattern: []const u8, start: usize, end: usize, case_sensitive: bool, scheme: CliScheme) i32 {
    var p: usize = 0;
    var score: i32 = 0;
    var in_gap = false;
    var consecutive: usize = 0;
    var first_bonus: i32 = 0;
    var j = start;
    while (j < end and p < pattern.len) : (j += 1) {
        if (cliByteEq(candidate[j], pattern[p], case_sensitive)) {
            score += score_match;
            var b: i32 = cliSchemeBonusAt(index, entry, candidate, j, scheme);
            if (consecutive == 0) {
                first_bonus = b;
            } else {
                if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
                b = @max(@max(b, first_bonus), bonus_consecutive);
            }
            score += if (p == 0) b * bonus_first_char_multiplier else b;
            in_gap = false;
            consecutive += 1;
            p += 1;
        } else {
            score += if (in_gap) score_gap_extension else score_gap_start;
            in_gap = true;
            consecutive = 0;
            first_bonus = 0;
        }
    }
    return score;
}

fn cliScoreV1(index: *const Index, entry: Entry, candidate: []const u8, pattern: []const u8, case_sensitive: bool, scheme: CliScheme) ?CliMatch {
    if (pattern.len == 0) return .{ .score = 0, .start = 0, .end = 0 };
    var p: usize = 0;
    var start: ?usize = null;
    var end: usize = 0;
    for (candidate, 0..) |c, i| {
        if (cliByteEq(c, pattern[p], case_sensitive)) {
            if (start == null) start = i;
            p += 1;
            if (p == pattern.len) {
                end = i + 1;
                break;
            }
        }
    }
    if (p != pattern.len) return null;

    p = pattern.len;
    var compact_start = start.?;
    var i = end;
    while (i > compact_start and p > 0) {
        i -= 1;
        if (cliByteEq(candidate[i], pattern[p - 1], case_sensitive)) {
            p -= 1;
            if (p == 0) {
                compact_start = i;
                break;
            }
        }
    }
    return .{
        .score = cliCalculateScoreScheme(index, entry, candidate, pattern, compact_start, end, case_sensitive, scheme),
        .start = compact_start,
        .end = end,
    };
}

fn cliSubsequenceStart(candidate: []const u8, pattern: []const u8, case_sensitive: bool) ?usize {
    if (pattern.len == 0) return 0;
    var p: usize = 0;
    var start: usize = 0;
    for (candidate, 0..) |c, i| {
        if (cliByteEq(c, pattern[p], case_sensitive)) {
            if (p == 0) start = i;
            p += 1;
            if (p == pattern.len) return start;
        }
    }
    return null;
}

/// Exact fzf-V2 score for one CLI candidate/query pair, with optional ASCII
/// case sensitivity. This intentionally uses a compact two-row DP because the
/// extended-query path values exact semantics and small code over the highly
/// specialized top-K kernels used by Index.search.
pub fn matchFuzzyForCliScheme(index: *Index, query: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool, scheme: CliScheme) ?CliMatch {
    if (entry_index >= index.entries.len) return null;
    const entry = index.entries[entry_index];
    if (candidate.len != entry.len or query.len > candidate.len) return null;
    if (query.len == 0) return .{ .score = 0, .start = 0, .end = 0 };
    const first_start = cliSubsequenceStart(candidate, query, case_sensitive) orelse return null;
    if (query.len > 1000) return cliScoreV1(index, entry, candidate, query, case_sensitive, scheme);

    if (query.len == 1) {
        var best: ?CliMatch = null;
        for (candidate, 0..) |c, i| {
            if (!cliByteEq(c, query[0], case_sensitive)) continue;
            const raw_bonus = cliSchemeBonusAt(index, entry, candidate, i, scheme);
            const score = score_match + raw_bonus * bonus_first_char_multiplier;
            if (best == null or score > best.?.score) best = .{ .score = score, .start = i, .end = i + 1 };
            if (raw_bonus >= bonus_boundary) return best;
        }
        return best;
    }

    const n = candidate.len;
    var prev_h = index.dp[0..n];
    var prev_c = index.dp[n .. 2 * n];
    var cur_h = index.dp[2 * n .. 3 * n];
    var cur_c = index.dp[3 * n .. 4 * n];

    var previous_score: i16 = 0;
    var in_gap = false;
    var j: usize = first_start;
    while (j < n) : (j += 1) {
        const c = candidate[j];
        if (cliByteEq(c, query[0], case_sensitive)) {
            prev_h[j] = @intCast(score_match + cliSchemeBonusAt(index, entry, candidate, j, scheme) * bonus_first_char_multiplier);
            prev_c[j] = 1;
            in_gap = false;
        } else {
            const penalty: i16 = @intCast(if (in_gap) score_gap_extension else score_gap_start);
            prev_h[j] = @max(previous_score + penalty, 0);
            prev_c[j] = 0;
            in_gap = true;
        }
        previous_score = prev_h[j];
    }

    var max_score: i16 = 0;
    var max_score_pos: usize = first_start;
    var row: usize = 1;
    while (row < query.len) : (row += 1) {
        in_gap = false;
        var left: i16 = 0;
        j = first_start;
        while (j < n) : (j += 1) {
            const c = candidate[j];
            const gap_penalty: i16 = @intCast(if (in_gap) score_gap_extension else score_gap_start);
            const gap_score: i16 = left + gap_penalty;
            var match_score_value: i16 = 0;
            var consecutive: i16 = 0;
            if (j > first_start and cliByteEq(c, query[row], case_sensitive)) {
                match_score_value = prev_h[j - 1] + @as(i16, score_match);
                var b: i16 = @intCast(cliSchemeBonusAt(index, entry, candidate, j, scheme));
                consecutive = prev_c[j - 1] + 1;
                if (consecutive > 1) {
                    const first_index = j + 1 - @as(usize, @intCast(consecutive));
                    const first_bonus: i16 = @intCast(cliSchemeBonusAt(index, entry, candidate, first_index, scheme));
                    if (b >= bonus_boundary and b > first_bonus) {
                        consecutive = 1;
                    } else {
                        b = @max(@max(b, @as(i16, bonus_consecutive)), first_bonus);
                    }
                }
                if (match_score_value + b < gap_score) {
                    match_score_value += @intCast(cliSchemeBonusAt(index, entry, candidate, j, scheme));
                    consecutive = 0;
                } else {
                    match_score_value += b;
                }
            }
            cur_c[j] = consecutive;
            in_gap = match_score_value < gap_score;
            const score: i16 = @max(@max(match_score_value, gap_score), 0);
            cur_h[j] = score;
            left = score;
            if (row + 1 == query.len and score > max_score) {
                max_score = score;
                max_score_pos = j;
            }
        }
        std.mem.swap([]i16, &prev_h, &cur_h);
        std.mem.swap([]i16, &prev_c, &cur_c);
    }
    return .{ .score = @intCast(max_score), .start = first_start, .end = max_score_pos + 1 };
}

pub fn matchFuzzyForCli(index: *Index, query: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool) ?CliMatch {
    return matchFuzzyForCliScheme(index, query, candidate, entry_index, case_sensitive, .default);
}

pub fn scoreFuzzyForCli(index: *Index, query: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool) ?i32 {
    const matched = matchFuzzyForCli(index, query, candidate, entry_index, case_sensitive) orelse return null;
    return matched.score;
}

fn cliContiguousScoreScheme(index: *const Index, entry: Entry, candidate: []const u8, start: usize, len: usize, scheme: CliScheme) i32 {
    var total: i32 = 0;
    var consecutive: usize = 0;
    var first_bonus: i32 = 0;
    for (0..len) |k| {
        var b: i32 = cliSchemeBonusAt(index, entry, candidate, start + k, scheme);
        total += score_match;
        if (consecutive == 0) {
            first_bonus = b;
        } else {
            if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
            b = @max(@max(b, first_bonus), bonus_consecutive);
        }
        total += if (k == 0) b * bonus_first_char_multiplier else b;
        consecutive += 1;
    }
    return total;
}

fn cliExactAt(candidate: []const u8, needle: []const u8, start: usize, case_sensitive: bool) bool {
    if (start + needle.len > candidate.len) return false;
    for (needle, 0..) |c, i| if (!cliByteEq(candidate[start + i], c, case_sensitive)) return false;
    return true;
}

fn cliBoundarySide(c: u8, scheme: CliScheme) bool {
    return @intFromEnum(cliSchemeCharClass(c, scheme)) <= @intFromEnum(CharClass.delimiter);
}

pub fn scoreExactForCliScheme(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool, boundary: bool, scheme: CliScheme) ?CliMatch {
    if (entry_index >= index.entries.len) return null;
    const entry = index.entries[entry_index];
    if (candidate.len != entry.len or needle.len > candidate.len) return null;
    if (needle.len == 0) return .{ .score = 0, .start = 0, .end = 0 };
    var best_start: ?usize = null;
    var best_bonus: i32 = -1;
    var start: usize = 0;
    while (start + needle.len <= candidate.len) : (start += 1) {
        if (!cliExactAt(candidate, needle, start, case_sensitive)) continue;
        const b = cliSchemeBonusAt(index, entry, candidate, start, scheme);
        if (boundary) {
            if (b < bonus_boundary) continue;
            if (start > 0 and !cliBoundarySide(candidate[start - 1], scheme)) continue;
            const end = start + needle.len;
            if (end < candidate.len and !cliBoundarySide(candidate[end], scheme)) continue;
        }
        if (b > best_bonus) {
            best_bonus = b;
            best_start = start;
        }
        if (b >= bonus_boundary) break;
    }
    const s = best_start orelse return null;
    const e = s + needle.len;
    if (!boundary) return .{ .score = cliContiguousScoreScheme(index, entry, candidate, s, needle.len, scheme), .start = s, .end = e };

    var score = best_bonus;
    var deduct = best_bonus - bonus_boundary + 1;
    if (s > 0 and candidate[s - 1] == '_') {
        score -= deduct + 1;
        deduct = 1;
    }
    if (e < candidate.len and candidate[e] == '_') score -= deduct;
    const boundary_white: i32 = if (scheme == .default) bonus_boundary_white else bonus_boundary;
    score += score_match * @as(i32, @intCast(needle.len)) + boundary_white * @as(i32, @intCast(needle.len + 1));
    return .{ .score = score, .start = s, .end = e };
}

pub fn scorePrefixForCliScheme(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool, scheme: CliScheme) ?CliMatch {
    if (entry_index >= index.entries.len) return null;
    const entry = index.entries[entry_index];
    if (candidate.len != entry.len) return null;
    var start: usize = 0;
    if (needle.len != 0 and !std.ascii.isWhitespace(needle[0])) {
        while (start < candidate.len and std.ascii.isWhitespace(candidate[start])) start += 1;
    }
    if (!cliExactAt(candidate, needle, start, case_sensitive)) return null;
    return .{ .score = cliContiguousScoreScheme(index, entry, candidate, start, needle.len, scheme), .start = start, .end = start + needle.len };
}

pub fn scoreSuffixForCliScheme(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool, scheme: CliScheme) ?CliMatch {
    if (entry_index >= index.entries.len) return null;
    const entry = index.entries[entry_index];
    if (candidate.len != entry.len) return null;
    var end = candidate.len;
    if (needle.len == 0 or !std.ascii.isWhitespace(needle[needle.len - 1])) {
        while (end > 0 and std.ascii.isWhitespace(candidate[end - 1])) end -= 1;
    }
    if (needle.len > end) return null;
    const start = end - needle.len;
    if (!cliExactAt(candidate, needle, start, case_sensitive)) return null;
    return .{ .score = cliContiguousScoreScheme(index, entry, candidate, start, needle.len, scheme), .start = start, .end = end };
}

pub fn scoreEqualForCliScheme(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool, scheme: CliScheme) ?CliMatch {
    if (entry_index >= index.entries.len or needle.len == 0) return null;
    const entry = index.entries[entry_index];
    if (candidate.len != entry.len) return null;
    var start: usize = 0;
    var end = candidate.len;
    if (!std.ascii.isWhitespace(needle[0])) {
        while (start < end and std.ascii.isWhitespace(candidate[start])) start += 1;
    }
    if (!std.ascii.isWhitespace(needle[needle.len - 1])) {
        while (end > start and std.ascii.isWhitespace(candidate[end - 1])) end -= 1;
    }
    if (end - start != needle.len or !cliExactAt(candidate, needle, start, case_sensitive)) return null;
    const boundary_white: i32 = if (scheme == .default) bonus_boundary_white else bonus_boundary;
    const score = (score_match + boundary_white) * @as(i32, @intCast(needle.len)) + (bonus_first_char_multiplier - 1) * boundary_white;
    return .{ .score = score, .start = start, .end = end };
}

pub fn scoreExactForCli(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool, boundary: bool) ?CliMatch {
    return scoreExactForCliScheme(index, needle, candidate, entry_index, case_sensitive, boundary, .default);
}

pub fn scorePrefixForCli(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool) ?CliMatch {
    return scorePrefixForCliScheme(index, needle, candidate, entry_index, case_sensitive, .default);
}

pub fn scoreSuffixForCli(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool) ?CliMatch {
    return scoreSuffixForCliScheme(index, needle, candidate, entry_index, case_sensitive, .default);
}

pub fn scoreEqualForCli(index: *const Index, needle: []const u8, candidate: []const u8, entry_index: usize, case_sensitive: bool) ?CliMatch {
    return scoreEqualForCliScheme(index, needle, candidate, entry_index, case_sensitive, .default);
}

const CliRuneClass = enum(u3) { white, non_word, delimiter, lower, upper, letter, number };

fn cliRuneClass(cp: u21, scheme: CliScheme) CliRuneClass {
    if (cp <= 0x7f) return switch (cliSchemeCharClass(@intCast(cp), scheme)) {
        .white => .white,
        .non_word => .non_word,
        .delimiter => .delimiter,
        .lower => .lower,
        .upper => .upper,
        .number => .number,
    };
    return switch (unicode_cli.classOf(cp)) {
        .white => .white,
        .lower => .lower,
        .upper => .upper,
        .letter => .letter,
        .number => .number,
        .other => .non_word,
    };
}

fn cliRuneBonusFor(previous: CliRuneClass, current: CliRuneClass, scheme: CliScheme) i32 {
    const boundary_white: i32 = if (scheme == .default) bonus_boundary_white else bonus_boundary;
    const boundary_delimiter: i32 = if (scheme == .history) bonus_boundary else bonus_boundary_delimiter;
    if (current != .white) {
        switch (previous) {
            .white => return boundary_white,
            .delimiter => return boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        }
    }
    if ((previous == .lower and current == .upper) or (previous != .number and current == .number)) return bonus_camel_number;
    return switch (current) {
        .non_word, .delimiter => bonus_non_word,
        .white => boundary_white,
        else => 0,
    };
}

fn cliInitialRuneClass(scheme: CliScheme) CliRuneClass {
    return if (scheme == .path) .delimiter else .white;
}

fn cliRuneMetaBonus(meta: usize) i32 {
    return @intCast(meta & 0xff);
}

fn cliRuneMetaClass(meta: usize) CliRuneClass {
    return @enumFromInt((meta >> 8) & 0x7);
}

fn cliPrepareUnicodeCandidate(index: *Index, candidate: []const u8, case_sensitive: bool, normalize: bool, scheme: CliScheme) ?usize {
    if (!std.unicode.utf8ValidateSlice(candidate)) return null;
    var it = std.unicode.Utf8Iterator{ .bytes = candidate, .i = 0 };
    var n: usize = 0;
    var previous = cliInitialRuneClass(scheme);
    while (it.nextCodepoint()) |raw| : (n += 1) {
        const class = cliRuneClass(raw, scheme);
        const bonus = cliRuneBonusFor(previous, class, scheme);
        var cp = raw;
        if (!case_sensitive) cp = unicode_cli.toLower(cp);
        if (normalize) cp = unicode_cli.normalize(cp);
        index.position_scratch[n] = cp;
        index.last_position_scratch[n] = @as(usize, @intCast(bonus)) | (@as(usize, @intFromEnum(class)) << 8);
        previous = class;
    }
    return n;
}

fn cliPrepareUnicodePattern(query: []const u8, case_sensitive: bool, normalize: bool, out: []u21) ?usize {
    if (!std.unicode.utf8ValidateSlice(query)) return null;
    var it = std.unicode.Utf8Iterator{ .bytes = query, .i = 0 };
    var n: usize = 0;
    while (it.nextCodepoint()) |raw| {
        if (n == out.len) return null;
        var cp = raw;
        if (!case_sensitive) cp = unicode_cli.toLower(cp);
        if (normalize) cp = unicode_cli.normalize(cp);
        out[n] = cp;
        n += 1;
    }
    return n;
}

pub fn cliTextHasNonAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return true;
    return false;
}

pub fn cliSmartCaseSensitive(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) {
        for (text) |c| if (c >= 'A' and c <= 'Z') return true;
        return false;
    }
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| if (unicode_cli.toLower(cp) != cp) return true;
    return false;
}

pub fn cliNormalizeTerm(text: []const u8, enabled: bool) bool {
    if (!enabled or !std.unicode.utf8ValidateSlice(text)) return false;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const lower_cp = unicode_cli.toLower(cp);
        if (unicode_cli.normalize(lower_cp) != lower_cp) return false;
    }
    return true;
}

pub fn cliRuneIsWhitespace(cp: u21) bool {
    if (cp <= 0x7f) return switch (@as(u8, @intCast(cp))) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
    return unicode_cli.classOf(cp) == .white;
}

pub fn cliRuneIsLetterOrNumber(cp: u21) bool {
    if (cp <= 0x7f) return std.ascii.isAlphanumeric(@intCast(cp));
    return switch (unicode_cli.classOf(cp)) {
        .lower, .upper, .letter, .number => true,
        else => false,
    };
}

fn cliUnicodeContiguousScore(index: *const Index, start: usize, len: usize) i32 {
    var total: i32 = 0;
    var consecutive: usize = 0;
    var first_bonus: i32 = 0;
    for (start..start + len) |j| {
        var b = cliRuneMetaBonus(index.last_position_scratch[j]);
        total += score_match;
        if (consecutive == 0) {
            first_bonus = b;
        } else {
            if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
            b = @max(@max(b, first_bonus), bonus_consecutive);
        }
        total += if (j == start) b * bonus_first_char_multiplier else b;
        consecutive += 1;
    }
    return total;
}

fn cliStoreUnicodePattern(index: *Index, query: []const u8, case_sensitive: bool, normalize: bool, expected_len: usize) bool {
    if (expected_len * 2 > index.dp.len or !std.unicode.utf8ValidateSlice(query)) return false;
    var it = std.unicode.Utf8Iterator{ .bytes = query, .i = 0 };
    var i: usize = 0;
    while (it.nextCodepoint()) |raw| : (i += 1) {
        var cp = raw;
        if (!case_sensitive) cp = unicode_cli.toLower(cp);
        if (normalize) cp = unicode_cli.normalize(cp);
        const value: u32 = cp;
        index.dp[i * 2] = @bitCast(@as(u16, @truncate(value)));
        index.dp[i * 2 + 1] = @bitCast(@as(u16, @truncate(value >> 16)));
    }
    return i == expected_len;
}

fn cliStoredPatternAt(index: *const Index, i: usize) u21 {
    const lo: u16 = @bitCast(index.dp[i * 2]);
    const hi: u16 = @bitCast(index.dp[i * 2 + 1]);
    return @intCast(@as(u32, lo) | (@as(u32, hi) << 16));
}

fn cliCalculateUnicodeStoredScore(index: *const Index, pattern_len: usize, start: usize, end: usize) i32 {
    var p: usize = 0;
    var score: i32 = 0;
    var in_gap = false;
    var consecutive: usize = 0;
    var first_bonus: i32 = 0;
    var j = start;
    while (j < end and p < pattern_len) : (j += 1) {
        if (index.position_scratch[j] == cliStoredPatternAt(index, p)) {
            score += score_match;
            var b = cliRuneMetaBonus(index.last_position_scratch[j]);
            if (consecutive == 0) {
                first_bonus = b;
            } else {
                if (b >= bonus_boundary and b > first_bonus) first_bonus = b;
                b = @max(@max(b, first_bonus), bonus_consecutive);
            }
            score += if (p == 0) b * bonus_first_char_multiplier else b;
            in_gap = false;
            consecutive += 1;
            p += 1;
        } else {
            score += if (in_gap) score_gap_extension else score_gap_start;
            in_gap = true;
            consecutive = 0;
            first_bonus = 0;
        }
    }
    return score;
}

fn cliScoreUnicodeV1Stored(index: *Index, candidate_len: usize, pattern_len: usize) ?CliMatch {
    var p: usize = 0;
    var start: ?usize = null;
    var end: usize = 0;
    for (index.position_scratch[0..candidate_len], 0..) |cp, i| {
        if (cp == cliStoredPatternAt(index, p)) {
            if (start == null) start = i;
            p += 1;
            if (p == pattern_len) {
                end = i + 1;
                break;
            }
        }
    }
    if (p != pattern_len) return null;

    p = pattern_len;
    var compact_start = start.?;
    var i = end;
    while (i > compact_start and p > 0) {
        i -= 1;
        if (index.position_scratch[i] == cliStoredPatternAt(index, p - 1)) {
            p -= 1;
            if (p == 0) {
                compact_start = i;
                break;
            }
        }
    }
    return .{
        .score = cliCalculateUnicodeStoredScore(index, pattern_len, compact_start, end),
        .start = compact_start,
        .end = end,
    };
}

fn cliUnicodeExactAtStored(index: *const Index, pattern_len: usize, start: usize) bool {
    for (0..pattern_len) |k| if (index.position_scratch[start + k] != cliStoredPatternAt(index, k)) return false;
    return true;
}

pub fn matchFuzzyUnicodeForCliScheme(index: *Index, query: []const u8, candidate: []const u8, case_sensitive: bool, normalize: bool, scheme: CliScheme) ?CliMatch {
    if (!std.unicode.utf8ValidateSlice(query)) return null;
    const n = cliPrepareUnicodeCandidate(index, candidate, case_sensitive, normalize, scheme) orelse return null;
    const m = std.unicode.utf8CountCodepoints(query) catch return null;
    if (m == 0) return .{ .score = 0, .start = 0, .end = 0 };
    if (m > n) return null;
    if (m > 1000) {
        if (!cliStoreUnicodePattern(index, query, case_sensitive, normalize, m)) return null;
        return cliScoreUnicodeV1Stored(index, n, m);
    }
    var pattern_buf: [1000]u21 = undefined;
    _ = cliPrepareUnicodePattern(query, case_sensitive, normalize, &pattern_buf) orelse return null;

    var p: usize = 0;
    var first_start: usize = 0;
    for (index.position_scratch[0..n], 0..) |cp, j| {
        if (cp == pattern_buf[p]) {
            if (p == 0) first_start = j;
            p += 1;
            if (p == m) break;
        }
    }
    if (p != m) return null;

    if (m == 1) {
        var best: ?CliMatch = null;
        for (index.position_scratch[0..n], 0..) |cp, j| {
            if (cp != pattern_buf[0]) continue;
            const raw_bonus = cliRuneMetaBonus(index.last_position_scratch[j]);
            const score = score_match + raw_bonus * bonus_first_char_multiplier;
            if (best == null or score > best.?.score) best = .{ .score = score, .start = j, .end = j + 1 };
            if (raw_bonus >= bonus_boundary) return best;
        }
        return best;
    }

    var prev_h = index.dp[0..n];
    var prev_c = index.dp[n .. 2 * n];
    var cur_h = index.dp[2 * n .. 3 * n];
    var cur_c = index.dp[3 * n .. 4 * n];
    var previous_score: i16 = 0;
    var in_gap = false;
    var j: usize = first_start;
    while (j < n) : (j += 1) {
        const cp: u21 = @intCast(index.position_scratch[j]);
        if (cp == pattern_buf[0]) {
            prev_h[j] = @intCast(score_match + cliRuneMetaBonus(index.last_position_scratch[j]) * bonus_first_char_multiplier);
            prev_c[j] = 1;
            in_gap = false;
        } else {
            const penalty: i16 = @intCast(if (in_gap) score_gap_extension else score_gap_start);
            prev_h[j] = @max(previous_score + penalty, 0);
            prev_c[j] = 0;
            in_gap = true;
        }
        previous_score = prev_h[j];
    }

    var max_score: i16 = 0;
    var max_score_pos = first_start;
    var row: usize = 1;
    while (row < m) : (row += 1) {
        in_gap = false;
        var left: i16 = 0;
        j = first_start;
        while (j < n) : (j += 1) {
            const cp: u21 = @intCast(index.position_scratch[j]);
            const gap_penalty: i16 = @intCast(if (in_gap) score_gap_extension else score_gap_start);
            const gap_score = left + gap_penalty;
            var match_score_value: i16 = 0;
            var consecutive: i16 = 0;
            if (j > first_start and cp == pattern_buf[row]) {
                match_score_value = prev_h[j - 1] + @as(i16, score_match);
                var b: i16 = @intCast(cliRuneMetaBonus(index.last_position_scratch[j]));
                consecutive = prev_c[j - 1] + 1;
                if (consecutive > 1) {
                    const first_index = j + 1 - @as(usize, @intCast(consecutive));
                    const first_bonus: i16 = @intCast(cliRuneMetaBonus(index.last_position_scratch[first_index]));
                    if (b >= bonus_boundary and b > first_bonus) {
                        consecutive = 1;
                    } else {
                        b = @max(@max(b, @as(i16, bonus_consecutive)), first_bonus);
                    }
                }
                if (match_score_value + b < gap_score) {
                    match_score_value += @intCast(cliRuneMetaBonus(index.last_position_scratch[j]));
                    consecutive = 0;
                } else {
                    match_score_value += b;
                }
            }
            cur_c[j] = consecutive;
            in_gap = match_score_value < gap_score;
            const score: i16 = @max(@max(match_score_value, gap_score), 0);
            cur_h[j] = score;
            left = score;
            if (row + 1 == m and score > max_score) {
                max_score = score;
                max_score_pos = j;
            }
        }
        std.mem.swap([]i16, &prev_h, &cur_h);
        std.mem.swap([]i16, &prev_c, &cur_c);
    }
    return .{ .score = @intCast(max_score), .start = first_start, .end = max_score_pos + 1 };
}

pub fn scoreExactUnicodeForCliScheme(index: *Index, needle: []const u8, candidate: []const u8, case_sensitive: bool, normalize: bool, boundary: bool, scheme: CliScheme) ?CliMatch {
    const n = cliPrepareUnicodeCandidate(index, candidate, case_sensitive, normalize, scheme) orelse return null;
    const m = std.unicode.utf8CountCodepoints(needle) catch return null;
    if (m == 0) return .{ .score = 0, .start = 0, .end = 0 };
    if (m > n or !cliStoreUnicodePattern(index, needle, case_sensitive, normalize, m)) return null;
    var best_start: ?usize = null;
    var best_bonus: i32 = -1;
    var scan_start: usize = 0;
    while (scan_start + m <= n) : (scan_start += 1) {
        if (!cliUnicodeExactAtStored(index, m, scan_start)) continue;
        const b = cliRuneMetaBonus(index.last_position_scratch[scan_start]);
        if (boundary) {
            if (b < bonus_boundary) continue;
            if (scan_start > 0 and @intFromEnum(cliRuneMetaClass(index.last_position_scratch[scan_start - 1])) > @intFromEnum(CliRuneClass.delimiter)) continue;
            const match_end = scan_start + m;
            if (match_end < n and @intFromEnum(cliRuneMetaClass(index.last_position_scratch[match_end])) > @intFromEnum(CliRuneClass.delimiter)) continue;
        }
        if (b > best_bonus) {
            best_bonus = b;
            best_start = scan_start;
        }
        if (b >= bonus_boundary) break;
    }
    const match_start = best_start orelse return null;
    const match_end = match_start + m;
    if (!boundary) return .{ .score = cliUnicodeContiguousScore(index, match_start, m), .start = match_start, .end = match_end };
    var score = best_bonus;
    var deduct = best_bonus - bonus_boundary + 1;
    if (match_start > 0 and index.position_scratch[match_start - 1] == '_') {
        score -= deduct + 1;
        deduct = 1;
    }
    if (match_end < n and index.position_scratch[match_end] == '_') score -= deduct;
    const boundary_white: i32 = if (scheme == .default) bonus_boundary_white else bonus_boundary;
    score += score_match * @as(i32, @intCast(m)) + boundary_white * @as(i32, @intCast(m + 1));
    return .{ .score = score, .start = match_start, .end = match_end };
}

pub fn scorePrefixUnicodeForCliScheme(index: *Index, needle: []const u8, candidate: []const u8, case_sensitive: bool, normalize: bool, scheme: CliScheme) ?CliMatch {
    const n = cliPrepareUnicodeCandidate(index, candidate, case_sensitive, normalize, scheme) orelse return null;
    const m = std.unicode.utf8CountCodepoints(needle) catch return null;
    if (m == 0) return .{ .score = 0, .start = 0, .end = 0 };
    if (m > n or !cliStoreUnicodePattern(index, needle, case_sensitive, normalize, m)) return null;
    var match_start: usize = 0;
    if (!cliRuneIsWhitespace(cliStoredPatternAt(index, 0))) {
        while (match_start < n and cliRuneMetaClass(index.last_position_scratch[match_start]) == .white) : (match_start += 1) {}
    }
    if (match_start + m > n or !cliUnicodeExactAtStored(index, m, match_start)) return null;
    return .{ .score = cliUnicodeContiguousScore(index, match_start, m), .start = match_start, .end = match_start + m };
}

pub fn scoreSuffixUnicodeForCliScheme(index: *Index, needle: []const u8, candidate: []const u8, case_sensitive: bool, normalize: bool, scheme: CliScheme) ?CliMatch {
    const n = cliPrepareUnicodeCandidate(index, candidate, case_sensitive, normalize, scheme) orelse return null;
    const m = std.unicode.utf8CountCodepoints(needle) catch return null;
    if (m > n or !cliStoreUnicodePattern(index, needle, case_sensitive, normalize, m)) return null;
    var match_end = n;
    if (m == 0 or !cliRuneIsWhitespace(cliStoredPatternAt(index, m - 1))) {
        while (match_end > 0 and cliRuneMetaClass(index.last_position_scratch[match_end - 1]) == .white) : (match_end -= 1) {}
    }
    if (m == 0) return .{ .score = 0, .start = match_end, .end = match_end };
    if (m > match_end) return null;
    const match_start = match_end - m;
    if (!cliUnicodeExactAtStored(index, m, match_start)) return null;
    return .{ .score = cliUnicodeContiguousScore(index, match_start, m), .start = match_start, .end = match_end };
}

pub fn scoreEqualUnicodeForCliScheme(index: *Index, needle: []const u8, candidate: []const u8, case_sensitive: bool, normalize: bool, scheme: CliScheme) ?CliMatch {
    const n = cliPrepareUnicodeCandidate(index, candidate, case_sensitive, normalize, scheme) orelse return null;
    const m = std.unicode.utf8CountCodepoints(needle) catch return null;
    if (m == 0 or m > n or !cliStoreUnicodePattern(index, needle, case_sensitive, normalize, m)) return null;
    var match_start: usize = 0;
    var match_end = n;
    if (!cliRuneIsWhitespace(cliStoredPatternAt(index, 0))) {
        while (match_start < match_end and cliRuneMetaClass(index.last_position_scratch[match_start]) == .white) : (match_start += 1) {}
    }
    if (!cliRuneIsWhitespace(cliStoredPatternAt(index, m - 1))) {
        while (match_end > match_start and cliRuneMetaClass(index.last_position_scratch[match_end - 1]) == .white) : (match_end -= 1) {}
    }
    if (match_end - match_start != m or !cliUnicodeExactAtStored(index, m, match_start)) return null;
    const boundary_white: i32 = if (scheme == .default) bonus_boundary_white else bonus_boundary;
    const score = (score_match + boundary_white) * @as(i32, @intCast(m)) + (bonus_first_char_multiplier - 1) * boundary_white;
    return .{ .score = score, .start = match_start, .end = match_end };
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

fn scoreUpperBoundGeneric(q: *const Query, caps: BonusCaps) i32 {
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

test "small-query score ceiling LUT matches generic arithmetic" {
    const values = [_][]const u8{
        "fooBarbaz1",
        "foo bar baz",
        "/AutomatorDocument.icns",
        "/man1/zshcompctl.1",
        "/.oh-my-zsh/cache",
        "abcabcabc",
        "src/FrameBuffer.zig",
    };
    const queries = [_][]const u8{ "obz", "fbbq", "rdoc5", "zshcmp" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        for (index.bonus_caps) |caps| {
            try std.testing.expectEqual(scoreUpperBoundGeneric(&q, caps), index.scoreUpperBound(&q, caps));
        }
    }
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

test "endpoint-span ceiling remains above exact V2 after score floor" {
    const values = [_][]const u8{
        "a----------------------------------------bcde",
        "a___b___c___d___e",
        "alpha_beta_gamma_delta_epsilon",
        "irxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxktq-",
        "one/two/three/four/five/six/seven",
        "abcdeabcdeabcde",
    };
    const queries = [_][]const u8{ "abcde", "abgde", "irktq-", "ottffs", "abcdea" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        if (q.bytes.len < 5) continue;
        const first_class: usize = @intCast(q.classes[0]);
        const last_class: usize = @intCast(q.classes[q.classes.len - 1]);
        if (first_class >= exact_signature_classes or last_class >= exact_signature_classes) continue;
        const first_slot = index.last_slot_for_class[first_class];
        const last_slot = index.last_slot_for_class[last_class];
        if (first_slot == 0xff or last_slot == 0xff) continue;

        for (index.entries, 0..) |entry, i| {
            const actual = index.scoreV2(&q, entry) orelse continue;
            const upper = index.scoreUpperBound(&q, index.bonus_caps[i]);
            const tightened = index.endpointSpanUpperBound(
                &q,
                entry,
                i,
                first_slot,
                last_slot,
                index.bonus_caps[i],
                upper,
            );
            try std.testing.expect(actual <= tightened);
        }
    }
}

test "gap-aware ceiling never underestimates generic V2" {
    const values = [_][]const u8{
        "src/alpha_beta_gamma_delta.zig",
        "/usr/local/share/doc/fuzzy-search/README.md",
        "FrameBufferManagerAndRenderer",
        "one_two_three_four_five_six_seven",
        "abcdefghijklmno_abcdefghijklmno",
        "a---b---c---d---e---f---g---h",
    };
    const queries = [_][]const u8{ "abgdzg", "ulshred", "fbmaren", "ottffss", "acegikm", "abcdefgh" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        if (q.bytes.len < 7 or q.bytes.len > 1000) continue;
        for (index.entries, 0..) |entry, i| {
            if (!index.subsequence(&q, entry)) continue;
            index.prepareLastPositions(&q, entry, i);
            const ceiling = index.gapAwareUpperPrepared(&q, index.bonus_caps[i]);
            const exact = index.scoreV2GeneralFromFirst(&q, entry, null, true);
            try std.testing.expect(exact <= ceiling);

            try std.testing.expect(index.subsequence(&q, entry));
            const ordinary = index.scoreV2GeneralFromFirst(&q, entry, null, false);
            try std.testing.expectEqual(ordinary, exact);
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

test "prepared six-byte V2 kernel matches ordinary small kernel" {
    const values = [_][]const u8{
        "alpha-beta-gamma-delta",
        "FrameBufferManagerAndRenderer",
        "src/fuzzy_backend_search.zig",
        "one_two_three_four_five_six",
        "abcdefabcdefabcdef",
    };
    const queries = [_][]const u8{ "abgade", "fbmare", "fbsrch", "ottffs", "aceace" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        try std.testing.expectEqual(@as(usize, 6), q.bytes.len);
        for (index.entries, 0..) |entry, i| {
            if (!index.subsequence(&q, entry)) continue;
            const ordinary = index.scoreV2SmallFromFirst(6, &q, entry, index.indexedLastPosition(entry, i, q.classes[5]));

            try std.testing.expect(index.subsequence(&q, entry));
            index.prepareLastPositions(&q, entry, i);
            const ceiling = index.gapAwareUpperPrepared(&q, index.bonus_caps[i]);
            const prepared = index.scoreV2SmallPreparedFromFirst(6, &q, entry);
            try std.testing.expect(prepared <= ceiling);
            try std.testing.expectEqual(ordinary, prepared);
        }
    }
}

test "small V2 kernels match general DP" {
    const values = [_][]const u8{
        "src/fuzzy_backend.zig",
        "fooBarBazQux",
        "alpha-beta-gamma-delta",
        "/usr/local/share/something",
        "abcdefabcdefabcdef",
        "FrameBufferManager",
        "one_two_three_four",
    };
    const queries = [_][]const u8{ "fbz", "fbbq", "abgd", "ulssg", "abcdea", "fbm" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        if (q.bytes.len < 3 or q.bytes.len > 6) continue;
        for (index.entries) |entry| {
            if (!index.subsequence(&q, entry)) continue;
            const general = index.scoreV2GeneralFromFirst(&q, entry, null, false);
            try std.testing.expect(index.subsequence(&q, entry));
            const specialized = switch (q.bytes.len) {
                3 => index.scoreV2SmallFromFirst(3, &q, entry, null),
                4 => index.scoreV2SmallFromFirst(4, &q, entry, null),
                5 => index.scoreV2SmallFromFirst(5, &q, entry, null),
                6 => index.scoreV2SmallFromFirst(6, &q, entry, null),
                else => unreachable,
            };
            try std.testing.expectEqual(general, specialized);
        }
    }
}

test "V2 matches fzf long-pattern V1 fallback" {
    const allocator = std.testing.allocator;
    const candidate_unit = "ba_YyBAYXYBBAXbxxy";
    const query_unit = "ybxx";
    const repetitions = 300;

    const candidate = try allocator.alloc(u8, candidate_unit.len * repetitions);
    defer allocator.free(candidate);
    const query = try allocator.alloc(u8, query_unit.len * repetitions);
    defer allocator.free(query);
    for (0..repetitions) |i| {
        @memcpy(candidate[i * candidate_unit.len ..][0..candidate_unit.len], candidate_unit);
        @memcpy(query[i * query_unit.len ..][0..query_unit.len], query_unit);
    }

    const values = [_][]const u8{candidate};
    var index = try init(allocator, &values);
    defer index.deinit();

    const q = index.compileQuery(query);
    const entry = index.entries[0];
    const v1 = index.scoreV1(&q, entry).?;
    const v2 = index.scoreV2(&q, entry).?;
    try std.testing.expectEqual(@as(i32, 14_415), v1);
    try std.testing.expectEqual(v1, v2);
}

test "single-byte cache matches exact V2 ranking" {
    const values = [_][]const u8{
        "alpha",
        "Alpha",
        "a/path",
        "foo_bar",
        "foo/bar",
        "src/main.zig",
        "1-alpha",
        "@scope/pkg",
        "{alpha}",
        "zeta",
        "beta-a",
        "unrelated",
    };
    const queries = [_][]const u8{ "a", "1", "_", "/", "@", "}" };

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    for (queries) |text| {
        const q = index.compileQuery(text);
        var exact: [values.len]StageMatch = undefined;
        var exact_len: usize = 0;
        for (index.entries, 0..) |entry, entry_index| {
            const score = index.scoreV2(&q, entry) orelse continue;
            exact[exact_len] = .{ .entry = entry_index, .score = score };
            stageBubbleWorst(index.entries, exact[0 .. exact_len + 1], exact_len);
            exact_len += 1;
        }
        stageSortBestFirst(index.entries, exact[0..exact_len]);

        index.resetHistory();
        var out: [values.len]usize = undefined;
        const got = try index.search(text, &out);
        try std.testing.expectEqual(exact_len, got.len);
        for (got, exact[0..exact_len]) |entry_index, expected| {
            try std.testing.expectEqual(expected.entry, entry_index);
        }
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

test "indexed final occurrence bound preserves subsequence search" {
    const values = [_][]const u8{
        "zzaxbyczdefyy",
        "abcdef",
        "a---b---c---d---e---f",
        "fedcbaabcdef",
        "aaaaabbbbbcccccdddddeeeeefffff",
    };
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const queries = [_][]const u8{ "abcdef", "abczef", "aaaaaf", "fedcba" };
    for (queries) |text| {
        index.resetHistory();
        const q = index.compileQuery(text);
        const first_class: usize = @intCast(q.classes[0]);
        const first_slot: u8 = if (first_class < exact_signature_classes) index.last_slot_for_class[first_class] else 0xff;
        const last_class: usize = @intCast(q.classes[q.classes.len - 1]);
        const last_slot: u8 = if (last_class < exact_signature_classes) index.last_slot_for_class[last_class] else 0xff;

        for (index.entries, 0..) |entry, entry_index| {
            if (q.bytes.len > entry.len) continue;
            const full = index.subsequenceIndexed(&q, entry, entry_index, first_slot, entry.len);
            var end = entry.len;
            if (entry.len < 256 and last_slot != 0xff) {
                const meta = index.last_positions[@as(usize, last_slot) * index.entries.len + entry_index];
                if (meta.last != 0xff) end = @as(usize, meta.last) + 1;
            }
            const bounded = index.subsequenceIndexed(&q, entry, entry_index, first_slot, end);
            try std.testing.expectEqual(full, bounded);
        }
    }
}

test "CLI Unicode scorer matches upstream fzf normalization fixtures" {
    const values = [_][]const u8{ "Só Danço Samba", "Danço", "ẞtraße", "plain-ascii" };
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const so = matchFuzzyUnicodeForCliScheme(&index, "So", values[0], false, true, .default).?;
    try std.testing.expectEqual(@as(i32, 62), so.score);
    try std.testing.expectEqual(@as(usize, 0), so.start);
    try std.testing.expectEqual(@as(usize, 2), so.end);

    const sodc = matchFuzzyUnicodeForCliScheme(&index, "sodc", values[0], false, true, .default).?;
    try std.testing.expectEqual(@as(i32, 97), sodc.score);
    try std.testing.expectEqual(@as(usize, 0), sodc.start);
    try std.testing.expectEqual(@as(usize, 7), sodc.end);

    const danco = matchFuzzyUnicodeForCliScheme(&index, "danco", values[1], false, true, .default).?;
    try std.testing.expectEqual(@as(i32, 140), danco.score);
    try std.testing.expectEqual(@as(usize, 0), danco.start);
    try std.testing.expectEqual(@as(usize, 5), danco.end);

    try std.testing.expect(matchFuzzyUnicodeForCliScheme(&index, "ßtraße", values[2], false, false, .default) != null);
}

test "CLI Unicode exact modes match upstream normalization fixture" {
    const values = [_][]const u8{"Danço"};
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const fuzzy = matchFuzzyUnicodeForCliScheme(&index, "danco", values[0], false, true, .default).?;
    const exact = scoreExactUnicodeForCliScheme(&index, "danco", values[0], false, true, false, .default).?;
    const prefix = scorePrefixUnicodeForCliScheme(&index, "danco", values[0], false, true, .default).?;
    const suffix = scoreSuffixUnicodeForCliScheme(&index, "danco", values[0], false, true, .default).?;
    const equal = scoreEqualUnicodeForCliScheme(&index, "danco", values[0], false, true, .default).?;
    for ([_]CliMatch{ fuzzy, exact, prefix, suffix, equal }) |matched| {
        try std.testing.expectEqual(@as(i32, 140), matched.score);
        try std.testing.expectEqual(@as(usize, 0), matched.start);
        try std.testing.expectEqual(@as(usize, 5), matched.end);
    }
}

test "CLI Unicode case and normalization policy matches fzf" {
    try std.testing.expect(cliSmartCaseSensitive("ẞ"));
    try std.testing.expect(!cliSmartCaseSensitive("ß"));
    try std.testing.expect(cliSmartCaseSensitive("Δ"));
    try std.testing.expect(!cliSmartCaseSensitive("δ"));
    try std.testing.expect(cliNormalizeTerm("danco", true));
    try std.testing.expect(cliNormalizeTerm("DANCO", true));
    try std.testing.expect(!cliNormalizeTerm("danço", true));
    try std.testing.expect(!cliNormalizeTerm("É", true));
    try std.testing.expect(!cliNormalizeTerm("danco", false));
}

test "CLI Unicode fallback mirrors ASCII scorer across randomized cases" {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-./,:;|@#()[]{}";
    var buffers: [64][48]u8 = undefined;
    var values: [64][]const u8 = undefined;
    var state: u64 = 0x5a17c0de12345678;
    for (&buffers, 0..) |*buffer, i| {
        const len = 1 + (i * 29 % buffer.len);
        for (buffer[0..len]) |*slot| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            slot.* = alphabet[@as(usize, @intCast(state >> 32)) % alphabet.len];
        }
        values[i] = buffer[0..len];
    }
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const schemes = [_]CliScheme{ .default, .path, .history };
    var query_buf: [10]u8 = undefined;
    for (0..1500) |trial| {
        state = state *% 2862933555777941757 +% 3037000493;
        const entry_index = @as(usize, @intCast(state >> 32)) % values.len;
        const candidate = values[entry_index];
        const qlen = 1 + trial % @min(query_buf.len, candidate.len);
        for (query_buf[0..qlen]) |*slot| {
            state = state *% 2862933555777941757 +% 3037000493;
            slot.* = alphabet[@as(usize, @intCast(state >> 33)) % alphabet.len];
        }
        const query = query_buf[0..qlen];
        for (schemes) |scheme| for ([_]bool{ false, true }) |case_sensitive| {
            try std.testing.expectEqual(
                matchFuzzyForCliScheme(&index, query, candidate, entry_index, case_sensitive, scheme),
                matchFuzzyUnicodeForCliScheme(&index, query, candidate, case_sensitive, false, scheme),
            );
            try std.testing.expectEqual(
                scoreExactForCliScheme(&index, query, candidate, entry_index, case_sensitive, false, scheme),
                scoreExactUnicodeForCliScheme(&index, query, candidate, case_sensitive, false, false, scheme),
            );
            try std.testing.expectEqual(
                scoreExactForCliScheme(&index, query, candidate, entry_index, case_sensitive, true, scheme),
                scoreExactUnicodeForCliScheme(&index, query, candidate, case_sensitive, false, true, scheme),
            );
            try std.testing.expectEqual(
                scorePrefixForCliScheme(&index, query, candidate, entry_index, case_sensitive, scheme),
                scorePrefixUnicodeForCliScheme(&index, query, candidate, case_sensitive, false, scheme),
            );
            try std.testing.expectEqual(
                scoreSuffixForCliScheme(&index, query, candidate, entry_index, case_sensitive, scheme),
                scoreSuffixUnicodeForCliScheme(&index, query, candidate, case_sensitive, false, scheme),
            );
            try std.testing.expectEqual(
                scoreEqualForCliScheme(&index, query, candidate, entry_index, case_sensitive, scheme),
                scoreEqualUnicodeForCliScheme(&index, query, candidate, case_sensitive, false, scheme),
            );
        };
    }
}

test "CLI Unicode scorer is score-equivalent on ASCII" {
    const values = [_][]const u8{ "fooBarbaz1", "foo bar baz", "/AutomatorDocument.icns", "/.oh-my-zsh/cache", "plain-ascii" };
    const queries = [_][]const u8{ "oBZ", "fbb", "rdoc", "zshc", "pain" };
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();
    for (values, queries, 0..) |value, query, i| {
        const byte_match = matchFuzzyForCliScheme(&index, query, value, i, false, .default);
        const rune_match = matchFuzzyUnicodeForCliScheme(&index, query, value, false, false, .default);
        try std.testing.expectEqual(byte_match, rune_match);
    }
}

test "CLI schemes use fzf boundary bonuses" {
    const values = [_][]const u8{ "foo", " foo", "/foo", ":foo", "-foo" };
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const expected = [_][5]i32{
        .{ 36, 36, 34, 34, 32 },
        .{ 34, 32, 34, 32, 32 },
        .{ 32, 32, 32, 32, 32 },
    };
    const schemes = [_]CliScheme{ .default, .path, .history };
    for (schemes, expected) |scheme, scores| {
        for (values, scores, 0..) |value, score, i| {
            const matched = matchFuzzyForCliScheme(&index, "f", value, i, false, scheme).?;
            try std.testing.expectEqual(score, matched.score);
        }
    }
}

test "CLI fuzzy scorer matches folded production V2 scores" {
    const values = [_][]const u8{
        "src/FuzzyBackend.zig",
        "foo-bar/Baz123.txt",
        "alpha_beta_gamma",
        "README.md",
        "a___B---c:::D",
        "zzzzzzfoobarzzzz",
        "CamelCaseHTTP2",
        "path/to/some-file.ext",
    };
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    const queries = [_][]const u8{
        "f", "fb", "fzb", "src", "b123", "abg", "read", "abc", "ccd", "foo", "ptsf", "htt2", "zzfb",
    };
    for (queries) |query| {
        for (values, 0..) |value, i| {
            index.resetHistory();
            const expected = scoreFoldedForCli(&index, query, i);
            const actual = scoreFuzzyForCli(&index, query, value, i, false);
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "CLI sensitive scorer rejects folded-only matches" {
    const values = [_][]const u8{ "FooBar", "foobar", "FOOBAR" };
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    try std.testing.expect(scoreFuzzyForCli(&index, "FB", values[0], 0, true) != null);
    try std.testing.expect(scoreFuzzyForCli(&index, "FB", values[1], 1, true) == null);
    try std.testing.expect(scoreFuzzyForCli(&index, "fb", values[2], 2, true) == null);
}

test "CLI fuzzy scorer randomized folded parity" {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/.: ";
    var buffers: [48][72]u8 = undefined;
    var values: [48][]const u8 = undefined;
    var state: u64 = 0x9e3779b97f4a7c15;
    for (&buffers, 0..) |*buffer, i| {
        const len = 12 + (i * 17 % 59);
        for (buffer[0..len]) |*slot| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            slot.* = alphabet[@as(usize, @intCast(state >> 32)) % alphabet.len];
        }
        values[i] = buffer[0..len];
    }

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    var query_buf: [10]u8 = undefined;
    for (0..160) |qi| {
        const qlen = 1 + qi % query_buf.len;
        for (query_buf[0..qlen]) |*slot| {
            state = state *% 2862933555777941757 +% 3037000493;
            slot.* = alphabet[@as(usize, @intCast(state >> 33)) % alphabet.len];
        }
        const query = query_buf[0..qlen];
        for (values, 0..) |value, i| {
            index.resetHistory();
            const expected = scoreFoldedForCli(&index, query, i);
            const actual = scoreFuzzyForCli(&index, query, value, i, false);
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "CLI fuzzy scorer covers V1 fallback above 1000 bytes" {
    var candidate_buf: [1108]u8 = undefined;
    @memset(&candidate_buf, 'a');
    candidate_buf[503] = '-';
    candidate_buf[1007] = 'b';
    const values = [_][]const u8{candidate_buf[0..]};
    var index = try init(std.testing.allocator, &values);
    defer index.deinit();

    var query_buf: [1002]u8 = undefined;
    @memset(&query_buf, 'a');
    query_buf[1001] = 'b';
    const query = query_buf[0..];
    index.resetHistory();
    const expected = scoreFoldedForCli(&index, query, 0);
    const actual = scoreFuzzyForCli(&index, query, values[0], 0, false);
    try std.testing.expectEqual(expected, actual);
}

test "randomized indexed top-k matches brute-force V2" {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_-/.: ";
    var buffers: [96][80]u8 = undefined;
    var values: [96][]const u8 = undefined;
    var state: u64 = 0xd1ff3e7a91b5c243;

    for (&buffers, 0..) |*buffer, i| {
        const len = 4 + (i * 37 % 77);
        for (buffer[0..len]) |*slot| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            slot.* = alphabet[@as(usize, @intCast(state >> 32)) % alphabet.len];
        }
        values[i] = buffer[0..len];
    }

    var index = try init(std.testing.allocator, &values);
    defer index.deinit();
    var query_buf: [12]u8 = undefined;
    var got_buf: [11]usize = undefined;
    var exact: [values.len]StageMatch = undefined;
    for (0..1200) |trial| {
        const qlen = 1 + trial % query_buf.len;
        for (query_buf[0..qlen]) |*slot| {
            state = state *% 2862933555777941757 +% 3037000493;
            slot.* = alphabet[@as(usize, @intCast(state >> 33)) % alphabet.len];
        }
        const query = query_buf[0..qlen];
        index.resetHistory();
        const q = index.compileQuery(query);
        var exact_len: usize = 0;
        for (index.entries, 0..) |entry, entry_index| {
            const score = index.scoreV2(&q, entry) orelse continue;
            exact[exact_len] = .{ .entry = entry_index, .score = score };
            stageBubbleWorst(index.entries, exact[0 .. exact_len + 1], exact_len);
            exact_len += 1;
        }
        stageSortBestFirst(index.entries, exact[0..exact_len]);

        index.resetHistory();
        const got = try index.search(query, &got_buf);
        const expected_len = @min(got_buf.len, exact_len);
        try std.testing.expectEqual(expected_len, got.len);
        for (got, exact[0..expected_len]) |entry_index, expected| {
            try std.testing.expectEqual(expected.entry, entry_index);
        }
    }
}
