const std = @import("std");

fn Int(array: anytype) @Int(.unsigned, @bitSizeOf(@TypeOf(array))) {
  return @bitCast(array);
}

pub const CommonAll = struct {common: usize, a: usize, b: usize};

pub fn GetNGramExistence(n: comptime_int, static: bool, count_total: bool) type {
  const total_count = std.math.pow(usize, 256, n);
  return struct {
    set: if (static) std.bit_set.StaticBitSet(total_count) else std.hash_map.AutoHashMapUnmanaged([n]u8, void) = .empty,
    _total: if (static and count_total) usize else void = if (static and count_total) 0 else {},

    pub fn count(self: *@This()) usize {
      std.debug.assert(!static or count_total);
      if (static and !count_total) return 0;
      return if (static) self._total else self.set.count();
    }

    /// Add a value to the set
    pub fn add(self: *@This(), allocator: std.mem.Allocator, fragment: [n]u8) std.mem.Allocator.Error!void {
      switch (static) {
        true => {
          if (static and count_total) {
            if (self.set.isSet(Int(fragment))) { return; }
            self.set.set(Int(fragment));
            self._total += 1;
          } else {
            self.set.set(Int(fragment));
          }
        },
        false => try self.set.put(allocator, fragment, {}),
      }
    }

    /// Returns true if the fragment is in the set
    pub fn remove(self: *@This(), fragment: [n]u8) bool {
      switch (static) {
        true => {
          const isSet = self.set.isSet(Int(fragment));
          if (isSet) {
            if (static and count_total) { self._total -= 1; }
            self.set.unset(Int(fragment));
            return true;
          }
          return false;
        },
        false => return self.set.remove(fragment),
      }
    }

    /// Returns the number of fragments common to both strings
    pub fn getCommon(self: *@This(), allocator: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!usize {
      for (0..a.len + (n - 1)) |i| {
        try self.add(allocator, a[i..][0..n].*);
      }

      var common: usize = 0;

      for (0..b.len + (n - 1)) |i| {
        const fragment = b[i..][0..n].*;
        if (self.remove(fragment)) common += 1;
      }

      return common;
    }

    /// Returns the number of fragments common to both strings, and exclusive to each string
    pub fn getCommonAll(self: *@This(), allocator: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!CommonAll {
      for (0..a.len + (n - 1)) |i| {
        try self.add(allocator, a[i..][0..n].*);
      }

      var common: usize = 0;
      var selfclone = try self.dupe(allocator);
      defer selfclone.deinit(allocator);

      for (0..b.len + (n - 1)) |i| {
        const fragment = b[i..][0..n].*;
        if (self.remove(fragment)) {
          common += 1;
        } else {
          try selfclone.add(allocator, fragment);
        }
      }

      return .{
        .common = common,
        .a = self.count(),
        .b = selfclone.count() - self.count(),
      };
    }

    /// Clears the set
    pub fn clear(self: *@This()) void {
      switch (static) {
        true => self.set = .empty,
        false => self.set.clearRetainingCapacity(),
      }
    }

    /// Dupe this struct
    pub fn dupe(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
      return @This(){
        .set = switch (static) {
          true => self.set,
          false => try self.set.clone(allocator),
        },
        ._total = self._total,
      };
    }

    /// Deinitializes the set
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
      switch (static) {
        true => {}, // no-op
        false => self.set.deinit(allocator),
      }
    }
  };
}

test GetNGramExistence {
  std.testing.refAllDeclsRecursive(GetNGramExistence(2, true, true));
  std.testing.refAllDeclsRecursive(GetNGramExistence(2, true, false));
  std.testing.refAllDeclsRecursive(GetNGramExistence(2, false, true));
  std.testing.refAllDeclsRecursive(GetNGramExistence(2, false, false));
}

pub fn GetNGramFrequency(I: type, n: comptime_int, static: bool, count_total: bool) type {
  const total_count = std.math.pow(usize, 256, n);
  return struct {
    set: if (static) [total_count]I else std.hash_map.AutoHashMapUnmanaged([n]u8, I) = if (static) .{0} ** total_count else .empty,
    _total: if (static and count_total) usize else void = if (static and count_total) 0 else {},

    pub fn count(self: *@This()) usize {
      std.debug.assert(!static or count_total);
      if (static and !count_total) return 0;
      return if (static) self._total else self.set.count();
    }

    /// Add a value to the set
    pub fn add(self: *@This(), allocator: std.mem.Allocator, fragment: [n]u8) std.mem.Allocator.Error!void {
      if (static and count_total) self._total += 1;
      switch (static) {
        true => self.set[Int(fragment)] += 1,
        false => {
          const gpr = try self.set.getOrPut(allocator, fragment);
          if (gpr.found_existing) {
            gpr.value_ptr.* += 1;
          } else {
            gpr.value_ptr.* = 0;
          }
        },
      }
    }

    /// Decrements or removes a value from the set
    pub fn remove(self: *@This(), fragment: [n]u8) bool {
      switch (static) {
        true => {
          if (self.set[Int(fragment)] != 0) {
            if (static and count_total) self._total -= 1;
            self.set[Int(fragment)] -= 1;
            return true;
          } else {
            return false;
          }
        },
        false => {
          const ptr = self.set.getPtr(fragment);
          if (ptr) |gpr| {
            if (gpr.* == 0) {
              const removed = self.set.remove(fragment);
              std.debug.assert(removed);
            } else {
              gpr.* -= 1;
            }
            return true;
          } else {
            return false;
          }
        },
      }
    }

    /// Returns the number of fragments common to both strings
    pub fn getCommon(self: *@This(), allocator: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!usize {
      for (0..a.len + (n - 1)) |i| {
        try self.add(allocator, a[i..][0..n].*);
      }

      var common: usize = 0;

      for (0..b.len + (n - 1)) |i| {
        if (self.remove(b[i..][0..n].*)) { common += 1; }
      }

      return common;
    }

    /// Returns the number of fragments common to both strings, and exclusive to each string
    pub fn getCommonAll(self: *@This(), allocator: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!CommonAll {
      const common = try self.getCommon(allocator, a, b);

      return .{
        .common = common,
        .a = a.len - (n - 1) - common,
        .b = b.len - (n - 1) - common,
      };
    }

    /// Clears the set
    pub fn clear(self: *@This()) void {
      switch (static) {
        true => self.set = .{0} ** total_count,
        false => self.set.clearRetainingCapacity(),
      }
    }

    /// Dupe this struct
    pub fn dupe(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
      return @This(){
        .set = switch (static) {
          true => self.set,
          false => try self.set.clone(allocator),
        },
        ._total = self._total,
      };
    }

    /// Deinitializes the set
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
      switch (static) {
        true => {}, // no-op
        false => self.set.deinit(allocator),
      }
    }

  };
}

test GetNGramFrequency {
  std.testing.refAllDeclsRecursive(GetNGramFrequency(u32, 2, true, true));
  std.testing.refAllDeclsRecursive(GetNGramFrequency(u32, 2, true, false));
  std.testing.refAllDeclsRecursive(GetNGramFrequency(u32, 2, false, true));
  std.testing.refAllDeclsRecursive(GetNGramFrequency(u32, 2, false, false));
}

