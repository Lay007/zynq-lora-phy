`timescale 1ns/1ps

// Compose the generated blind detector with the hand-written timestamp
// alignment primitive. The inputs are exactly the sideband outputs produced by
// the generated FFT correlator: symbolIndex/symbolValid and
// symbolSampleCount/timestampValid.
//
// The currently committed HDL Coder snapshot predates ModulePrefix and names
// the generated detector implementation `BlindDetector`. After regenerating
// with run_hdl_generation.m the same implementation is expected to be named
// `lora_blind_BlindDetector`. Define LORA_NAMESPACED_GENERATED when compiling
// those regenerated sources. No generated Verilog is edited by hand.
`ifdef LORA_NAMESPACED_GENERATED
`define LORA_BLIND_DETECTOR_MODULE lora_blind_BlindDetector
`else
`define LORA_BLIND_DETECTOR_MODULE BlindDetector
`endif

module lora_detector_timestamp_path (
    input  wire        clk,
    input  wire        resetn,
    input  wire        clk_enable,
    input  wire        reset_in,

    input  wire [31:0] symbol_index,
    input  wire        symbol_valid,
    input  wire [63:0] symbol_sample_count,
    input  wire        timestamp_valid,
    // Correlator peak magnitude of the decision on symbol_index, in the same
    // cycle. Zero exactly when there is no signal (see the straddle guard).
    input  wire [15:0] symbol_peak,
    input  wire [7:0]  sync_word,

    output wire         detected,
    // High in the same cycle as `detected` when only the straddle-tolerant
    // path (see below) accepted the sync word, not the generated rule.
    output wire         straddle_detected,
    // High in the same cycle as `detected` when only the split-tolerant path
    // (see below) accepted the packet.
    output wire         split_detected,
    // High in the same cycle as `detected` when only the early-sync path
    // (see below) accepted the packet.
    output wire         early_sync_detected,
    output wire         preamble_detected,
    output wire         sync_valid,
    output wire [15:0]  preamble_bin,
    output wire [15:0]  chips_to_boundary,
    output wire [7:0]   bins_seen,

    output wire [63:0]  preamble_start_count,
    output wire         preamble_start_valid,
    output wire [63:0]  packet_start_count,
    output wire         packet_start_valid,
    output wire         alignment_error,
    output wire         symbol_index_width_error
);

    // HDL Coder currently emits a uint32 symbolIndex for the correlator and a
    // uint16 input for the detector. LoRa SF is at most 12, so valid symbol
    // indices fit comfortably in 16 bits. Keep the truncation explicit and
    // expose an error flag rather than silently hiding an integration mistake.
    wire [15:0] detector_symbol_index = symbol_index[15:0];
    assign symbol_index_width_error = symbol_valid && (|symbol_index[31:16]);

    wire detected_generated;
    wire [15:0] generated_preamble_bin;
    wire [15:0] generated_chips_to_boundary;

    `LORA_BLIND_DETECTOR_MODULE u_blind_detector (
        .clk(clk),
        .reset(~resetn),
        .enb(clk_enable),
        .symbolIndex(detector_symbol_index),
        .symbolValid(symbol_valid),
        .syncWord(sync_word),
        .resetIn(reset_in),
        .detected(detected_generated),
        .preambleDetected(preamble_detected),
        .syncValid(sync_valid),
        .preambleBin(generated_preamble_bin),
        .chipsToBoundary(generated_chips_to_boundary),
        .binsSeen(bins_seen)
    );

    // Straddle-tolerant sync acceptance (M7).
    //
    // On the free-running symbol grid the correlator window straddles two
    // symbols. Deep inside the preamble that costs nothing, but where the
    // preamble meets the first sync symbol the window holds half of each and
    // the N-point spectrum has two comparable peaks; the peak tracker returns
    // whichever is larger. For arrivals a little past half a symbol (about
    // 9% of arrival phases, measured by replaying board IQ through this RTL
    // at every phase) it returns the preamble half: the first sync symbol
    // shows up as one extra preamble bin, and the second sync symbol is read
    // correctly. The generated detector needs preamble+8*highNibble at that
    // position and so never fires, and the packet is lost for good: the sync
    // word cannot be seen again on this grid.
    //
    // The pattern is [8 x ref][ref][ref + 8*lowNibble] instead of
    // [8 x ref][ref + 8*highNibble][ref + 8*lowNibble]. Accepting it as well,
    // with the same +/-1 bin tolerance and the same ten-symbol window, adds
    // no detection where the generated rule already fires: the two sync
    // patterns differ in the ninth symbol by 8*highNibble bins, so at most
    // one of them can match (a sync word with highNibble 0 makes them
    // identical and this path adds nothing). No generated file is edited;
    // this is combinational in the same cycle as symbol_valid, like the
    // generated detected, because lora_detector_timestamp_align requires the
    // decision on the matching timestamp cycle.
    //
    // Two guards, both found the hard way on the first board run of this
    // path (5 of its 12 rescued packets were false detections):
    //
    //  * Every decision in the window must have come from a correlator that
    //    saw a signal. In silence the correlator's spectrum is exactly zero
    //    and its argmax is bin 0, so eight "equal" bins and a ninth equal
    //    bin cost nothing, and the decision for the first, partial window of
    //    the next packet then needs only ONE coincidence (16 +/- 1 bins,
    //    about 2.3%) instead of the generated rule's two. peak, spectrum sum
    //    and confidence were all exactly 0 on every silent decision of
    //    board recordings from 25 dB to the 50 dB set, and non-zero on every
    //    decision of a real preamble or sync window, so "peak != 0" is a
    //    clean test. A false detection there arms the trace and the grid
    //    resync on the wrong instant and garbles the joint estimate.
    //  * The reference bin must lie near half a symbol (N/4 .. 3N/4). The
    //    straddle happens only when the packet's arrival is about half a
    //    symbol from the correlator window, which is what the bin measures;
    //    on the board it was 55..66 and the seven rescued packets that
    //    decoded were 58..64. Silence's bin 0 is far outside.
    localparam [15:0] BIN_MASK = 16'd127; // 2^SF - 1 for the SF7 build

    reg [15:0] prev_bin [0:8]; // [0] oldest ... [8] newest previous symbol
    reg [8:0]  prev_present;   // matching 'correlator saw a signal' bits
    reg [3:0]  prev_filled;
    integer    alt_i;
    integer    alt_j;

    wire [15:0] alt_low  = {12'd0, sync_word[3:0]};
    wire [15:0] alt_ref  = prev_bin[0];
    // N/4 .. 3N/4: the reference bin has to be near half a symbol.
    localparam [15:0] BAND_LOW  = (BIN_MASK + 16'd1) >> 2;
    localparam [15:0] BAND_HIGH = ((BIN_MASK + 16'd1) >> 2) * 16'd3;
    wire alt_ref_in_band = (alt_ref >= BAND_LOW) && (alt_ref <= BAND_HIGH);
    wire alt_signal_present = (&prev_present) && (symbol_peak != 16'd0);
    wire [15:0] alt_s2_target = (alt_ref + ((alt_low << 3) & BIN_MASK)) & BIN_MASK;

    function automatic bin_within(input [15:0] bin, input [15:0] target);
        reg [15:0] delta;
        begin
            delta = (bin - target) & BIN_MASK;
            bin_within = (delta == 16'd0) || (delta == 16'd1) ||
                         (delta == BIN_MASK);
        end
    endfunction

    reg alt_run_ok;
    always @* begin
        alt_run_ok = 1'b1;
        for (alt_i = 0; alt_i < 8; alt_i = alt_i + 1)
            alt_run_ok = alt_run_ok && bin_within(prev_bin[alt_i], alt_ref);
    end

    wire alt_step = clk_enable && symbol_valid && !reset_in;
    wire detected_straddle = alt_step && (prev_filled == 4'd9) &&
        alt_run_ok && alt_signal_present && alt_ref_in_band &&
        bin_within(prev_bin[8], alt_ref) &&
        bin_within(detector_symbol_index, alt_s2_target);

    // Split-tolerant acceptance (M9).
    //
    // On the free-running grid the correlator window holds the tail of one
    // preamble chirp and the head of the next. When the two parts arrive in
    // antiphase -- which depends on the carrier offset and on where inside a
    // chip the packet lands -- they cancel at the true lag and the peak splits
    // into two nearly equal lobes one bin either side. The decision then
    // alternates between true-1 and true+1 from symbol to symbol, and the
    // generated rule's "eight preamble decisions within +/-1 of the oldest"
    // fails. All seven detection misses of the 2026-09-24 board runs were
    // this: replayed through this RTL at the board's own phase (1-sample
    // steps) the decisions matched the board's 16 of 16 and nothing fired;
    // the blind phases recur every 8 samples, one position inside the chip.
    // Removing the carrier offset makes the peak single again, but before
    // detection the offset is not known, so the rule tolerates the split:
    // [8 x (ref +/-2)][ref + 8*highNibble +/-2][ref + 8*lowNibble +/-2], and
    // the straddle form of it (two of the seven misses had both: the split
    // preamble and the first sync symbol read as one more preamble bin),
    // [8 x (ref +/-2)][ref +/-2][ref + 8*lowNibble +/-2]. That form raises
    // straddle_detected too, because the joint controller must not unwrap its
    // coarse origin (see lora_joint_chirp_grid_controller, M7).
    //
    // It fires only where neither the generated rule nor the straddle path
    // did, with the straddle path's two guards (every decision from a
    // correlator that saw a signal; reference bin in N/4 .. 3N/4 -- the seven
    // misses had 49..78). Its preamble bin is the centre of the two lobes
    // seen, not whichever came first, and chips_to_boundary follows from it
    // as the generated detector's does (N - bin): the generated detector's
    // own tracking restarted at the jump and its outputs are stale here.
    wire [15:0] alt_high = {12'd0, sync_word[7:4]};
    wire [15:0] alt_s1_target = (alt_ref + ((alt_high << 3) & BIN_MASK)) & BIN_MASK;

    function automatic bin_within2(input [15:0] bin, input [15:0] target);
        reg [15:0] delta;
        begin
            delta = (bin - target) & BIN_MASK;
            bin_within2 = (delta <= 16'd2) || (delta >= BIN_MASK - 16'd1);
        end
    endfunction

    // Offset of each preamble decision from the reference, -2..+2.
    function automatic signed [3:0] off2(input [15:0] bin, input [15:0] target);
        reg [15:0] delta;
        begin
            delta = (bin - target) & BIN_MASK;
            if (delta <= 16'd2) off2 = delta[3:0];
            else off2 = -$signed({1'b0, (BIN_MASK + 16'd1 - delta)} & 16'h000f);
        end
    endfunction

    reg split_run_ok;
    reg signed [3:0] split_min;
    reg signed [3:0] split_max;
    reg signed [3:0] split_o;
    always @* begin
        split_run_ok = 1'b1;
        split_min = 4'sd0;
        split_max = 4'sd0;
        for (alt_i = 0; alt_i < 8; alt_i = alt_i + 1) begin
            split_run_ok = split_run_ok && bin_within2(prev_bin[alt_i], alt_ref);
            split_o = off2(prev_bin[alt_i], alt_ref);
            if (split_o < split_min) split_min = split_o;
            if (split_o > split_max) split_max = split_o;
        end
    end
    // Centre of the lobes, rounded toward the reference.
    wire signed [4:0] split_sum = split_min + split_max;
    wire signed [3:0] split_centre = split_sum >>> 1;
    wire [15:0] split_bin = (alt_ref + {{12{split_centre[3]}}, split_centre}) & BIN_MASK;
    wire [15:0] split_chips = ((BIN_MASK + 16'd1) - split_bin) & BIN_MASK;

    wire split_s1_sync = bin_within2(prev_bin[8], alt_s1_target);
    wire split_s1_straddle = bin_within2(prev_bin[8], alt_ref);
    wire detected_split_raw = alt_step && (prev_filled == 4'd9) &&
        split_run_ok && alt_signal_present && alt_ref_in_band &&
        (split_s1_sync || split_s1_straddle) &&
        bin_within2(detector_symbol_index, alt_s2_target);
    wire detected_split = detected_split_raw && !detected_generated && !detected_straddle;
    wire split_straddle_form = detected_split && !split_s1_sync;

    // Early-sync acceptance.
    //
    // The mirror image of the straddle path. When the packet lands exactly
    // half a symbol from the correlator window, every window holds half of
    // two chirps, and the one holding the last preamble chirp and the first
    // sync chirp is a tie. Without a carrier offset it goes to the preamble
    // and the generated rule fires; with one, the two halves' tones fall on
    // different fractions of a bin, the tie breaks toward the sync, and the
    // decisions read [7 x ref][s1][s1][s2]: one preamble decision short,
    // nothing fires. Found by the CI matrix (grid_phase 512, CFO
    // +/-0.000418 cycles/sample, the board's typical offset: 64 x 7, 72, 72,
    // 81 against the generated rule's 64 x 8, 72, 80 at CFO 0).
    //
    // The windows are the generated rule's own -- the tie window is the one
    // it counts as the eighth preamble decision -- so the path fires on the
    // same symbol, with the same preamble bin (ref) and chips_to_boundary
    // (N - ref), and the joint controller treats it as an ordinary
    // detection (no straddle flag). Seven equal decisions and the first sync
    // twice are no weaker a pattern than the generated rule's eight and one.
    // Guards as for the straddle path.
    reg early_run_ok;
    always @* begin
        early_run_ok = 1'b1;
        for (alt_i = 0; alt_i < 7; alt_i = alt_i + 1)
            early_run_ok = early_run_ok && bin_within(prev_bin[alt_i], alt_ref);
    end
    wire detected_early_raw = alt_step && (prev_filled == 4'd9) &&
        early_run_ok && alt_signal_present && alt_ref_in_band &&
        bin_within(prev_bin[7], alt_s1_target) &&
        bin_within(prev_bin[8], alt_s1_target) &&
        bin_within(detector_symbol_index, alt_s2_target);
    wire detected_early = detected_early_raw && !detected_generated &&
        !detected_straddle && !detected_split;
    wire [15:0] early_chips = ((BIN_MASK + 16'd1) - alt_ref) & BIN_MASK;

    assign detected = detected_generated || detected_straddle || detected_split || detected_early;
    assign straddle_detected = (detected_straddle && !detected_generated) || split_straddle_form;
    assign split_detected = detected_split;
    assign early_sync_detected = detected_early;
    assign preamble_bin = detected_split ? split_bin :
                          detected_early ? alt_ref : generated_preamble_bin;
    assign chips_to_boundary = detected_split ? split_chips :
                               detected_early ? early_chips : generated_chips_to_boundary;

    always @(posedge clk) begin
        if (!resetn || reset_in) begin
            prev_filled <= 4'd0;
            prev_present <= 9'd0;
            for (alt_j = 0; alt_j < 9; alt_j = alt_j + 1)
                prev_bin[alt_j] <= 16'd0;
        end else if (clk_enable && symbol_valid) begin
            for (alt_j = 0; alt_j < 8; alt_j = alt_j + 1)
                prev_bin[alt_j] <= prev_bin[alt_j + 1];
            prev_bin[8] <= detector_symbol_index;
            prev_present <= {prev_present[7:0], symbol_peak != 16'd0};
            if (prev_filled < 4'd9)
                prev_filled <= prev_filled + 4'd1;
        end
    end

    // reset_in clears the generated detector/correlator streaming state. Clear
    // timestamp history on the same clock edge so a post-reset detector event
    // can never be paired with a pre-reset symbol timestamp.
    wire align_resetn = resetn && !reset_in;

    lora_detector_timestamp_align u_timestamp_align (
        .clk(clk),
        .resetn(align_resetn),
        .symbol_sample_count(symbol_sample_count),
        .symbol_timestamp_valid(timestamp_valid),
        .preamble_detected(preamble_detected),
        .packet_detected(detected),  // generated OR straddle-tolerant
        .preamble_start_count(preamble_start_count),
        .preamble_start_valid(preamble_start_valid),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .alignment_error(alignment_error)
    );

endmodule

`undef LORA_BLIND_DETECTOR_MODULE
