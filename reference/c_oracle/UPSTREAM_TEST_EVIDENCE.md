# Upstream test evidence

## 2026-07-26 — AArch64 Linux development profile

- SQLite: 3.53.4 / `bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`
- Command: `zig build test-upstream`
- Permutation: `veryquick`, 2 isolated jobs
- Result: **329,824 tests, 0 errors**
- Platform: Fedora Linux AArch64, Btrfs, 16 KiB host pages
- C compiler: GCC 15.2.1
- Test interpreter: Tcl 8.6.16, bootstrapped into ignored `.reference-build/deps`
- Leak result: test jobs completed without reported SQLite allocator leaks

This is oracle validation only. It is not evidence that the native Zig database engine exists or passes SQLite tests.
