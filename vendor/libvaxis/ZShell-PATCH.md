# zshell libvaxis patch

This tree is vendored from libvaxis commit `6cab03f8a3faeb58bddf334343889a7f685ba7a7`.

`src/Loop.zig` is patched to keep `SIGWINCH` handling async-signal-safe. Upstream's
signal callback posts directly into the event queue. The queue uses an `std.Io.Mutex`,
so a resize signal that interrupts a thread while that mutex is held can panic with
`Deadlock detected`. This is reproducible while rapidly resizing a terminal window
and is tracked upstream in rockorager/libvaxis#234.

The local patch moves SIGWINCH ownership from `Tty` into `Loop` and uses a POSIX
self-pipe. The signal handler only atomically coalesces resize notifications and writes
one byte to the pipe. The normal TTY input task reads the pipe, obtains the new terminal
size, and posts the resize event outside signal context. This avoids both mutexes in the
old path (`tty.zig`'s handler registry mutex and the event queue mutex). The same pipe
wakes the input task during shutdown.

A second resize guard in `src/vxfw/App.zig` avoids division by zero when a
terminal transiently reports zero rows or columns during a resize.
