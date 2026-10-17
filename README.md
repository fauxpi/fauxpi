# FauxPi

FauxPi is a Raspberry Pi hardware simulator application.

![FauxPi running with the board sheet open](screenshot.png)

## Features

- **Supported Boards**:
  - Raspberry Pi 1 (Model A+, Model B+)
  - Raspberry Pi 3 (Model A+, Model B+)
  - Raspberry Pi Zero, Zero W, and Zero 2 W
- **VideoCore IV Graphics**: Efficiently simulates accelerated video.
- **Interactive Board Sheet**: Connect and disconnect power, HDMI, analog audio, USB devices (hub, keyboard, mouse), Ethernet, SD cards, and a 40-pin GPIO ribbon cable with live output LEDs and input switches.
- **Storage**: Make multiple SD card images of different Raspberry Pi software.
- **Networking & Audio**: Simulates Ethernet and Wi-Fi and audio output from analog audio jack and across HDMI.

## Building and Running

Build and launch FauxPi using the included Zig wrapper script:

```sh
./scripts/zig build run
```
