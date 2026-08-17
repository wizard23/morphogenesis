const std = @import("std");

// Simplified Generational Arena using only dense arrays
// Provides O(1) spawn/destroy with handle-based safety

pub const Generation = u16;
pub const Index = u16;

pub fn GenerationalArena(comptime T: type, comptime capacity: u32) type {
    return struct {
        const Self = @This();

        pub const Handle = packed struct {
            index: Index,
            generation: Generation,

            const HandleSelf = @This();

            pub fn invalid() HandleSelf {
                return HandleSelf{ .index = 0xFFFF, .generation = 0xFFFF };
            }

            pub fn isValid(self: HandleSelf) bool {
                return self.index != 0xFFFF and self.generation != 0xFFFF;
            }

            pub fn eql(self: HandleSelf, other: HandleSelf) bool {
                return self.index == other.index and self.generation == other.generation;
            }
        };

        const Entry = struct {
            data: T,
            handle: Handle,
        };

        // Dense storage only
        entries: [capacity]Entry,
        count: u32,
        
        // Mapping from handle index to dense index
        sparse_to_dense: [capacity]u32,
        generations: [capacity]Generation,
        
        // Free list
        free_indices: [capacity]u16,
        free_count: u32,

        /// (Re)initialise in place. By-value construction of a ~0.5 MB struct materialised a template
        /// in the wasm data segment and copied it through the stack (measured 2026-08-17).
        pub fn init(self: *Self) void {
            self.count = 0;
            self.free_count = capacity;
            for (0..capacity) |i| {
                self.free_indices[i] = @intCast(i);
                self.sparse_to_dense[i] = 0xFFFFFFFF;
                self.generations[i] = 0;
            }
        }

        pub fn spawn(self: *Self, data: T) Handle {
            if (self.free_count == 0) {
                return Handle.invalid();
            }

            // Get next free slot
            self.free_count -= 1;
            const sparse_index = self.free_indices[self.free_count];
            
            // Increment generation
            self.generations[sparse_index] += 1;
            
            // Add to dense array
            const dense_index = self.count;
            self.entries[dense_index] = Entry{
                .data = data,
                .handle = Handle{
                    .index = sparse_index,
                    .generation = self.generations[sparse_index],
                },
            };
            
            // Update mapping
            self.sparse_to_dense[sparse_index] = dense_index;
            self.count += 1;

            return self.entries[dense_index].handle;
        }

        pub fn destroy(self: *Self, handle: Handle) void {
            if (!handle.isValid()) return;
            if (handle.index >= capacity) return;
            if (self.generations[handle.index] != handle.generation) return;
            
            const dense_index = self.sparse_to_dense[handle.index];
            if (dense_index >= self.count) return;
            
            // Swap with last element
            const last_index = self.count - 1;
            if (dense_index != last_index) {
                self.entries[dense_index] = self.entries[last_index];
                // Update mapping for swapped element
                self.sparse_to_dense[self.entries[dense_index].handle.index] = dense_index;
            }
            
            self.count -= 1;
            
            // Clear mapping and add to free list
            self.sparse_to_dense[handle.index] = 0xFFFFFFFF;
            self.free_indices[self.free_count] = handle.index;
            self.free_count += 1;
        }

        pub fn get(self: *const Self, handle: Handle) ?*const T {
            if (!handle.isValid()) return null;
            if (handle.index >= capacity) return null;
            if (self.generations[handle.index] != handle.generation) return null;
            
            const dense_index = self.sparse_to_dense[handle.index];
            if (dense_index >= self.count) return null;
            
            return &self.entries[dense_index].data;
        }

        pub fn getMut(self: *Self, handle: Handle) ?*T {
            if (!handle.isValid()) return null;
            if (handle.index >= capacity) return null;
            if (self.generations[handle.index] != handle.generation) return null;
            
            const dense_index = self.sparse_to_dense[handle.index];
            if (dense_index >= self.count) return null;
            
            return &self.entries[dense_index].data;
        }

        pub fn getDenseIndex(self: *const Self, handle: Handle) ?u32 {
            if (!handle.isValid()) return null;
            if (handle.index >= capacity) return null;
            if (self.generations[handle.index] != handle.generation) return null;
            
            const dense_index = self.sparse_to_dense[handle.index];
            if (dense_index >= self.count) return null;
            
            return dense_index;
        }

        pub fn getDataAt(self: *Self, index: u32) *T {
            return &self.entries[index].data;
        }

        pub fn getHandleAt(self: *const Self, index: u32) Handle {
            return self.entries[index].handle;
        }

        pub fn getAliveCount(self: *const Self) u32 {
            return self.count;
        }

        pub fn getDenseCount(self: *const Self) u32 {
            return self.count;
        }

        // Iterator for dense data
        pub fn forEachDense(self: *const Self, func: *const fn (Handle, *const T) void) void {
            for (0..self.count) |i| {
                func(self.entries[i].handle, &self.entries[i].data);
            }
        }
    };
}