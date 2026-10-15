# FauxPi

FauxPi is a Raspberry Pi hardware simulator written in Zig. It boots unmodified Raspberry Pi SD card images and kernels directly on your desktop, with an interactive board view for connecting and inspecting hardware peripherals at runtime.

![FauxPi running with the board sheet open](screenshot.png)

## Features

- **Supported Boards**:
  - Raspberry Pi 1 (Model A+, Model B+) — BCM2835 / ARM1176JZF-S
  - Raspberry Pi 3 (Model A+, Model B+) — BCM2837 / Cortex-A53 (ARMv7 & AArch64)
  - Raspberry Pi Zero, Zero W, and Zero 2 W
- **VideoCore IV Graphics**: Hardware Video Scaler (HVS), V3D 3D GPU, and HDMI display output.
- **Interactive Board Sheet**: Connect and disconnect power, HDMI, analog audio, USB devices (hub, keyboard, mouse), Ethernet, SD cards, and a 40-pin GPIO ribbon cable with live output LEDs and input switches.
- **Storage**: Copy-on-write QCOW2 SD card images with an integrated image library and Raspberry Pi OS downloader.
- **Networking & Audio**: Built-in user-mode NAT/DHCP networking over USB Ethernet and CYW43430 Wi-Fi, plus PWM, HDMI MAI, and VCHIQ audio output.

## Building and Running

Build and launch FauxPi using the included Zig wrapper script:

```sh
./scripts/zig build run
```

To boot directly from an SD card or disk image:

```sh
./scripts/zig build run -- --sd path/to/image.img
```

Run tests with:

```sh
./scripts/zig build test
```
