#!/usr/bin/env bash
# CMP 50HX PCIe Gen2 unlock + auto-retrain (deterministic policy method).
#
# The card's PCIe target-speed registers are GSP-clobbered ~100 ms after the
# driver's boot-window policy runs, so waiting for a "self-unlock" is
# unreliable (observed on kernel 6.8.0-139: no flip for 12+ minutes, because
# the driver's retrain gate then always skips). Instead we apply the unlock
# policy ourselves through BAR0 — the same register set patch 01 writes — and
# kick LTSSM, which makes the card adopt the unlocked capability set at once
# (adoption is one-shot per power cycle, so this must run before anything
# else adopts the locked set; the boot order guarantees that). Then we mirror
# the card's target onto the upstream port and fire Retrain Link until the
# link reaches the card's target generation. Retrain Link is safe under load
# and harmless to repeat.
#
# Register map (BAR0): MISC1 0x8841c, LTSSM 0x8872c, CFG0 0x8c040,
# PL_RATE 0x8c1c0, CYA0 0x8c2c0, XP3G_VAL0 0x8e120, XP3G_OVR0 0x8e110,
# XP3G_PLM0 (gate) 0x8e1b0. XP3G_VAL3/OVR3 from the driver policy are
# omitted: an A/B on 2026-09-13 proved the unlock works without them.
set -u

TIMEOUT_MIN=20      # give up after this many minutes
POLL_SEC=15         # how often to retry (gate opens ~5 s after boot)
RETRAIN_WAIT_SEC=3  # how long to wait for the link to come back up

log() { echo "cmp50hx-gen2: $*"; }

# Applies the Gen2 policy + LTSSM kick via BAR0. Prints one of:
#   GATE_CLOSED          PLM gate not open yet (driver still booting)
#   ADOPTED tls=N cap=N  policy applied, card adopted the unlocked set
#   ALREADY tls=N cap=N  card already unlocked (CAP >= 2)
apply_policy() { # $1 = BDF
    python3 - "$1" <<'EOF'
import mmap, sys
bdf = sys.argv[1]
R = dict(MISC1=0x8841C, LTSSM=0x8872C, CFG0=0x8C040, PL_RATE=0x8C1C0,
         CYA0=0x8C2C0, OVR0=0x8E110, VAL0=0x8E120, PLM0=0x8E1B0)
f = open(f'/sys/bus/pci/devices/{bdf}/resource0', 'r+b')
m = mmap.mmap(f.fileno(), 0x90000)
rd = lambda o: int.from_bytes(m[o:o+4], 'little')
wr = lambda o, v: m.__setitem__(slice(o, o+4), v.to_bytes(4, 'little'))
if rd(R['PLM0']) != 0xFFFFFFFF:
    print("GATE_CLOSED"); sys.exit(0)
import subprocess
cap = int(subprocess.run(['setpci', '-s', bdf, 'CAP_EXP+0c.L'],
                         capture_output=True, text=True).stdout, 16)
tls = int(subprocess.run(['setpci', '-s', bdf, 'CAP_EXP+30.W'],
                         capture_output=True, text=True).stdout, 16) & 0xf
if (cap & 0xf) >= 2:
    print(f"ALREADY tls={tls} cap={cap & 0xf}"); sys.exit(0)
wr(R['MISC1'], (rd(R['MISC1']) | ((1 << 11) | (1 << 13))) & ~((1 << 12) | (1 << 14)))
wr(R['VAL0'], 0); wr(R['OVR0'], 1)
wr(R['CYA0'], rd(R['CYA0']) & ~(1 << 2))
wr(R['CFG0'], (rd(R['CFG0']) & ~0x000C0000) | (2 << 18))
wr(R['PL_RATE'], (rd(R['PL_RATE']) & ~0x00060000) | 0x00040000)
wr(R['LTSSM'], 6)
cap = int(subprocess.run(['setpci', '-s', bdf, 'CAP_EXP+0c.L'],
                         capture_output=True, text=True).stdout, 16)
tls = int(subprocess.run(['setpci', '-s', bdf, 'CAP_EXP+30.W'],
                         capture_output=True, text=True).stdout, 16) & 0xf
print(f"ADOPTED tls={tls} cap={cap & 0xf}")
EOF
}

link_gen() { # $1 = BDF; prints current generation 0..5
    case "$(cat "/sys/bus/pci/devices/$1/current_link_speed" 2>/dev/null)" in
        *2.5*)  echo 1 ;;
        *5.0*)  echo 2 ;;
        *8.0*)  echo 3 ;;
        *16.0*) echo 4 ;;
        *32.0*) echo 5 ;;
        *)      echo 0 ;;
    esac
}

gpu_tls() { # $1 = BDF; prints the card's target generation
    local t
    t=$(setpci -s "$1" CAP_EXP+30.W 2>/dev/null)
    echo $(( 0x${t:-0} & 0xf ))
}

retrain() { # $1 = upstream bridge BDF; $2 = target generation
    local ctl2 ctl
    ctl2=$(setpci -s "$1" CAP_EXP+30.W)
    setpci -s "$1" CAP_EXP+30.W="$(printf '%04x' $(( (0x$ctl2 & ~0xf) | $2 )))"
    ctl=$(setpci -s "$1" CAP_EXP+10.W)
    setpci -s "$1" CAP_EXP+10.W="$(printf '%04x' $(( 0x$ctl | 0x20 )))"
}

bfds=$(lspci -Dnn 2>/dev/null | awk '/10de:1e09/ {print $1}')
if [[ -z "${bfds}" ]]; then
    log "no CMP 50HX (10de:1e09) found; nothing to do"
    exit 0
fi

deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while :; do
    all_fast=1
    for bdf in ${bfds}; do
        t=$(gpu_tls "${bdf}")
        cur=$(link_gen "${bdf}")
        if (( t >= 2 && cur >= t )); then
            continue
        fi
        all_fast=0
        if (( t < 2 )); then
            out=$(apply_policy "${bdf}" 2>/dev/null)
            case "${out}" in
                GATE_CLOSED)
                    log "${bdf}: PLM gate not open yet; retrying"
                    ;;
                ADOPTED*|ALREADY*)
                    log "${bdf}: ${out}"
                    ;;
                *)
                    log "${bdf}: policy apply failed (${out}); retrying"
                    ;;
            esac
            t=$(gpu_tls "${bdf}")
            (( t < 2 )) && continue
        fi
        upstream=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${bdf}")")")
        log "${bdf}: card unlocked (TLS=${t}), firing retrain via ${upstream} (link now Gen${cur})"
        retrain "${upstream}" "${t}"
        for _ in $(seq 1 $(( RETRAIN_WAIT_SEC * 10 ))); do
            [[ "$(link_gen "${bdf}")" -ge ${t} ]] && break
            sleep 0.1
        done
        cur=$(link_gen "${bdf}")
        if (( cur >= t )); then
            log "${bdf}: PASS, link at $(cat "/sys/bus/pci/devices/${bdf}/current_link_speed")"
        else
            log "${bdf}: retrain fired, link still at Gen${cur} < Gen${t} (will retry)"
        fi
    done
    if [[ ${all_fast} -eq 1 ]]; then
        log "all CMP 50HX cards at their target generation"
        exit 0
    fi
    if [[ $(date +%s) -ge ${deadline} ]]; then
        log "TIMEOUT after ${TIMEOUT_MIN} min; some card(s) below target"
        exit 1
    fi
    sleep "${POLL_SEC}"
done
