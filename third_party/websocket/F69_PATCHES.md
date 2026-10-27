Vendored copy of https://github.com/karlseguin/websocket.zig at f2b3bad6875595e8dd42c726e8e914885a8b0ba0 (MIT, see LICENSE).

Local patch: `src/client/client.zig` — the Windows read path called `Io.VTable.netRead`, which Zig 0.17
removed; it now calls `Io.net.Stream.readWithControl` (`Stream.read` is broken in 0.17.0). Drop this copy (and point build.zig.zon back at the upstream
URL) once upstream fixes Windows on Zig 0.17.
