# RTX PRO 6000 + CMP 170HX passthrough on Proxmox

Two very different NVIDIA cards passed through to one Ubuntu guest: a **RTX PRO 6000 Blackwell
Workstation** (96 GB, `sm_120`, `10de:2bb1`) and a **CMP 170HX** mining card (`10de:20c2`, GA100)
unlocked from 8 GB to **64 GB** of usable VRAM.

Everything here is transcribed from a running host, not written from memory. Where the machine
disagrees with older documentation, the machine wins and the stale version is kept in `docs/`
marked superseded.

---

### Hardware this was built and measured on

| | |
|---|---|
| Host | Proxmox VE 9.2.x, kernel 7.0.x-pve, Secure Boot **disabled** |
| CPU | AMD Ryzen 9 9950X3D (16C/32T) — 24 vCPU passed to the guest |
| RAM | 160 GiB DDR5 allocated to the guest (157 GiB usable) — **no swap, deliberately** |
| GPU 0 | NVIDIA RTX PRO 6000 Blackwell Workstation — 97,887 MiB, `sm_120`, `10de:2bb1`, PCIe Gen5 x16 (~42 GB/s H2D measured), 400 W default limit / 600 W max |
| GPU 1 | NVIDIA CMP 170HX — 65,536 MiB **after unlock** (8 GB stock), `sm_80` (GA100), `10de:20c2`, PCIe **Gen2 x1 (~0.38 GB/s)**, 200 W default limit / 250 W max |
| Guest | Ubuntu 24.04.4 LTS, kernel 6.8.0-139-generic, NVIDIA driver 610.43.02 |
| Storage | 5.8 TB NVMe (~93 GB free with all packs resident) |

**This repo covers the host side for both cards** — passthrough, the CMP unlock, GSP restore
and PCIe link training. The four model recipes (repos 02-05) all run inside the guest above.

> **This is a point-in-time recipe and may be slightly outdated or incomplete.**
> It was transcribed from a working system rather than written as a clean-room guide: driver,
> engine and image versions move quickly, some steps that were obvious in the moment are
> under-documented, and a few numbers were measured once rather than averaged. Every measured
> figure below is specific to the hardware in the table above — on a different PCIe topology,
> a different RAM size, or a card without the CMP's x1 bottleneck, the tuning will differ.
> Read it as a worked example with its reasoning shown, not as a turnkey script.

## What actually makes this work

Four things, in order of how much time they cost to discover:

1. **The CMP needs its GSP boot registers restored on every VM start**, not just the first.
2. **The unlock is a patched open-source kernel module**, not a VBIOS flash.
3. **The CMP negotiates PCIe Gen1 x1 at boot** and has to be hammered up to Gen2.
4. **Secure Boot must be off**, because the patched module is self-signed at best.

---

## 1. Host prerequisites

```
Proxmox VE 9.2.x · kernel 7.0.x-pve · AMD Ryzen 9950X3D
SecureBoot: disabled          # mokutil --sb-state
```

`host/grub.cmdline` — IOMMU on, passthrough mode:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```

`host/modules` — vfio loaded early:

```
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
```

`host/modprobe.d/` — four files that matter:

| file | why |
|---|---|
| `blacklist-gpu-host.conf` | keeps `nouveau`/`nvidia`/`nvidiafb`/`snd_hda_intel` off both cards so vfio can claim them |
| `cmpunlocker-vfio.conf` | `options vfio-pci disable_idle_d3=1` — the CMP misbehaves if the host idles it into D3 |
| `cmp-pcie-gen2.conf` | `options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"` — for when the driver *does* own the card |
| `vfio.conf` | vfio-pci device binding |

### IOMMU grouping — check this before buying anything

```
01:00.0 + 01:00.1  -> group 13   (GPU + its HDMI audio function)
04:04.0 + 06:00.0  -> group 17   (a PCIe bridge shares the CMP's group)
```

The CMP is **not** alone in its group. That is fine here because the co-resident device is a
bridge, but it means you pass the whole group's function set and cannot split it.

---

## 2. The VM definition

`vm/ai-vm.conf` (sanitized). The passthrough-relevant lines:

```
machine: q35            # required for PCIe passthrough
bios: seabios
cpu: host
numa: 1
balloon: 0              # ballooning + passthrough do not mix
hostpci0: 0000:01:00,pcie=1,rombar=0     # whole function group: GPU + audio
hostpci1: 0000:06:00.0,pcie=1,rombar=0   # CMP, single function
hookscript: local:snippets/cmp-gsp-restore.sh
memory: 163840
cores: 24
onboot: 1
```

Two details worth copying:

- **`hostpci0: 0000:01:00`** with no function suffix passes the *entire* device, picking up
  `01:00.1` (audio) automatically — matching IOMMU group 13.
- **`rombar=0`** on both. The guest driver initialises these cards without the option ROM.

The file retains a `pre-gpu-passthrough` snapshot showing the starting point (`machine: pc`,
less RAM) — useful if you need to roll back.

---

## 3. The CMP unlock

The unlock is **[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)**, pinned here at
commit `76f0954`. This repo does **not** vendor it — `cmpunlocker-reference/` holds only the
handful of files needed to understand the mechanism, under that project's own licence.

It builds **patched NVIDIA open-gpu-kernel-modules** (`cmpunlocker-reference/build.sh`) against a
pinned driver version — `VERSION` lists `610.57.04 / 610.43.03 / 610.43.02`; this host runs
**610.43.02** in the guest.

The unlock profile lives in `cmpunlocker-reference/common/constants.yaml`:

```yaml
"8gb":
  stock_mib: 8192
  unlocked_mib: 65536        # 8 GB -> 64 GB
  cfg1: "0x02779000"
  lmr:  "0x0000020B"
  fb_bytes: "0x0000001000000000"
  geometry_rewrite: true
```

Variants exist for the 10 GB (`0x2082`, -> 40 GB) and ES boards. `tools/detect-variant.py`
picks the right one.

---

## 4. The GSP restore hookscript — the non-obvious part

`host/hookscript/cmp-gsp-restore.sh` runs at **pre-start** for the VM. It exists because of
three behaviours that are individually reasonable and collectively lethal:

- The vfio-pci **bind udev event fires only on an actual driver change**. On the second and
  subsequent VM starts the card is already bound, no event fires, GSP restore never runs, and
  the guest reports **"WPR2 already up"**.
- After an **ungraceful VM stop**, `bsi_secure_scratch_14` latches **write-protected**. Only
  `cmpunlocker/tools/passthrough.sh restore <bdf>` clears it. Until you do, the next VM gets
  no GPU at all.
- Writing those registers **while the host nvidia driver owns the card clobbers a live GSP** —
  so the script checks the bound driver and skips anything not on `vfio-pci`.

`tools/gsp-restore.py` does the work: mmap BAR0 (`/sys/bus/pci/devices/<bdf>/resource0`,
`0x1000000` bytes) and rewrite the GSP boot-state registers listed in `gsp-regs.conf`.

Healthy log lines look like this — "already clean" is the normal case, not a warning:

```
cmpunlocker: 0000:06:00.0 GSP boot state already clean
2026-..-..T..:..:.. 0000:06:00.0 restored
```

---

## 5. PCIe link training

The CMP comes up at **Gen1 x1** and must be retrained. `host/gen2-hammer` walks the upstream
bridge writing `CAP_EXP+30.w` / `CAP_EXP+10.w` in a loop until the link reports Gen2, guarded by
vendor/device id so it can never touch the wrong card. It is env-tunable:

```
CMP170HX_GEN2_TARGET=2  CMP170HX_GEN2_MAX_ITERATIONS=600  CMP170HX_GEN2_RETRAIN_INTERVAL=0.05
```

`host/systemd/gen2.service` runs it **before `basic.target`**, early enough that the card is
trained before anything claims it.

### Read link state under load, never at idle

```
01:00.0  LnkSta: Speed 2.5GT/s (downgraded), Width x16
06:00.0  LnkSta: Speed 5GT/s,  Width x1 (downgraded)
```

Both look alarming and both are **idle downtraining**. Measured under real traffic this host
sustains ~42 GB/s H2D on the Blackwell. The CMP genuinely is x1 — about 0.38 GB/s — which is
the single most important number if you plan to put a model on it.

> **Design consequence.** At x1, sending *weights* to the CMP is hopeless, but sending
> *activations* is nearly free (~10 KiB per token per layer). Any workload split across these
> two cards should move activations over the slow link and keep weights resident.

`docs/superseded-gen2-sync-hammer.ru.md` is an earlier Russian-language writeup of a
`gen2-sync-hammer.sh` + per-VM hookscript approach. **That script does not exist on this host**
and no `gen2-sync*.log` was ever produced — it was replaced by `gen2-hammer` + `gen2.service`.
Kept for context only.

---

## 6. Guest side

Ubuntu 24.04, stock NVIDIA driver **610.43.02**, `nvidia-persistenced` enabled. No patched
driver is needed *in the guest* — the unlock lives entirely on the host. The guest simply sees:

```
RTX PRO 6000 Blackwell Workstation Edition   97,887 MiB   sm_120
CMP 170HX (reported as "NVIDIA Graphics Device")  65,536 MiB   sm_80
```

Note the CMP identifies itself with a generic name; match it by PCI id `10de:20c2`, not by name.

---

## Bring-up order

```bash
# host
mokutil --sb-state                      # must say disabled
# install grub cmdline + modprobe.d + /etc/modules, then:
update-initramfs -u && reboot

git clone https://github.com/amoghmunikote/cmpunlocker && cd cmpunlocker
git checkout 76f0954
sudo ./install.sh                       # builds the patched module, arms the cards
sudo ./tools/passthrough.sh status      # confirm both cards + clean GSP state

cp cmp-gsp-restore.sh /var/lib/vz/snippets/
qm set <VMID> --hookscript local:snippets/cmp-gsp-restore.sh
systemctl enable --now gen2.service

qm start <VMID>
```

## When it breaks

| symptom | cause | fix |
|---|---|---|
| guest: **"WPR2 already up"** | GSP restore did not re-run (no driver-change udev event) | the pre-start hookscript; verify `/var/log/cmp-gsp-restore.log` |
| next VM start gets **no GPU** | VM was killed, not shut down; ACR stamp latched write-protected | `passthrough.sh restore <bdf>` |
| CMP stuck at **Gen1** | retrain never ran or ran too late | `gen2.service` before `basic.target`; check `/var/log/gen2.log` |
| host driver grabs a card | blacklist incomplete | `host/modprobe.d/blacklist-gpu-host.conf`, then `update-initramfs -u` |
| card disappears after idle | D3 transition | `options vfio-pci disable_idle_d3=1` |

---

## Sanitization

Addresses use documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`),
domains are `example.invalid`, and keys/UUIDs/MACs are placeholders. Hardware models, PCI ids,
register values and sizes are real — they have to be, for any of this to be reproducible.
