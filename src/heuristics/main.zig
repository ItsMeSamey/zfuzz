const std = @import("std");

pub const algorithms = struct {
  pub const custom = @import("algorithms/custom.zig");
  pub const jaro_similarity = @import("algorithms/jaro_similarity.zig");
  pub const lcs_length = @import("algorithms/lcs_length.zig");
  pub const levenshtein_distance = @import("algorithms/levenshtein_distance.zig");
  pub const n_gram = @import("algorithms/n_gram.zig");
};

pub const custom = algorithms.custom;
pub const jaro_similarity = algorithms.jaro_similarity;
pub const lcs_length = algorithms.lcs_length;
pub const levenshtein_distance = algorithms.levenshtein_distance;
pub const n_gram = algorithms.n_gram;

pub const SimilarityMeasure = @TypeOf(struct {
  fn inner(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
    _ = .{ I, F, a, b, allocator };
    return undefined;
  }
}.inner);

/// A similarity measure that calculates a "Frequency Distance" between two strings.
/// It attempts to quantify how "far apart" characters and their positions are across strings,
/// especially when character frequencies differ.
///
/// C=256 (alphabet size)
/// Time complexity: O(a + b + C * log2(max(a, b)))
/// Space complexity: O(a + b + C)
pub fn FrequencySimilarity(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
  return 1.0 - (try custom.FrequencyDistance(I, F, a, b, allocator));
}

/// Calculates the Jaro similarity between two strings.
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(a + b)
pub const JaroSimilarity: SimilarityMeasure = jaro_similarity.JaroSimilarity;

/// Returns a number between 0 and 1 that represents the percentage of the length of the longest common subsequence.
///
/// LCSPercentage = LCSLength(a, b) / min(len(a), len(b))
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(2 * min(a, b))
pub fn LCSPercentage(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
  const min_len = @min(a.len, b.len);
  if (min_len == 0) return if (a.len == b.len) 1.0 else 0.0;
  return @as(F, @floatFromInt(lcs_length.LCSLength(I, a, b, allocator))) / @as(F, @floatFromInt(min_len));
}

/// Calculates Levenshtein distance as a similarity measure.
///
/// LevenshteinDistancePercentage = 1 - LevenshteinDistance(a, b) / max(len(a), len(b))
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(2 * min(a, b))
pub fn LevenshteinSimilarityPercentage(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
  const max_len = @max(a.len, b.len);
  if (max_len == 0) return 1.0;
  return 1.0 - (@as(F, @floatFromInt(try levenshtein_distance.LevenshteinDistance(I, a, b, allocator))) / @as(F, @floatFromInt(max_len)));
}

/// Calculates the Optimal String Alignment (OSA) distance as a similarity measure.
///
/// OptimalStringAlignmentDistancePercentage = 1 - OptimalStringAlignmentDistance(a, b) / max(len(a), len(b))
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(3 * min(a, b))
pub fn LevenshteinOSASimilarityPercentage(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
  const max_len = @max(a.len, b.len);
  if (max_len == 0) return 1.0;
  return 1.0 - (@as(F, @floatFromInt(try levenshtein_distance.LevenshteinOSADistance(I, a, b, allocator))) / @as(F, @floatFromInt(max_len)));
}

/// Calculates the Damerau-Levenshtein distance as a similarity measure.
///
/// DamerauLevenshteinDistancePercentage = 1 - DamerauLevenshteinDistance(a, b) / max(len(a), len(b))
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(a * b)
pub fn LevenshteinDamerauSimilarityPercentage(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
  const max_len = @max(a.len, b.len);
  if (max_len == 0) return 1.0;
  return 1.0 - (@as(F, @floatFromInt(try levenshtein_distance.DamerauLevenshteinDistance(I, a, b, allocator))) / @as(F, @floatFromInt(max_len)));
}

/// Denotes the kind of "Gram" to use for Calculations
pub const GramKind = enum(u1) { Occurrence, Frequency };

/// Get Tversky Index
///
/// Time Complexity = O(a + b)
/// Space Complexity = O(a + b)
pub fn GetTverskyIndex(gram_count: comptime_int, gram_kind: GramKind, alpha: comptime_float, beta: comptime_float) SimilarityMeasure {
  return struct {
    fn inner(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
      const GramGetterFn = switch (gram_kind) {
        .Occurrence => n_gram.GetNGramExistence,
        .Frequency => n_gram.GetNGramFrequency,
      };

      const GramGetter = GramGetterFn(I, gram_count, switch (gram_kind) {
        .Occurrence => gram_count <= 2,
        .Frequency => gram_count <= 1,
      }, false);

      var gram: GramGetter = .{};
      defer gram.deinit(allocator);

      const result: n_gram.CommonAll = try gram.getCommonAll(allocator, a, b);
      return @as(F, @floatFromInt(result.common)) / ( @as(F, @floatFromInt(result.common)) + alpha * @as(F, @floatFromInt(result.a)) + beta * @as(F, @floatFromInt(result.b)) );
    }
  }.inner;
}

/// Jaccard Coefficient
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(a + b)
pub fn JaccardSimilarity(gram_count: comptime_int, gram_kind: GramKind) SimilarityMeasure {
  return GetTverskyIndex(gram_count, gram_kind, 1, 1);
}

/// Dice Coefficient
///
/// Time Complexity = O(a * b)
/// Space Complexity = O(a + b)
pub fn DiceSimilarity(gram_count: comptime_int, gram_kind: GramKind) SimilarityMeasure {
  return GetTverskyIndex(gram_count, gram_kind, 0.5, 0.5);
}

/// Wrapper function that gives priority to strings that match from the beginning.
///
/// prefix_l >= 1.0 brings values closer to 1 whereas prefix_l <= 0.0 brings values closer to 0.
/// if prefix_l is not in range [0.0, 1.0] output may not be in range either
pub fn WrapTrimStart(f: SimilarityMeasure, prefix_l: comptime_float, prefix_limit: comptime_int) SimilarityMeasure {
  return struct {
    fn inner(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
      const min_len = @min(a.len, b.len);
      if (min_len == 0) return f(I, F, a, b, allocator);

      var pre: usize = 0;
      while (pre < prefix_limit and pre < min_len and a[pre] == b[pre]) pre += 1;

      const out = try f(I, F, a[pre..], b[pre..], allocator);
      return (@as(F, @floatFromInt(pre)) * prefix_l + out * @as(F, @floatFromInt(min_len - pre))) / @as(F, @floatFromInt(min_len));
    }
  }.inner;
}

/// Wrapper function that gives priority to strings that match from the end.
///
/// suffix_l >= 1.0 brings values closer to 1 whereas suffix_l <= 0.0 brings values closer to 0.
/// if suffix_l is not in range [0.0, 1.0] output may not be in range either
pub fn WrapTrimEnd(f: SimilarityMeasure, suffix_l: comptime_float, suffix_limit: comptime_int) SimilarityMeasure {
  return struct {
    fn inner(comptime I: type, comptime F: type, a: []const u8, b: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
      const min_len = @min(a.len, b.len);
      if (min_len == 0) return f(I, F, a, b, allocator);

      var suf: usize = 0;
      while (suf < suffix_limit and suf < min_len and a[a.len - 1 - suf] == b[b.len - 1 - suf]) suf += 1;

      const out = try f(I, F, a[0 .. a.len - suf], b[0 .. b.len - suf], allocator);
      return (out * @as(F, @floatFromInt(min_len - suf)) + @as(F, @floatFromInt(suf)) * suffix_l) / @as(F, @floatFromInt(min_len));
    }
  }.inner;
}

/// Wrapper function that gives priority to strings that match from the beginning and/or the end.
///
/// prefix_l >= 1.0 brings values closer to 1 whereas prefix_l <= 0.0 brings values closer to 0.
/// suffix_l >= 1.0 brings values closer to 1 whereas suffix_l <= 0.0 brings values closer to 0.
/// if prefix_l or suffix_l is are in range [0.0, 1.0] output may not be in range either
pub fn WrapTrim(f: SimilarityMeasure, prefix_l: comptime_float, prefix_limit: comptime_int, suffix_l: comptime_float, suffix_limit: comptime_int) SimilarityMeasure {
  return struct {
    fn inner(comptime I: type, comptime F: type, a_: []const u8, b_: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!F {
      var a = a_;
      var b = b_;

      const min_len_original = @min(a.len, b.len);
      if (min_len_original == 0) return f(I, F, a, b, allocator);

      var pre: usize = 0;
      var suf: usize = 0;

      if (prefix_l > suffix_l) {
        while (pre < prefix_limit and pre < min_len_original and a[pre] == b[pre]) pre += 1;
        a = a[pre..];
        b = b[pre..];

        while (suf < suffix_limit and suf < min_len_original and a[a.len - 1 - suf] == b[b.len - 1 - suf]) suf += 1;
        a = a[0 .. a.len - suf];
        b = b[0 .. b.len - suf];
      } else {
        while (suf < suffix_limit and suf < min_len_original and a[a.len - 1 - suf] == b[b.len - 1 - suf]) suf += 1;
        a = a[0 .. a.len - suf];
        b = b[0 .. b.len - suf];

        while (pre < prefix_limit and pre < min_len_original and a[pre] == b[pre]) pre += 1;
        a = a[pre..];
        b = b[pre..];
      }

      const out = try f(I, F, a, b, allocator);
      return (
        out * @as(F, @floatFromInt(min_len_original - (pre + suf)))
        + @as(F, @floatFromInt(suf)) * suffix_l
        + @as(F, @floatFromInt(pre)) * prefix_l
      ) / @as(F, @floatFromInt(min_len_original));
    }
  }.inner;
}

test {
  std.testing.refAllDeclsRecursive(@This());
}

