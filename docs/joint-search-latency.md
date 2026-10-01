# Joint ToA/CFO search and processing deadline

The early-sync path can confirm a packet one FFT window late. Its flag now
selects the preceding chirp origin even when CFO moves the phase below half
a symbol. This prevents a one-symbol ToA error that CRC alone cannot detect.

Three optional receiver parameters reduce search latency. Their defaults
preserve the existing serial search and resource architecture:

| Parameter | Default | Qualified experimental setting |
| --- | ---: | ---: |
| `MATCH_REQUEST_ON_RESPONSE` | 0 | 1 |
| `MATCH_COARSE_STRIDE` | 1 | 2 |
| `JOINT_PREFETCH_UP` | 0 | 1 |
| `SEARCH_RADIUS` | 16 | 48 |
| `GRID_FINE_GUARD_SAMPLES` | 16 | 48 |

The fast MAC issues the next read on the cycle that consumes a valid response.
It keeps one outstanding read, handles delayed responses, and uses the same
complex multiplier. For 1024 samples and a one-cycle read port, MAC completion
takes 1027 clocks instead of 2050 clocks (start-to-result convention in the
protocol test).

Stride 2 first locates a broad correlation lobe, then evaluates five consecutive
unit-sample lags around the coarse maximum. Only this final unit-spacing
triplet reaches the interpolator. Radius 48 needs 49 coarse plus five fine
correlations. This option is intended for the oversampled SF7/L8 chirp; it
must not be used for arbitrary isolated single-sample peaks. Boundary maxima
are conservatively rejected.

Prefetch evaluates an interior upchirp after eight nonzero-peak preamble
decisions. Equal zero-valued decisions in silence cannot arm it. Confirmation
by the sync word is still required before downchirp processing or metadata.
Cached offsets transfer to the confirmed epoch, with signed modulo-symbol
phase adjustment of at most two chips; larger changes repeat the up search.
Failed unconfirmed work produces no correction. Failed confirmed speculative
work retries the ordinary up search. Stream reset drops the cache. Unconfirmed
cached work expires after twelve further symbols; preambles of 8 and 12 symbols
are covered by the regression, longer preambles are not qualified here.

Run the full-packet regression on Linux with Verilator and the package installed:

```sh
python tools/joint_packet_regression.py --out build/joint-full-packet
```

Nine complete, noise-free standard packets exercise both CFO signs at
1500 Hz, arrival phases around the half-symbol boundary, and preambles of
8/12 symbols. Samples arrive every alternating 62/63 clocks, matching
1 MS/s at a 62.5 MHz PL clock. Checks include decoded CRC, exact payload,
ToA error below half a sample, and completion more than 96 samples before
the header (the maximum guarded resync advance).

The down-search launch-to-fine delay is 55,613 clocks, or 889.808 microseconds.
The total prefetch span includes waiting for RF samples and sync confirmation;
it is not a compute-only latency. Detection-to-fine and remaining header margin
are reported separately. The ToA epoch is the first of the retained eight
preamble chirps; with a 12-symbol preamble it is four symbols after the first
RF chirp. These simulation figures do not establish physical timestamp
accuracy, host latency, or FPGA timing closure.
