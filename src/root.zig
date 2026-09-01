const std = @import("std");

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
    last_positions: []u16,
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
                if ((once & class_bit) == 0) {
                    once |= class_bit;
                } else {
                    twice |= class_bit;
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

        var last_slot_for_class = [_]u8{0xff} ** exact_signature_classes;
        var selected = [_]u8{0} ** last_slots;
        var selected_count: usize = 0;
        while (selected_count < last_slots) : (selected_count += 1) {
            var best_class: usize = 0;
            var best_frequency: usize = 0;
            for (0..exact_signature_classes) |class| {
                if (last_slot_for_class[class] != 0xff) continue;
                const frequency = plane_frequency[class];
                if (frequency > best_frequency) {
                    best_frequency = frequency;
                    best_class = class;
                }
            }
            selected[selected_count] = @intCast(best_class);
            last_slot_for_class[best_class] = @intCast(selected_count);
        }

        var last_slot_for_byte = [_]u8{0xff} ** 256;
        for (0..256) |byte_value| {
            const class: usize = @intCast(signatureClass(@intCast(byte_value)));
            if (class < exact_signature_classes) last_slot_for_byte[byte_value] = last_slot_for_class[class];
        }

        const last_positions = try allocator.alloc(u16, last_slots * values.len);
        errdefer allocator.free(last_positions);
        @memset(last_positions, std.math.maxInt(u16));
        for (entries, 0..) |entry, row| {
            if (entry.len >= std.math.maxInt(u16)) continue;
            const text = lower_bytes[entry.offset .. entry.offset + entry.len];
            for (text, 0..) |c, position| {
                const slot = last_slot_for_byte[c];
                if (slot == 0xff) continue;
                last_positions[@as(usize, slot) * values.len + row] = @intCast(position);
            }
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
                if (!self.subsequence(&q, entry)) continue;
                self.next_survivors[word] |= row_bit;

                self.addStage(.{
                    .entry = entry_index,
                    .score = self.scoreV2IndexedFromFirst(&q, entry, entry_index),
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

                // The precomputed bonus ceiling needs no candidate scan. Once
                // top-K is full, use it before the ordered-subsequence pass.
                // Rows skipped here stay in the prefix cache as "possible";
                // that cache is allowed to be a superset, so future prefix
                // extensions remain exact.
                if (stage_len == top_k) {
                    const upper = self.scoreUpperBound(&q, self.bonus_caps[entry_index]);
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
                    if (!self.subsequence(&q, entry)) continue;
                    self.next_survivors[word] |= row_bit;
                    self.addStage(.{
                        .entry = entry_index,
                        .score = self.scoreV2TwoIndexed(&q, entry, entry_index),
                    }, top_k, &stage_len);
                    continue;
                }

                // Longer queries still use the exact subsequence pass to
                // populate the first-feasible position of every query byte.
                if (!self.subsequence(&q, entry)) continue;
                self.next_survivors[word] |= row_bit;

                var score: i32 = undefined;
                if (q.bytes.len >= 7 and q.bytes.len <= 1000 and stage_len == top_k) {
                    self.prepareLastPositions(&q, entry, entry_index);
                    const tightened = self.gapAwareUpperPrepared(&q, self.bonus_caps[entry_index]);
                    if (tightened < self.stage[0].score) continue;
                    score = self.scoreV2GeneralFromFirst(&q, entry, null, true);
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

        var h1_prev: i16 = 0;
        var in_gap1 = false;
        var max_score: i16 = 0;

        var j = first0;
        while (j <= last_col) : (j += 1) {
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

            if (j >= first1) {
                const left: i16 = if (j == first1) 0 else h1_prev;
                const gap_score: i16 = left + (if (in_gap1) gap_extension else gap_start);
                var match_value: i16 = 0;

                if (c == p1 and j > first0) {
                    const raw_bonus: i16 = @intCast(bonus[j]);
                    match_value = h0_prev + match_score;
                    var b = raw_bonus;
                    const consecutive = c0_prev + 1;
                    if (consecutive > 1) {
                        if (b >= boundary and b > b_prev) {
                            // Chunk is broken at the stronger boundary. The
                            // consecutive count itself is not needed because
                            // this is the final row.
                        } else {
                            b = @max(b, @max(consecutive_bonus, b_prev));
                        }
                    }
                    if (match_value + b < gap_score) {
                        match_value += raw_bonus;
                    } else {
                        match_value += b;
                    }
                }

                in_gap1 = match_value < gap_score;
                h1_prev = @max(@max(match_value, gap_score), 0);
                max_score = @max(max_score, h1_prev);
            }

            h0_prev = h0_cur;
            c0_prev = c0_cur;
        }

        return @intCast(max_score);
    }

    fn scoreV2TwoIndexed(self: *const Index, q: *const Query, entry: Entry, entry_index: usize) i32 {
        const text = self.candidateLower(entry);
        const bonus = self.candidateBonuses(entry);
        const first0 = self.position_scratch[0];
        const first1 = self.position_scratch[1];
        const last_col = blk: {
            const class: usize = @intCast(signatureClass(q.bytes[1]));
            if (class < exact_signature_classes and entry.len < std.math.maxInt(u16)) {
                const slot = self.last_slot_for_class[class];
                if (slot != 0xff) {
                    const stored = self.last_positions[@as(usize, slot) * self.entries.len + entry_index];
                    if (stored != std.math.maxInt(u16)) break :blk @as(usize, stored);
                }
            }
            break :blk std.mem.findScalarLast(u8, text, q.bytes[1]).?;
        };

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

        var h1_prev: i16 = 0;
        var in_gap1 = false;
        var max_score: i16 = 0;

        var j = first0;
        while (j <= last_col) : (j += 1) {
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

            if (j >= first1) {
                const left: i16 = if (j == first1) 0 else h1_prev;
                const gap_score: i16 = left + (if (in_gap1) gap_extension else gap_start);
                var match_value: i16 = 0;

                if (c == p1 and j > first0) {
                    const raw_bonus: i16 = @intCast(bonus[j]);
                    match_value = h0_prev + match_score;
                    var b = raw_bonus;
                    const consecutive = c0_prev + 1;
                    if (consecutive > 1) {
                        if (b >= boundary and b > b_prev) {
                            // Chunk is broken at the stronger boundary. The
                            // consecutive count itself is not needed because
                            // this is the final row.
                        } else {
                            b = @max(b, @max(consecutive_bonus, b_prev));
                        }
                    }
                    if (match_value + b < gap_score) {
                        match_value += raw_bonus;
                    } else {
                        match_value += b;
                    }
                }

                in_gap1 = match_value < gap_score;
                h1_prev = @max(@max(match_value, gap_score), 0);
                max_score = @max(max_score, h1_prev);
            }

            h0_prev = h0_cur;
            c0_prev = c0_cur;
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
        while (reverse_pattern != 0) {
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

    /// General exact score-only fzf V2 DP. Kept separate from the small-query
    /// kernels both as the 7+ byte production path and as a parity reference.
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

    fn gapAwareUpperPrepared(self: *const Index, q: *const Query, caps: BonusCaps) i32 {
        var prefix_bonus = bonusCap(caps, q.classes[0]);
        var upper = score_match + prefix_bonus * bonus_first_char_multiplier;
        for (1..q.bytes.len) |i| {
            const latest_previous = self.last_position_scratch[i - 1];
            const earliest_current = self.position_scratch[i];
            if (latest_previous + 1 < earliest_current) {
                const gap = earliest_current - latest_previous - 1;
                const penalty = score_gap_start + @as(i32, @intCast(gap - 1)) * score_gap_extension;
                upper = @max(0, upper + penalty);
            }
            prefix_bonus = @max(prefix_bonus, bonusCap(caps, q.classes[i]));
            upper += score_match + @max(prefix_bonus, bonus_consecutive);
        }
        return upper;
    }

    fn indexedLastPosition(self: *const Index, entry: Entry, entry_index: usize, class_value: u6) ?usize {
        if (entry.len >= std.math.maxInt(u16)) return null;
        const class: usize = @intCast(class_value);
        if (class >= exact_signature_classes) return null;
        const slot = self.last_slot_for_class[class];
        if (slot == 0xff) return null;
        const stored = self.last_positions[@as(usize, slot) * self.entries.len + entry_index];
        return if (stored == std.math.maxInt(u16)) null else @as(usize, stored);
    }

    fn scoreV2IndexedFromFirst(self: *Index, q: *const Query, entry: Entry, entry_index: usize) i32 {
        if (q.bytes.len == 1) return self.scoreV2Single(q, entry).?;
        if (q.bytes.len == 2) return self.scoreV2TwoIndexed(q, entry, entry_index);
        const last_hint = self.indexedLastPosition(entry, entry_index, q.classes[q.classes.len - 1]);
        return switch (q.bytes.len) {
            3 => self.scoreV2SmallFromFirst(3, q, entry, last_hint),
            4 => self.scoreV2SmallFromFirst(4, q, entry, last_hint),
            5 => self.scoreV2SmallFromFirst(5, q, entry, last_hint),
            6 => self.scoreV2SmallFromFirst(6, q, entry, last_hint),
            else => self.scoreV2GeneralFromFirst(q, entry, last_hint, false),
        };
    }

    fn scoreV2FromFirst(self: *Index, q: *const Query, entry: Entry) i32 {
        return switch (q.bytes.len) {
            3 => self.scoreV2SmallFromFirst(3, q, entry, null),
            4 => self.scoreV2SmallFromFirst(4, q, entry, null),
            5 => self.scoreV2SmallFromFirst(5, q, entry, null),
            6 => self.scoreV2SmallFromFirst(6, q, entry, null),
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
