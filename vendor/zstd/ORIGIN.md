# Zstandard 1.5.7

Unmodified common/compress/decompress C sources and headers from:
https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz

Downloaded archive SHA256:
eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

The BSD 3-Clause licensing option in LICENSE is used. COPYING is retained
with the upstream dual-license notice. No legacy-format or dictionary-builder
C modules are built; BlackHole does not use them. ZSTD_MULTITHREAD is enabled;
ZSTD_DISABLE_ASM avoids assembler/toolchain differences on Windows.

Windows always compiles these C files into the program. On Linux, the system
library remains the default; `-fbundled-zstd` selects the bundled sources.
