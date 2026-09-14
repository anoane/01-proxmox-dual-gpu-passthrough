# Debugging

Before you go asking in the Discord for help, here is a FAQ you should take a look at:

---

## "nvidia-smi: command not found"

- The installer likely didn't run or even failed. Re-run `sudo ./install.sh` and cold reboot.

---

## nvidia-smi shows 8192 or 10240 MiB (not 65536 or 40960)

- All the PLMs must show `0xffffffff`. Run `sudo dmesg | grep SEC2_DEBUG`to confirm.

- If this still persists, refer to the Discord protocol at the end of the document.

---

## PCIe still at Gen1 after install

- Confirm IOMMU passthrough mode is enabled. Depending on your operating system, enabling IOMMU passthrough can vary.

- If this still persists, refer to the Discord protocol at the end of the document.

---

## Discord protocol

If you have tried the above steps and are still having issues, please follow these steps to get help in the [Discord community](https://discord.gg/CdHSakKSFv):

1. Open a ticket in the #issue-support channel.

2. Provide the following information in your ticket:
   - Your operating system and version
   - Your GPU model and driver version
   - The output of `sudo dmesg | grep SEC2_DEBUG`
   - Latest install log (if applicable)

