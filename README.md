# hands-on-metal

Notes for understanding how Halium/libhybris exposes Android hardware interfaces without exposing vendor-private implementation details.

## What decompiling `libhybris.so` shows

### 1) Import/Export symbols (linker map)
- You can see references to Android-side symbols (for example mangled C++ names such as `GraphicBuffer` constructors).
- You can also see the Linux-side wrapper/thunk functions that call them.
- This reveals *which* Android binary APIs are being bridged.

### 2) Thunk/packing logic (data formatting)
- Decompiled thunks show memory allocation and field writes before dispatch.
- Offset patterns (for example writes at `+4`, `+8`, `+12`) help reconstruct expected struct layout.
- This is where the bridge’s call-shape knowledge is visible.

### 3) `ioctl` command constants
- Low-level bridge paths may include hard-coded constants passed to `ioctl`.
- Example pattern: `ioctl(fd, 0xc0186401, buffer)`.
- Those constants identify kernel interface commands that can be reused when building compatible userspace/driver glue.

## Why source is usually better than pure decompilation

- Decompiled output is often stripped (generic names like `var_1`, `dword_450`).
- Halium/libhybris is open source, so matching your binary version to source gives clearer variable names, comments, and intent.

## Practical workflow

1. Trace runtime behavior under Halium (for example with `ltrace`/`strace`) to capture actual calls.
2. Match observed calls to the corresponding libhybris source paths.
3. Reimplement compatible logic (same command numbers and data structure layout) in your own namespaced bridge/driver.

## Bottom line

Decompilation shows the **how** of the glue layer; live tracing and source comparison are usually the fastest path to the concrete **what** (real values, layout expectations, and call sequencing), especially for complex paths like GPU command submission.
