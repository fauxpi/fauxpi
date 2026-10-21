# FauxPi

FauxPi is a Raspberry Pi hardware simulator application.

![FauxPi running with the board sheet open](screenshot.png)

## Features

- **Supported Boards**:
  - Raspberry Pi 1 A+ and B+
  - Raspberry Pi 3 A+ and B+
  - Raspberry Pi Zero, Zero W, and Zero 2 W
- **VideoCore IV Graphics**: Efficiently simulates accelerated video.
- **Interactive Board Sheet**: Connect and disconnect connectors like a read piece of hardware.
- **Storage**: Manager multiple SD card images.
- **Networking & Audio**: Ethernet, Wi-Fi and audio supported.

## Running

Launch FauxPi by running the included script. No dependencies required.

```sh
./scripts/zig build run
```

## Measuring boot time

`scripts/bench-boot` boots a Raspberry Pi OS image headless several times and reports how long it takes to reach each boot milestone, so performance changes can be compared:

```sh
./scripts/zig build
./scripts/bench-boot 2026-10-06-raspios-trixie-arm64-lite.img.xz --runs 3
```

The first run prepares the image (adding a small probe service and doing a warm-up boot for first-boot setup) and caches it under `build/bench/`. Arguments after `--` are passed to FauxPi, for example `-- --clock instructions`. It needs `python3`, `qemu-img`, `debugfs` (e2fsprogs), and `xz` for compressed images.
