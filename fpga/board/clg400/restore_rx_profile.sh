#!/bin/sh
set -eu

# Return the AD9361 to the LoRa receive profile after a cold boot.
#
# The transceiver comes up at 30.72 MS/s with a bypassed filter chain, and the
# LoRa receiver needs exact 1 MS/s. Only IIO sysfs attributes of the transceiver
# are written. This script never touches QSPI, the boot loader, the FPGA
# manager, the PL control registers, or any RF transmit enable; the two FIR
# enables it writes select the digital filter chain, not an RF output.
#
# The order matters and getting it wrong returns EINVAL rather than anything
# descriptive. This follows ad9361_set_bb_rate() from libad9361-iio -- park at
# 3 MS/s with the filter bypassed and load the 128-tap decimate- and
# interpolate-by-4 filter -- with one correction for this board's driver: both
# filter enables are written, and both before the target rate, because at
# 1 MS/s the chain is only legal with the receive FIR decimating.
#
# The rate is parked *before* the FIR is bypassed, not after: on a cold boot
# the transceiver is already above the park rate with the filter bypassed, so
# either order looks fine there. Re-running this script against a board
# already sitting at the 1 MS/s profile (e.g. only to change gain) is a
# different starting point -- bypassing the FIR while still at 1 MS/s is the
# same illegal combination the comment above already names, just approached
# from the other side, and fails with the same bare EINVAL.
#
# Reordering alone was not enough, measured live: even with the rate already
# parked, bypassing the FIR immediately afterward -- both writes in the same
# shell, no delay -- still failed with the same bare EINVAL. A fixed settle
# delay after the park was tried next and was not reliable either: 0.2 s was
# enough in some trials and not others, and a failing write's exit status
# turned out not to mean the value was rejected -- one run's `echo 0 >
# out_voltage_filter_fir_en` reported the same write error and still left
# the attribute reading back 0. So the write's own exit status is not what
# to trust here; the readback is. set_fir below writes, ignores that write's
# reported status, and polls the readback with a short retry budget instead
# of a guessed delay.
set_fir() {
    attribute=$1
    value=$2
    tries=0
    while true; do
        echo "$value" > "$attribute" 2>/dev/null || true
        if [ "$(cat "$attribute")" = "$value" ]; then
            return 0
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 20 ]; then
            echo "FAIL: $attribute did not settle to $value after $tries attempts" >&2
            return 1
        fi
        sleep 0.1
    done
}

DEVICE=${DEVICE:-/sys/bus/iio/devices/iio:device0}
RATE=${RATE:-1000000}
LO=${LO:-868100000}
BANDWIDTH=${BANDWIDTH:-200000}
# RX gain puts the packet inside the generated correlator's working window,
# about 20..5000 input LSB (its 16-bit |X|^2 truncates weak windows to zero
# and saturates strong ones; measured by RTL replay 2026-09-27). On the
# ~1 m bench the packet peak swings ~15 dB with people in the room: at 25 dB
# it fell to 9..16 LSB and 1 in 5 of the weakest packets was missed; 50 dB
# clipped the ADC (2026-09-19). 37 dB gave 36..880 LSB and 0 misses in 1245.
GAIN=${GAIN:-37}
PARK_RATE=3000000
FIR_TAPS=128
# Receive FIR: "generic" is the libad9361 filter (passband about +-400 kHz at
# 1 MS/s, so only the analog LPF limits the noise); "lora125" is a 128-tap
# Kaiser low-pass cut at 80 kHz for the 125 kHz LoRa channel (-1 dB at
# 50 kHz, 133 kHz noise bandwidth). The PL correlator is a matched filter
# over the whole 1024-sample window, so out-of-channel noise does not fold
# into the decision and the generic filter costs no sensitivity by itself;
# lora125 only lowers the total level the correlator sees and adds
# adjacent-channel rejection (PER bench A/B, 2026-09-30,
# docs/per-curves-experiment.md). The transmit half always uses the generic
# filter. The FIR changes the group delay, so absolute ToA shifts.
RX_FIR=${RX_FIR:-generic}

if [ ! -d "$DEVICE" ]; then
    echo "FAIL: $DEVICE is not present." >&2
    exit 2
fi
if [ "$(cat "$DEVICE/name")" != "ad9361-phy" ]; then
    echo "FAIL: $DEVICE is not the AD9361 transceiver." >&2
    exit 3
fi

filter_file=$(mktemp /tmp/lora_fir.XXXXXX)
trap 'rm -f "$filter_file"' EXIT HUP INT TERM

# ad9361_set_bb_rate() filter for sample rates at or below 20 MS/s.
generic_taps="
        -15 -27 -23 -6 17 33 31 9 -23 -47 -45 -13 34 69
        67 21 -49 -102 -99 -32 69 146 143 48 -96 -204 -200
        -69 129 278 275 97 -170 -372 -371 -135 222 494 497
        187 -288 -654 -665 -258 376 875 902 363 -500 -1201
        -1265 -530 699 1748 1906 845 -1089 -2922 -3424 -1697
        2326 7714 12821 15921 15921 12821 7714 2326 -1697
        -3424 -2922 -1089 845 1906 1748 699 -530 -1265 -1201
        -500 363 902 875 376 -258 -665 -654 -288 187 497
        494 222 -135 -371 -372 -170 97 275 278 129 -69 -200
        -204 -96 48 143 146 69 -32 -99 -102 -49 21 67 69
        34 -13 -45 -47 -23 9 31 33 17 -6 -23 -27 -15"
# Kaiser (beta 6) windowed sinc, fc 80 kHz at 4 MS/s, DC gain matched to the
# generic filter: -1 dB at 50 kHz, -2.4 dB at 62.5 kHz, -32 dB at 125 kHz,
# below -68 dB from 180 kHz.
lora125_taps="
    5 6 8 10 12 13 15 16 16 16 15 12 8 3 -4 -12 -22 -35 -49 -64 -81 -100
    -119 -139 -158 -178 -196 -212 -226 -236 -241 -242 -236 -224 -203
    -175 -137 -90 -32 35 113 201 299 407 524 649 781 919 1061 1207 1354
    1500 1645 1786 1921 2048 2167 2274 2370 2451 2518 2569 2603 2621
    2621 2603 2569 2518 2451 2370 2274 2167 2048 1921 1786 1645 1500
    1354 1207 1061 919 781 649 524 407 299 201 113 35 -32 -90 -137 -175
    -203 -224 -236 -242 -241 -236 -226 -212 -196 -178 -158 -139 -119
    -100 -81 -64 -49 -35 -22 -12 -4 3 8 12 15 16 16 16 15 13 12 10 8 6 5"
case "$RX_FIR" in
    generic) rx_taps=$generic_taps ;;
    lora125) rx_taps=$lora125_taps ;;
    *) echo "FAIL: RX_FIR must be generic or lora125, not $RX_FIR" >&2; exit 6 ;;
esac
{
    echo "RX 3 GAIN -6 DEC 4"
    echo "TX 3 GAIN 0 INT 4"
    set -- $generic_taps
    for tap in $rx_taps; do
        echo "$tap,$1"
        shift
    done
    echo
} > "$filter_file"

cd "$DEVICE"

echo "$PARK_RATE" > in_voltage_sampling_frequency
set_fir out_voltage_filter_fir_en 0
set_fir in_voltage_filter_fir_en 0
cat "$filter_file" > filter_fir_config

# The interpolated transmit chain has to be able to clock the whole filter at
# the target rate; libad9361 parks the chain again when it cannot.
dac_rate=$(sed 's/.*DAC:\([0-9]*\).*/\1/' tx_path_rates)
tx_rate=$(sed 's/.*TXSAMP:\([0-9]*\).*/\1/' tx_path_rates)
max_taps=$(( (dac_rate / tx_rate) * 16 ))
if [ "$max_taps" -lt "$FIR_TAPS" ]; then
    echo "$PARK_RATE" > in_voltage_sampling_frequency
fi

# libad9361 only writes the transmit enable, because on the kernels it targets
# that one enables both halves of the filter chain. This board's driver does
# not: the receive enable has to be written separately, and it has to be written
# before the target rate. At 1 MS/s the chain is only legal with the receive FIR
# decimating, so setting the rate first is what produces the bare EINVAL.
#
# Re-enabling was not observed to be flaky the way disabling was, but it is
# the same write to the same two attributes right after another rate change,
# so it gets the same verified-by-readback treatment rather than an
# unguarded echo that happens to have worked in every trial so far.
set_fir out_voltage_filter_fir_en 1
set_fir in_voltage_filter_fir_en 1
echo "$RATE" > in_voltage_sampling_frequency

echo "$BANDWIDTH" > in_voltage_rf_bandwidth
echo "$LO" > out_altvoltage0_RX_LO_frequency
echo manual > in_voltage0_gain_control_mode
echo manual > in_voltage1_gain_control_mode
echo "$GAIN" > in_voltage0_hardwaregain
echo "$GAIN" > in_voltage1_hardwaregain

echo '=== read back ==='
for attribute in \
    in_voltage_sampling_frequency in_voltage_rf_bandwidth \
    in_voltage_filter_fir_en out_voltage_filter_fir_en \
    in_voltage0_gain_control_mode in_voltage1_gain_control_mode \
    in_voltage0_hardwaregain in_voltage1_hardwaregain \
    out_altvoltage0_RX_LO_frequency rx_path_rates tx_path_rates; do
    printf '%s=%s\n' "$attribute" "$(cat "$attribute")"
done
echo "rx_fir=$RX_FIR"

actual_rate=$(cat in_voltage_sampling_frequency)
if [ "$actual_rate" != "$RATE" ]; then
    echo "FAIL: sampling frequency read back as $actual_rate, expected $RATE" >&2
    exit 4
fi
if [ "$(cat in_voltage_filter_fir_en)" != "1" ] || \
   [ "$(cat out_voltage_filter_fir_en)" != "1" ]; then
    echo 'FAIL: the FIR chain is not enabled on both paths.' >&2
    exit 5
fi

echo 'PASS: AD9361 restored to the LoRa receive profile.'
