# Hybrid feasibility probe

The probe links the pinned C oracle to:

- a stateless SQL scalar callback implemented in Zig;
- a C-layout VFS adapter whose randomness method and state are implemented in Zig.

It deliberately uses a public, versioned boundary. It does not approve private pager/B-tree/VDBE layouts.
