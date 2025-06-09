# Building RubyFPV on Raspberry Pi 4

These instructions guide you through compiling the RubyFPV software and, if needed, installing the RTL88XXAU Wi‑Fi driver on a Raspberry Pi&nbsp;4 running Raspberry&nbsp;Pi OS.

## 1. Install build dependencies

Update your package list and install the tools required for compilation:

```bash
sudo apt update
sudo apt install -y git build-essential wiringpi raspberrypi-kernel-headers
```

## 2. Clone the source code

Download the RubyFPV repository and switch to its directory:

```bash
git clone https://github.com/Kfro89/RubyFPV.git
cd RubyFPV
```

## 3. Compile RubyFPV

Simply invoke `make`. The default build environment targets Raspberry&nbsp;Pi hardware.

```bash
make
```

Compilation creates a number of binaries such as `ruby_central` and `ruby_rt_vehicle` in the repository root.

## 4. (Optional) Install RTL88XXAU driver

If your radio hardware uses the RTL88XXAU Wi‑Fi chipset, run the provided helper script to compile and install the driver for your current kernel:

```bash
sudo scripts/install_rtw8814au_driver.sh
```

The script checks for additional build requirements, downloads the driver source, and installs the modules.

---
You have now built RubyFPV on your Raspberry&nbsp;Pi&nbsp;4. Refer to [README.md](README.md) and the RubyFPV website for usage details and additional documentation.
