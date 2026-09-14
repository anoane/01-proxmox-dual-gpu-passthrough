#!/bin/bash
# pre-start: the vfio-pci "bind" udev event fires only on an actual driver change, so
# gsp-restore does not re-run on later VM starts and the guest then sees
# "WPR2 already up". Re-run it here -- but ONLY for cards already bound to vfio-pci.
# Writing these registers while the host nvidia driver owns the card would clobber a
# live GSP. After an ungraceful stop, bsi_secure_scratch_14 latches write-protected and
# only `cmpunlocker/tools/passthrough.sh restore <bdf>` clears it.
[ "$2" = "pre-start" ] || exit 0
LOG=/var/log/cmp-gsp-restore.log
for id in 20c2 2082; do
  for bdf in $(lspci -Dn -d 10de:$id 2>/dev/null | awk "{print \$1}"); do
    drv=$(basename "$(readlink -f /sys/bus/pci/devices/$bdf/driver 2>/dev/null)" 2>/dev/null)
    if [ "$drv" = "vfio-pci" ]; then
      /usr/local/lib/cmpunlocker/gsp-restore "$bdf" >>"$LOG" 2>&1 \
        && echo "$(date -Is) $bdf restored" >>"$LOG" || echo "$(date -Is) $bdf FAILED" >>"$LOG"
    else
      echo "$(date -Is) $bdf on driver '${drv:-none}' - skipped (not vfio-pci)" >>"$LOG"
    fi
  done
done
exit 0
