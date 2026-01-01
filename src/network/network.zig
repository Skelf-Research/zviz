const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const linux = @import("../syscalls/linux.zig");

/// Network policy mode
pub const Mode = enum {
    allow_all,
    deny_all,
    allow_cidr,
};

/// Network configuration from profile
pub const Config = struct {
    mode: Mode = .deny_all,
    allow_cidrs: []const Cidr = &.{},
    deny_cidrs: []const Cidr = &.{},
    allow_dns: bool = false,
};

/// CIDR representation
pub const Cidr = struct {
    address: [4]u8, // IPv4 for now
    prefix_len: u8,

    pub fn parse(s: []const u8) !Cidr {
        // Parse "10.0.0.0/8" format
        const slash_idx = std.mem.indexOf(u8, s, "/") orelse return error.InvalidFormat;
        const addr_part = s[0..slash_idx];
        const prefix_part = s[slash_idx + 1 ..];

        var address: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, addr_part, '.');
        var i: usize = 0;
        while (it.next()) |octet| : (i += 1) {
            if (i >= 4) return error.InvalidFormat;
            address[i] = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidFormat;
        }
        if (i != 4) return error.InvalidFormat;

        const prefix_len = std.fmt.parseInt(u8, prefix_part, 10) catch return error.InvalidFormat;
        if (prefix_len > 32) return error.InvalidFormat;

        return .{
            .address = address,
            .prefix_len = prefix_len,
        };
    }

    pub fn contains(self: Cidr, ip: [4]u8) bool {
        const mask = if (self.prefix_len == 0) @as(u32, 0) else ~(@as(u32, 0)) << @intCast(32 - self.prefix_len);
        const net_addr = (@as(u32, self.address[0]) << 24) |
            (@as(u32, self.address[1]) << 16) |
            (@as(u32, self.address[2]) << 8) |
            @as(u32, self.address[3]);
        const ip_addr = (@as(u32, ip[0]) << 24) |
            (@as(u32, ip[1]) << 16) |
            (@as(u32, ip[2]) << 8) |
            @as(u32, ip[3]);

        return (ip_addr & mask) == (net_addr & mask);
    }

    pub fn format(
        self: Cidr,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}.{d}.{d}.{d}/{d}", .{
            self.address[0],
            self.address[1],
            self.address[2],
            self.address[3],
            self.prefix_len,
        });
    }
};

/// Network interface configuration
pub const InterfaceConfig = struct {
    /// IP address for container side (e.g., "10.200.1.2/24")
    container_ip: ?[]const u8 = null,
    /// IP address for host side (e.g., "10.200.1.1/24")
    host_ip: ?[]const u8 = null,
    /// Default gateway (usually host_ip without prefix)
    gateway: ?[]const u8 = null,
    /// MTU (default 1500)
    mtu: u16 = 1500,
};

/// Network namespace manager
pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    container_id: []const u8,
    config: Config,
    interface_config: InterfaceConfig,
    veth_host: ?[]const u8 = null,
    veth_container: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, container_id: []const u8, config: Config) !NetworkManager {
        const id_copy = try allocator.dupe(u8, container_id);
        return .{
            .allocator = allocator,
            .container_id = id_copy,
            .config = config,
            .interface_config = .{},
        };
    }

    pub fn deinit(self: *NetworkManager) void {
        self.allocator.free(self.container_id);
        if (self.veth_host) |v| self.allocator.free(v);
        if (self.veth_container) |v| self.allocator.free(v);
    }

    /// Set up network namespace with veth pair
    pub fn setup(self: *NetworkManager, container_pid: i32) !void {
        log.info("Setting up network for container: {s}, pid: {d}", .{ self.container_id, container_pid });

        // Generate veth interface names (max 15 chars for Linux interface names)
        const id_short = if (self.container_id.len > 8) self.container_id[0..8] else self.container_id;
        self.veth_host = try std.fmt.allocPrint(self.allocator, "veth-{s}", .{id_short});
        self.veth_container = try std.fmt.allocPrint(self.allocator, "eth0", .{});

        // Note: In a real implementation, this would use netlink sockets.
        // For now, we document the setup steps.
        log.debug("Would create veth pair: {s} <-> {s}", .{ self.veth_host.?, self.veth_container.? });
        log.debug("Would move {s} to netns of pid {d}", .{ self.veth_container.?, container_pid });

        if (self.interface_config.container_ip) |ip| {
            log.debug("Would assign IP {s} to container interface", .{ip});
        }

        if (self.interface_config.gateway) |gw| {
            log.debug("Would set default gateway to {s}", .{gw});
        }
    }

    /// Create veth pair using netlink (stub for actual implementation)
    fn createVethPair(self: *NetworkManager) !void {
        _ = self;
        // In production, this would use NETLINK_ROUTE socket with RTM_NEWLINK
        // to create veth pair atomically.
        // For now, this is a placeholder.
    }

    /// Move interface to container network namespace
    fn moveToNetns(self: *NetworkManager, ifname: []const u8, pid: i32) !void {
        _ = self;
        _ = ifname;
        _ = pid;
        // Would use NETLINK_ROUTE with RTM_NEWLINK and IFLA_NET_NS_PID
    }

    /// Configure IP address on interface
    fn configureAddress(self: *NetworkManager, ifname: []const u8, ip: []const u8) !void {
        _ = self;
        _ = ifname;
        _ = ip;
        // Would use NETLINK_ROUTE with RTM_NEWADDR
    }

    /// Apply firewall rules (iptables/nftables)
    pub fn applyFirewallRules(self: *NetworkManager) !void {
        switch (self.config.mode) {
            .allow_all => {
                log.warn("Network policy: allow_all (not recommended)", .{});
            },
            .deny_all => {
                log.info("Network policy: deny_all", .{});
                try self.applyNftRules();
            },
            .allow_cidr => {
                log.info("Network policy: allow_cidr with {d} rules", .{self.config.allow_cidrs.len});
                try self.applyNftRules();
            },
        }
    }

    fn applyNftRules(self: *NetworkManager) !void {
        // Generate nftables rules
        const rules = try generateNftRules(self.allocator, self.config);
        defer self.allocator.free(rules);

        // In production, would write to nftables via nft command or netlink
        log.debug("Would apply nftables rules:\n{s}", .{rules});
    }

    /// Enable IP forwarding for the container bridge
    pub fn enableForwarding(self: *NetworkManager) !void {
        _ = self;
        // Write "1" to /proc/sys/net/ipv4/ip_forward
        const file = std.fs.openFileAbsolute("/proc/sys/net/ipv4/ip_forward", .{ .mode = .write_only }) catch |err| {
            log.warn("Could not enable IP forwarding: {any}", .{err});
            return;
        };
        defer file.close();
        file.writeAll("1") catch {};
    }

    /// Set up NAT for container egress (MASQUERADE)
    pub fn setupNat(self: *NetworkManager, bridge_cidr: []const u8) !void {
        log.debug("Would set up NAT for {s}", .{bridge_cidr});
        // In production: iptables -t nat -A POSTROUTING -s {bridge_cidr} -j MASQUERADE
        _ = self;
    }

    /// Clean up network resources
    pub fn cleanup(self: *NetworkManager) void {
        log.info("Cleaning up network for container: {s}", .{self.container_id});

        if (self.veth_host) |veth| {
            log.debug("Would delete veth: {s}", .{veth});
            // Deleting host side automatically deletes the pair
        }

        // Clean up nftables rules for this container
        log.debug("Would remove nftables table for container", .{});
    }

    /// Check if container has network connectivity
    pub fn checkConnectivity(self: *NetworkManager) bool {
        _ = self;
        // Could ping gateway or check interface state
        return true;
    }
};

/// Generate nftables rules from config
pub fn generateNftRules(allocator: std.mem.Allocator, config: Config) ![]u8 {
    // Estimate buffer size
    const estimated_size = 512 + config.allow_cidrs.len * 64;
    var buf = try allocator.alloc(u8, estimated_size);
    var pos: usize = 0;

    // Header
    const header =
        \\table inet zigviz {
        \\  chain output {
        \\    type filter hook output priority 0; policy drop;
        \\    oif lo accept
        \\    ct state established,related accept
        \\
    ;
    @memcpy(buf[pos..][0..header.len], header);
    pos += header.len;

    // Allow DNS if configured
    if (config.allow_dns) {
        const dns_rules =
            \\    udp dport 53 accept
            \\    tcp dport 53 accept
            \\
        ;
        @memcpy(buf[pos..][0..dns_rules.len], dns_rules);
        pos += dns_rules.len;
    }

    // Allow specified CIDRs
    for (config.allow_cidrs) |cidr| {
        const line = std.fmt.bufPrint(buf[pos..], "    ip daddr {d}.{d}.{d}.{d}/{d} accept\n", .{
            cidr.address[0],
            cidr.address[1],
            cidr.address[2],
            cidr.address[3],
            cidr.prefix_len,
        }) catch return error.OutOfMemory;
        pos += line.len;
    }

    // Footer
    const footer =
        \\  }
        \\}
        \\
    ;
    @memcpy(buf[pos..][0..footer.len], footer);
    pos += footer.len;

    return allocator.realloc(buf, pos);
}

test "parse cidr" {
    const cidr = try Cidr.parse("10.0.0.0/8");
    try std.testing.expectEqual(@as(u8, 10), cidr.address[0]);
    try std.testing.expectEqual(@as(u8, 8), cidr.prefix_len);
}

test "cidr contains" {
    const cidr = try Cidr.parse("10.0.0.0/8");
    try std.testing.expect(cidr.contains(.{ 10, 1, 2, 3 }));
    try std.testing.expect(!cidr.contains(.{ 192, 168, 1, 1 }));
}

test "generate nft rules" {
    const config = Config{
        .mode = .allow_cidr,
        .allow_cidrs = &.{
            Cidr{ .address = .{ 10, 0, 0, 0 }, .prefix_len = 8 },
        },
        .allow_dns = true,
    };

    const rules = try generateNftRules(std.testing.allocator, config);
    defer std.testing.allocator.free(rules);
    try std.testing.expect(std.mem.indexOf(u8, rules, "10.0.0.0/8") != null);
}
