# Testing

Testing guidelines for ZViz.

## Running Tests

```bash
# Unit tests
zig build test

# Integration tests
zig build test-integration

# All tests
zig build test-all

# Security tests
sudo ./zig-out/bin/zviz escape-test
```

## Writing Tests

```zig
test "example" {
    const result = myFunction();
    try std.testing.expectEqual(expected, result);
}
```
