pub const Source = enum {
    process,
    agent,
    human,
    system,

    pub fn name(self: Source) []const u8 {
        return @tagName(self);
    }
};
