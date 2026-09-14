
# Настройка синхронизированного ретрейна PCIe на хосте Proxmox

## Шаг 1: Создайте скрипт синхронизированного ретрейна

```bash
nano /usr/local/sbin/gen2-sync-hammer.sh
```

Вставьте:

```bash
#!/bin/bash
set -uo pipefail

readonly VENDOR_ID="10de"
readonly LOG_FILE="/var/log/gen2-sync.log"
readonly MAX_ITERATIONS=2000
readonly RETRAIN_INTERVAL=0.05
readonly TIMEOUT_SECONDS=120

# Атомарное логирование (echo >> файл атомарен для коротких строк)
log() {
    local line="[$(date -Is)] [$$] $*"
    echo "${line}" | tee -a "${LOG_FILE}"
}

read_link_status() {
    setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true
}

link_generation() {
    local status
    status="$(read_link_status "$1")"
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        echo $((0x${status} & 0x0f))
    else
        echo "?"
    fi
}

is_supported_gpu() {
    local bdf="$1"
    local vendor device
    [[ -r "/sys/bus/pci/devices/${bdf}/vendor" ]] || return 1
    [[ -r "/sys/bus/pci/devices/${bdf}/device" ]] || return 1
    vendor="$(<"/sys/bus/pci/devices/${bdf}/vendor")"
    device="$(<"/sys/bus/pci/devices/${bdf}/device")"
    [[ "${vendor,,}" == "0x${VENDOR_ID}" ]] || return 1
    [[ "${device,,}" == "0x20c2" || "${device,,}" == "0x2082" ]]
}

upstream_bridge() {
    local bdf="$1"
    local parent
    parent="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${bdf}")")")"
    [[ "${parent}" != "${bdf}" ]] || return 1
    [[ -e "/sys/bus/pci/devices/${parent}" ]] || return 1
    echo "${parent}"
}

is_pci_bridge() {
    local bdf="$1"
    local class
    [[ -r "/sys/bus/pci/devices/${bdf}/class" ]] || return 1
    class="$(<"/sys/bus/pci/devices/${bdf}/class")"
    [[ "${class,,}" == 0x0604* ]]
}

retrain_one() {
    local gpu="$1"
    local bridge status generation iteration start_time elapsed

    if ! is_supported_gpu "${gpu}"; then
        log "${gpu}: vendor/device guard failed; skipping"
        return 1
    fi
    
    bridge="$(upstream_bridge "${gpu}" || true)"
    if [[ -z "${bridge}" ]] || ! is_pci_bridge "${bridge}"; then
        log "${gpu}: no valid upstream PCI bridge found; skipping"
        return 1
    fi

    start_time=$(date +%s)
    log "${gpu}: start PARALLEL retrain via upstream ${bridge}; target Gen2; timeout ${TIMEOUT_SECONDS}s"
    
    for ((iteration = 1; iteration <= MAX_ITERATIONS; iteration++)); do
        elapsed=$(( $(date +%s) - start_time ))
        if (( elapsed >= TIMEOUT_SECONDS )); then
            generation="$(link_generation "${gpu}")"
            log "${gpu}: TIMEOUT after ${TIMEOUT_SECONDS}s; final Gen${generation}"
            return 1
        fi

        if ! is_supported_gpu "${gpu}"; then
            log "${gpu}: disappeared during retrain; stopping"
            return 1
        fi

        # Отправляем команды ретрейна (как в оригинале)
        setpci -s "${bridge}" CAP_EXP+30.w=0002:000f 2>/dev/null || true
        setpci -s "${gpu}" CAP_EXP+30.w=0002:000f 2>/dev/null || true
        setpci -s "${bridge}" CAP_EXP+10.w=0020:0020 2>/dev/null || true

        status="$(read_link_status "${gpu}")"
        if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
            generation=$((0x${status} & 0x0f))
            if (( generation >= 2 )); then
                log "${gpu}: SUCCESS Gen${generation} at iteration ${iteration} (${elapsed}s)"
                return 0
            fi
        fi
        
        sleep "${RETRAIN_INTERVAL}"
    done

    generation="$(link_generation "${gpu}")"
    log "${gpu}: no Gen2 window after ${MAX_ITERATIONS} attempts; final Gen${generation}"
    return 1
}

# Обработчик завершения - убивает все фоновые процессы при прерывании
cleanup() {
    log "Received termination signal, killing child processes"
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null
    log "=== Synchronized parallel retrain aborted ==="
    exit 1
}

main() {
    local rc=0
    local -a gpus=()
    local -a PIDS=()
    local -a GPU_NAMES=()

    : > "${LOG_FILE}"
    log "=== Synchronized PARALLEL retrain started ==="

    mapfile -t gpus < <(
        for id in 20c2 2082; do
            lspci -D -d "${VENDOR_ID}:${id}" 2>/dev/null | awk '{print $1}'
        done
    )
    
    if [[ ${#gpus[@]} -eq 0 ]]; then
        log "no supported CMP 170HX found"
        log "=== Synchronized parallel retrain finished (rc=0, no GPUs) ==="
        return 0
    fi

    log "Found ${#gpus[@]} GPU(s): ${gpus[*]}"

    # Устанавливаем обработчик прерывания
    trap cleanup SIGTERM SIGINT

    # Запускаем ретрейн для каждой карты параллельно в фоне
    for gpu in "${gpus[@]}"; do
        (
            retrain_one "${gpu}"
        ) &
        PIDS+=($!)
        GPU_NAMES+=("${gpu}")
        log "Spawned background process PID=$! for GPU ${gpu}"
    done

    # Ожидаем завершения каждого процесса и собираем коды возврата
    local i=0
    local failed=0
    local succeeded=0
    
    for pid in "${PIDS[@]}"; do
        wait "$pid"
        local exit_code=$?
        local gpu_name="${GPU_NAMES[$i]}"
        
        if [[ $exit_code -eq 0 ]]; then
            log "${gpu_name}: process PID=${pid} finished with SUCCESS (rc=0)"
            ((succeeded++))
        else
            log "${gpu_name}: process PID=${pid} finished with FAILURE (rc=${exit_code})"
            ((failed++))
            rc=1
        fi
        ((i++))
    done

    log "=== Synchronized parallel retrain finished: ${succeeded} succeeded, ${failed} failed, rc=${rc} ==="
    
    # Сбрасываем trap
    trap - SIGTERM SIGINT
    
    return "${rc}"
}

main "$@"
```

Сделайте исполняемым:

```bash
chmod +x /usr/local/sbin/gen2-sync-hammer.sh
```

---

## Шаг 2: Создайте hookscript для ВМ

```bash
mkdir -p /var/lib/vz/snippets
nano /var/lib/vz/snippets/vm-gen2-sync.sh
```

Вставьте:

```bash
#!/bin/bash
LOG="/var/log/hookscript-debug.log"
LOCK="/tmp/gen2-sync-running"
MAX_LOG_SIZE=262144  # 256 КБ в байтах

# Ротация лог-файла: вызывается один раз при запуске
rotate_log() {
    if [ -f "$LOG" ]; then
        local size
        size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
        if [ "$size" -ge "$MAX_LOG_SIZE" ]; then
            cp "$LOG" "${LOG}.bak"
            > "$LOG"
        fi
    fi
}

rotate_log

echo "[$(date -Is)] Hookscript: параметры=$@ (PID=$$)" >> "$LOG"

if [ "$2" != "post-start" ]; then
    echo "[$(date -Is)] Пропускаем фазу $2" >> "$LOG"
    exit 0
fi

if [ -f "$LOCK" ]; then
    echo "[$(date -Is)] Ретрейн уже запущен, пропускаем" >> "$LOG"
    exit 0
fi

touch "$LOCK"
echo "[$(date -Is)] Запускаем синхронизированный ретрейн" >> "$LOG"

if [ -x /usr/local/sbin/gen2-sync-hammer.sh ]; then
    nohup /usr/local/sbin/gen2-sync-hammer.sh >> /var/log/gen2-sync-hook.log 2>&1 &
    echo "[$(date -Is)] Ретрейн запущен в фоне (PID: $!)" >> "$LOG"
    (sleep 130 && rm -f "$LOCK") &
else
    echo "[$(date -Is)] ОШИБКА: Скрипт не найден" >> "$LOG"
    rm -f "$LOCK"
fi
```

Сделайте исполняемым:

```bash
chmod +x /var/lib/vz/snippets/vm-gen2-sync.sh
```

---

## Шаг 3: Привяжите hookscript к ВМ

```bash
qm set <VMID> --hookscript local:snippets/vm-gen2-sync.sh
```

Замените `<VMID>` на ID вашей виртуальной машины.

---

## Шаг 4: Проверка результата

Выполните **полное** выключение Proxmox, через некоторое время включите и проверьте лог:

```bash
cat /var/log/gen2-sync-hook.log
```

Ожидаемый вывод при успехе:

```
=== Synchronized retrain started ===
0000:XX:00.0: SUCCESS Gen2 at iteration NNN (NNs)
0000:YY:00.0: SUCCESS Gen2 at iteration NNN (NNs)
=== Synchronized retrain finished (rc=0) ===
```

Проверьте скорость PCIe Proxmox:

```bash
lspci -vvv -s <адрес_карты_1> | grep -i "LnkSta:"
lspci -vvv -s <адрес_карты_2> | grep -i "LnkSta:"
```

Проверьте скорость PCIe ВМ:

```
sudo lspci -vv | grep -E "LnkCap:|LnkSta:"
```


Ожидаемый вывод:

```
LnkSta: Speed 5GT/s, Width x4
```

---

## Откат

```bash
qm set <VMID> --delete hookscript
rm -f /usr/local/sbin/gen2-sync-hammer.sh
rm -f /var/lib/vz/snippets/vm-gen2-sync.sh
rm -f /var/log/gen2-sync*.log /var/log/hookscript-debug.log /tmp/gen2-sync-running
```

