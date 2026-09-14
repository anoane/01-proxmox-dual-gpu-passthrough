> **Third-party document — not written here.** This is cmpunlocker's own installation guide, taken from
> [amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) at commit `76f0954`
> and kept alongside this recipe for convenience. It remains under that project's licence (see
> `cmpunlocker-reference/LICENSE`). The commands below are run **inside a cmpunlocker checkout on the Proxmox host**, not in this repo.

---

# Installation

Here are the steps to install cmpunlocker on your system.

---

## Requirements

- NVIDIA CMP 170HX (8GB or 10GB)
- Linux operating system (Ubuntu, Debian, Fedora, etc.)
- Kernel headers matching the running kernel (linux-headers-$(uname -r) / kernel-devel)
- Python 3
- **nvidia-open 610.43.0x already installed** (libs + firmware)
- Root access to the system (sudo privileges)
- Secure Boot disabled
- Network access on first install (downloads matching stock open-gpu-kernel-modules sources)

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

To force a certain memory profile, use the `--profile` option:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

Then perform a cold reboot (full power off, then boot).

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./uninstall.sh --yes
```

Then perform a cold reboot (full power off, then boot).
