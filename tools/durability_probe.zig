//! Independent bounded durability probe for rollback DELETE/FULL.
//! This is test infrastructure, not pager implementation code.

const std = @import("std");

const Value = enum(u8) { old, new };

const Event = enum {
    journal_write,
    journal_sync,
    database_write,
    database_sync,
    journal_delete,
};

const Store = struct {
    durable_database: Value = .old,
    volatile_database: ?Value = null,
    durable_journal: ?Value = null,
    volatile_journal: ?Value = null,

    fn apply(self: *Store, event: Event) void {
        switch (event) {
            .journal_write => self.volatile_journal = self.durable_database,
            .journal_sync => {
                if (self.volatile_journal) |value| {
                    self.durable_journal = value;
                    self.volatile_journal = null;
                }
            },
            .database_write => self.volatile_database = .new,
            .database_sync => {
                if (self.volatile_database) |value| {
                    self.durable_database = value;
                    self.volatile_database = null;
                }
            },
            .journal_delete => {
                self.durable_journal = null;
                self.volatile_journal = null;
            },
        }
    }

    fn crashAndRecover(self: *Store) void {
        self.volatile_database = null;
        self.volatile_journal = null;
        if (self.durable_journal) |original| {
            self.durable_database = original;
            self.durable_journal = null;
        }
    }
};

const correct_trace = [_]Event{
    .journal_write,
    .journal_sync,
    .database_write,
    .database_sync,
    .journal_delete,
};

fn recoveredAfterPrefix(trace: []const Event, prefix_len: usize) Value {
    var store = Store{};
    for (trace[0..prefix_len]) |event| store.apply(event);
    store.crashAndRecover();
    return store.durable_database;
}

test "every modeled pre-commit crash recovers old and commit recovers new" {
    for (0..correct_trace.len + 1) |prefix_len| {
        const recovered = recoveredAfterPrefix(&correct_trace, prefix_len);
        const expected: Value = if (prefix_len < correct_trace.len) .old else .new;
        try std.testing.expectEqual(expected, recovered);
    }
}

test "validator kills delete-before-database-sync mutant" {
    const mutant = [_]Event{
        .journal_write,
        .journal_sync,
        .database_write,
        .journal_delete,
    };
    const recovered = recoveredAfterPrefix(&mutant, mutant.len);
    try std.testing.expect(recovered != .new);
}

test "journal must be durable before database durability can advance" {
    const mutant = [_]Event{
        .journal_write,
        .database_write,
        .database_sync,
    };
    const recovered = recoveredAfterPrefix(&mutant, mutant.len);
    try std.testing.expect(recovered != .old);
}
