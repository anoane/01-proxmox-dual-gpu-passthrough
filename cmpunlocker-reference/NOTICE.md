# Third-party content

The files in this directory are **not ours**. They are a small excerpt of
[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker), pinned at commit `76f0954`,
included only so the mechanism described in the top-level README can be followed.

They remain under cmpunlocker's own licence (`LICENSE` in this directory). Credit belongs to
that project's authors (`CREDITS.md`).

The vendored NVIDIA `open-gpu-kernel-modules` source tree that cmpunlocker patches is
deliberately **not** included here — clone the upstream project and run its `install.sh`.
Only `driver/VERSION` and `driver/build.sh` are kept, to pin which driver version is targeted.
