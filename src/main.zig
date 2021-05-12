const std = @import("std");
const expect = std.testing.expect;

const MaxUsers = 16;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) expect(false); //fail
    }
    var state = State.init(&gpa.allocator);
    defer state.deinit();

    try state.apply_cmd(.{ .AddUser = "erik" });
    try state.apply_cmd(.{ .AddUser = "chris" });
    {
        var output = try state.to_html();
        defer output.deinit();
        std.log.info("First:\n{s}", .{output.items});
    }

    try state.apply_cmd(.{ .AddSlot = "May 8" });
    try state.apply_cmd(.{ .AddSlot = "May 15" });
    try state.apply_cmd(.{ .AddSlot = "May 22" });
    try state.apply_cmd(.{ .AddSlot = "May 29" });
    {
        var output = try state.to_table();
        defer output.deinit();
        std.log.info("With Slots:\n{s}", .{output.items});
    }
    try state.apply_cmd(.{ .RemoveSlot = "May 8" });
    {
        var output = try state.to_table();
        defer output.deinit();
        std.log.info("One Slot Removed:\n{s}", .{output.items});
    }
    try state.apply_cmd(.{ .UserWants = .{ .user = "chris", .slot = "May 15" } });
    try state.apply_cmd(.{ .UserWants = .{ .user = "chris", .slot = "May 29" } });
    try state.apply_cmd(.{ .UserHates = .{ .user = "erik", .slot = "May 29" } });
    try state.apply_cmd(.{ .UserHates = .{ .user = "erik", .slot = "May 22" } });
    {
        var output = try state.to_table();
        defer output.deinit();
        std.log.info("Preferences:\n{s}", .{output.items});
    }
    try state.apply_cmd(.{ .UserNeutral = .{ .user = "chris", .slot = "May 29" } });
    try state.apply_cmd(.{ .UserNeutral = .{ .user = "erik", .slot = "May 29" } });
    {
        var output = try state.to_table();
        defer output.deinit();
        std.log.info("Actually not bothered:\n{s}", .{output.items});
    }
    try state.apply_cmd(.{ .AssignSlot = .{ .slot = "May 15" } });
    try state.apply_cmd(.{ .AssignSlot = .{ .slot = "May 22" } });
    try state.apply_cmd(.{ .AssignSlot = .{ .slot = "May 29" } });
    {
        var output = try state.to_table();
        defer output.deinit();
        std.log.info("All assigned:\n{s}", .{output.items});
    }
    //TODO: view points
    //TODO: create a log reader/writer for commands
    //TODO: Generate actual html
    //TODO: include zhp or something (eventually do our own!)
}

const Command = union(enum) {
    AddUser: []const u8, // Add a new user to the system
    //DeleteUser: []const u8, // Delete a user by name

    AddSlot: []const u8, // Add a new slot (e.g. Saturday/week)
    RemoveSlot: []const u8, // Remove a slot

    UserWants: struct { user: []const u8, slot: []const u8 },
    UserNeutral: struct { user: []const u8, slot: []const u8 },
    UserHates: struct { user: []const u8, slot: []const u8 },

    AssignSlot: struct { slot: []const u8 },
    UnassignSlot: struct { slot: []const u8 },
};

const User = struct {
    name: []const u8,
    id: u8,
    score: f32 = 0,
};

fn scoreCmp(context: void, lhs: User, rhs: User) bool {
    return lhs.score < rhs.score;
}
fn naturalCmp(context: void, lhs: User, rhs: User) bool {
    return lhs.id < rhs.id;
}

const Slot = struct {
    name: []const u8,
    id: u32,
    assignedUsers: [MaxUsers]bool = [_]bool{false} ** MaxUsers, // bitmap of assignments
    wantUsers: [MaxUsers]bool = [_]bool{false} ** MaxUsers, // bitmap of wants
    hateUsers: [MaxUsers]bool = [_]bool{false} ** MaxUsers, // bitmap of not-wants
};

const StateMutationError = error{
    UserNotFound,
    SlotNotFound,
    SlotAlreadyExists,
    UserAlreadyExists,
    SlotAlreadyAssigned,
    SlotUnfillable,
};

pub const State = struct {
    allocator: *std.mem.Allocator,
    users: std.ArrayList(User),
    slots: std.ArrayList(Slot),
    slotCount: u32,
    const MaxAssigned: u8 = 1;

    pub fn init(allocator: *std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .users = std.ArrayList(User).init(allocator),
            .slots = std.ArrayList(Slot).init(allocator),
            .slotCount = 0,
        };
    }

    pub fn deinit(self: *State) void {
        self.users.deinit();
        self.slots.deinit();
    }

    pub fn to_html(self: *State) !std.ArrayList(u8) {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        for (self.users.items) |user| {
            try out.writer().print(
                "user: {s} ({})\n",
                .{ user.name, user.id },
            );
        }
        for (self.slots.items) |slot| {
            try out.writer().print(
                "slot: {s} ({})\n",
                .{ slot.name, slot.id },
            );
        }
        return out;
    }

    pub fn to_table(self: *State) !std.ArrayList(u8) {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        // Headers
        try out.appendSlice("Users\t|");
        for (self.slots.items) |slot| {
            try out.writer().print(
                "{s}\t|",
                .{slot.name},
            );
        }
        try out.append('\n');
        for (out.items) |_| {
            try out.append('-');
        }
        try out.append('\n');

        for (self.users.items) |user, i| {
            try out.writer().print(
                "{s}\t|",
                .{user.name},
            );
            for (self.slots.items) |slot| {
                try out.writer().print("{c}\t|", .{show_slot_idx(slot, i)});
            }
            try out.append('\n');
        }
        return out;
    }

    pub fn apply_cmd(self: *State, cmd: Command) !void {
        try switch (cmd) {
            .AddUser => |name| self.users.append(.{ .name = name, .id = @intCast(u8, self.users.items.len) }),
            .AddSlot => |name| {
                try self.slots.append(.{ .name = name, .id = self.slotCount });
                self.slotCount += 1;
            },
            .RemoveSlot => |name| {
                var idx = find_item(Slot, self.slots, name);
                if (idx) |index| {
                    _ = self.slots.orderedRemove(index);
                }
            },
            .UserWants => |want| {
                var uid = find_item(User, self.users, want.user) orelse return StateMutationError.UserNotFound;
                var sid = find_item(Slot, self.slots, want.slot) orelse return StateMutationError.SlotNotFound;
                self.slots.items[sid].wantUsers[uid] = true;
                self.slots.items[sid].hateUsers[uid] = false;
            },
            .UserNeutral => |neut| {
                var uid = find_item(User, self.users, neut.user) orelse return StateMutationError.UserNotFound;
                var sid = find_item(Slot, self.slots, neut.slot) orelse return StateMutationError.SlotNotFound;
                self.slots.items[sid].wantUsers[uid] = false;
                self.slots.items[sid].hateUsers[uid] = false;
            },
            .UserHates => |hate| {
                var uid = find_item(User, self.users, hate.user) orelse return StateMutationError.UserNotFound;
                var sid = find_item(Slot, self.slots, hate.slot) orelse return StateMutationError.SlotNotFound;
                self.slots.items[sid].wantUsers[uid] = false;
                self.slots.items[sid].hateUsers[uid] = true;
            },
            .AssignSlot => |info| {
                var sid = find_item(Slot, self.slots, info.slot) orelse return StateMutationError.SlotNotFound;
                var slot = &self.slots.items[sid];
                var curAssigned = popCount(slot.assignedUsers);
                if (curAssigned >= MaxAssigned) return StateMutationError.SlotAlreadyAssigned;

                // If anyone wants it assign it to the first user who said so
                var ouid: ?usize = assignment: {
                    for (slot.wantUsers) |b, i| {
                        if (b and !slot.assignedUsers[i]) {
                            slot.assignedUsers[i] = true;
                            break :assignment i;
                        }
                    }
                    break :assignment null;
                };
                // Otherwise assign it to the user with the lowest score who didn't hate it
                if (ouid == null) {
                    ouid = ass2: {
                        std.sort.sort(User, self.users.items, {}, scoreCmp);
                        for (self.users.items) |user| {
                            if (!slot.assignedUsers[user.id] and !slot.hateUsers[user.id]) {
                                slot.assignedUsers[user.id] = true;
                                break :ass2 user.id;
                            }
                        }
                        break :ass2 null;
                    };
                    std.sort.sort(User, self.users.items, {}, naturalCmp);
                }

                const uid = ouid orelse return StateMutationError.SlotUnfillable;
                // Give the assigned user a point
                const num_users = self.users.items.len;
                self.users.items[uid].score += 1 + (1 / @intToFloat(f32, num_users));
                // Remove 1/users points from everyone else
                for (self.users.items) |*user| {
                    user.*.score -= (1 / @intToFloat(f32, num_users));
                }
            },
            else => {},
        };
    }
    fn popCount(slice: anytype) usize {
        var x: usize = 0;
        for (slice) |b| {
            if (b) {
                x += 1;
            }
        }
        return x;
    }

    fn find_item(comptime T: type, list: std.ArrayList(T), name: []const u8) ?usize {
        var index: usize = 0;
        while (index < list.items.len and !std.mem.eql(u8, list.items[index].name, name)) {
            index += 1;
        }
        if (index < list.items.len) {
            return index;
        } else {
            return null;
        }
    }
    fn show_slot_idx(slot: Slot, idx: usize) u8 {
        const ass: bool = slot.assignedUsers[idx];
        const want: bool = slot.wantUsers[idx];
        const hate: bool = slot.hateUsers[idx];

        std.debug.assert(!(want and hate));

        if (ass) return 'A';
        if (want) return 'W';
        if (hate) return 'H';
        return ' ';
    }
};
