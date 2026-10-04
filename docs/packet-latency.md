# Optional packet processing latency (LT1)

The ARM trace reader can read a latency-capable experimental FPGA image without
changing existing CRC/PER or ToA policy. An old image or old trace reports
`latency_supported=false`; it does not acquire an estimated latency from the
existing `mac_search_clocks` diagnostic.

Control bit 7 selects LT1. Its status high 24 bits equal `0x4c5401`.
Sequence, detection interval, down-search interval, coarse low word,
coarse high word and signed Q12 fraction occupy the seven existing status
outputs, in that order. The intervals use 62.5 MHz PL clocks (16 ns each).
They end on accepted precise correction. Detection starts on a confirmed packet
start; down-search starts on the most recent down-reference search, including
an allowed retry. They exclude host decoding and USB/SSH delay.

Status low bits: 0 detection valid, 1 down-search valid, 2 detection overflow,
3 down-search overflow, 4 ambiguous restart, 5 precise correction applied,
6 reserved zero, 7 snapshot valid. A normal snapshot is `0x4c5401a3`.

`lora_trace_stream` appends `lat_status`, `lat_seq`, `lat_detect_clocks`,
`lat_down_clocks`, `lat_coarse`, `lat_frac` and `lat_changed` to `PKT` lines.
It checks LT1 read stability and exact identity against page 0, and retains the
final page-0 sequence check. Its page mask clears bit 7 when selecting any
other page.

`finite_bench.parse_record` retains raw integers and requires the same sequence
and full 64-bit coarse/Q12 timestamp as the fresh valid ToA record. Changed
snapshots, overflow, restart ambiguity, missing validity flags, reserved bits
and impossible counter ordering reject the latency. Reasons are exposed in
`latency_rejection_reasons`; a rejected latency does not alter otherwise valid
CRC/PER or ToA. A malformed partial extension remains an invalid trace attempt.

Only valid latency records expose `latency_detect_us` and `latency_down_us`.
Finite accounting reports `usable_latency` per unique planned ID after exact
payload and CRC validation, just as `usable_toa` does. A duplicate record cannot
create another successful planned transmission. FPGA support must be qualified
separately; this reader change does not qualify a new image or change the
checked-in RTL.
