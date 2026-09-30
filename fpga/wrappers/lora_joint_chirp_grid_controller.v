`timescale 1ns/1ps

// Sequence one full-resolution preamble/SFD matched-filter pair and turn the
// two integer peaks into a sample-grid correction.
//
// A timing error moves the upchirp and downchirp peaks in the same direction;
// CFO moves them in opposite directions. Therefore
//
//   timingSamples = round_away_from_zero((upOffset + downOffset) / 2).
//
// The coarse packet timestamp is the first of the eight preamble decisions
// retained by the detector's ten-symbol [8 preamble + 2 sync] window. It is an
// FFT window origin, not the grid boundary preceding the packet. A decision
// follows the chirp occupying most of its window: when arrival crosses half
// a symbol, the confirmed decision sequence moves to the next FFT window.
// Therefore the packet chirp is at the NEAREST boundary to that window origin.
// Unwrap chips_to_boundary*L into [-SYMBOL_SAMPLES/2, SYMBOL_SAMPLES/2), then
// use that same origin for both searches (the first full SFD is ten symbols
// later). At the half-symbol tie the confirmed sequence uses the later window.
// The grid resynchronizer instead needs a forward-only skip modulo a symbol;
// using that skip as a timestamp displacement selects the next preamble chirp.
//
// fine_skip includes FINE_GUARD_SAMPLES. The coarse grid-resync policy must
// withhold the same guard from its first skip, so both requests together equal
// the original coarse advance plus the signed joint timing correction. Keeping
// the late request non-negative matters because the generated correlator can
// advance its grid by dropping samples but cannot move it backwards.
module lora_joint_chirp_grid_controller #(
    parameter integer SAMPLES_PER_CHIP = 8,
    parameter integer SYMBOL_SAMPLES = 1024,
    parameter integer SEARCH_RADIUS = 16,
    parameter integer FINE_GUARD_SAMPLES = 16,
    parameter integer PREAMBLE_TO_SFD_SYMBOLS = 10
) (
    input  wire               clk,
    input  wire               resetn,
    input  wire               stream_reset,

    input  wire               packet_start_valid,
    input  wire [63:0]        packet_start_count,
    input  wire [15:0]        chips_to_boundary,
    // Set when the detector accepted the sync word only through its
    // straddle-tolerant path (M7). See coarse_phase_samples below.
    input  wire               packet_straddle,
    input  wire [63:0]        history_next_sample_count,

    input  wire               search_busy,
    input  wire               search_failed,
    input  wire               search_triplet_valid,
    input  wire [63:0]        search_peak_sample_count,
    // Sub-sample refinement for the integer peak above, from the same
    // generated ToA interpolator the legacy single-search path already uses.
    // Q12 (1/4096 sample), range +/-2048 (+/-0.5 sample); one search_offset_valid
    // pulse follows each search_triplet_valid, on its own fixed latency, never
    // concurrently with the next search's peak (the states below wait for it
    // before either leg is allowed to proceed).
    input  wire signed [15:0] search_offset_q12,
    input  wire               search_offset_valid,

    output reg                search_start,
    output reg  [63:0]        search_coarse_start,
    output reg                reference_down,
    output reg                busy,

    output reg  signed [31:0] timing_correction_samples,
    // Diagnostics. The board applies a correction that is not the one
    // the reference model derives, and the two are measured from
    // different origins, so only these make them comparable: where the
    // up search was told to look, and how far from there its peak was.
    output wire [63:0]        diag_up_coarse_start,
    output wire signed [31:0] diag_up_offset_samples,
    // The sub-sample refinement actually captured for the up leg, in the
    // same Q12 units as search_offset_q12. Without this, the fractional
    // correction the board applies would again be invisible to any future
    // stage-differential comparison, exactly the gap that made this fix hard
    // to find in the first place. The down leg has no equivalent diagnostic
    // today and this does not add one.
    output wire signed [15:0] diag_up_offset_frac_q12,
    output reg  [31:0]        fine_skip,
    output reg                fine_resync_valid,
    output reg                timing_valid,

    output reg                restart_error,
    output reg                timing_range_error,
    // Asserted for one cycle when a search abort forced the correction to
    // be declined, split by which of the two searches aborted. Without
    // this split a trace cannot tell "the estimator never ran" from "it
    // ran and was rejected", nor tell the up-search failing from the
    // down-search failing -- both used to share one search_abort_error bit.
    output reg                up_search_abort_error,
    output reg                down_search_abort_error,
    // Asserted for one cycle exactly when a correction both completed and
    // fell inside +/-FINE_GUARD_SAMPLES, i.e. was actually applied to the
    // grid. timing_valid alone does not say this: it also pulses when the
    // estimate was computed and then declined by timing_range_error.
    output reg                precise_correction_applied,
    // The packet's time of arrival with the carrier offset removed: the up
    // leg's coarse start plus the joint (up + down) / 2 timing, split as the
    // metadata ABI is (a whole sample count and a signed Q12 remainder within
    // +/-0.5 sample). Valid on the precise_correction_applied pulse.
    //
    // Why: the metadata used to be the up leg's peak alone, and a carrier
    // offset moves an upchirp's matched-filter peak by the CFO displacement
    // (-2.8..-3.6 samples on the board, i.e. microseconds). The joint pair
    // cancels it but only ever steered the symbol grid.
    output reg  [63:0]        toa_coarse,
    output reg  signed [31:0] toa_fraction_q12,
    // The carrier offset the same pair measured, as the matched-filter
    // displacement (up - down) / 2 in Q12 samples; valid with toa_coarse.
    // lora_cfo_derotator removes it from the decisions that follow.
    output reg  signed [31:0] cfo_q12
);

    localparam [3:0] STATE_IDLE           = 4'd0;
    localparam [3:0] STATE_LAUNCH_UP      = 4'd1;
    localparam [3:0] STATE_WAIT_UP        = 4'd2;
    localparam [3:0] STATE_WAIT_DOWN_DATA = 4'd3;
    localparam [3:0] STATE_LAUNCH_DOWN    = 4'd4;
    localparam [3:0] STATE_WAIT_DOWN      = 4'd5;
    localparam [3:0] STATE_WAIT_UP_FRAC   = 4'd6;
    localparam [3:0] STATE_WAIT_DOWN_FRAC = 4'd7;
    // Two register stages between the down leg's interpolator result and
    // the latched estimate. With the sum, the rounding, the range check and
    // the CFO difference all in the interpolator's output cycle, the M9
    // build missed timing by 0.056 ns on that one path (46 logic levels,
    // 36 of them carry chains, quotientReg -> toa_fraction_q12 CE). The
    // estimate arrives two clocks later; a sample takes 63.
    localparam [3:0] STATE_SUM            = 4'd8;
    localparam [3:0] STATE_DECIDE         = 4'd9;

    localparam [63:0] SYMBOL_SAMPLES_U64 = SYMBOL_SAMPLES;
    localparam [63:0] SEARCH_RADIUS_U64 = SEARCH_RADIUS;
    localparam [63:0] FINE_GUARD_U64 = FINE_GUARD_SAMPLES;
    // Half the Q12-of-two-samples divisor used to round timing to the
    // nearest integer sample below (see the comment at rounded_abs).
    localparam signed [65:0] TIMING_ROUND_BIAS_Q12x2 = 66'sd4096;

    reg [3:0] state;
    reg [63:0] up_coarse_start;
    reg [63:0] down_coarse_start;
    reg signed [64:0] up_offset_int;
    reg signed [15:0] up_offset_frac_q12;
    reg signed [64:0] down_offset_int;
    reg signed [15:0] down_offset_frac_q12;
    reg signed [65:0] offset_sum_q12_r;
    reg signed [65:0] cfo_q12_r;

    assign diag_up_coarse_start = up_coarse_start;
    assign diag_up_offset_samples = up_offset_int[31:0];
    assign diag_up_offset_frac_q12 = up_offset_frac_q12;

    wire [63:0] coarse_chip_advance = chips_to_boundary * SAMPLES_PER_CHIP;
    // A straddle-accepted packet never wraps. Where the preamble meets the
    // first sync symbol the correlator window holds half of each, and for
    // the arrivals the generated detector could not accept (measured on
    // board IQ replayed through this RTL: chips_to_boundary 62..73, up to
    // 592 samples of advance, past the half-symbol point) the retained
    // decision window has not yet moved on to the next symbol.
    // packet_start_count then still names the earlier window, and wrapping
    // by a symbol here points the down search a whole symbol early: its
    // matched-filter peak came out 6.5x weaker, noise. The up leg cannot
    // tell, because every preamble upchirp looks alike.
    wire coarse_wraps = !packet_straddle
        && (coarse_chip_advance >= (SYMBOL_SAMPLES_U64 / 2));
    wire signed [64:0] coarse_phase_samples =
        coarse_wraps
        ? $signed({1'b0, coarse_chip_advance}) - $signed({1'b0, SYMBOL_SAMPLES_U64})
        : $signed({1'b0, coarse_chip_advance});
    wire signed [64:0] packet_chirp_start =
        $signed({1'b0, packet_start_count}) + coarse_phase_samples;
    // Both searches read coarse_start-SEARCH_RADIUS .. coarse_start+M+RADIUS,
    // so neither may start before that window has arrived. The down search
    // always waited; the up search did not, and a read past
    // next_sample_count is a history miss exactly like a read that has aged
    // out. Measured on the board: the miss persists when the packet is sent
    // 0.2 ms after the stream reset, where nothing can have been overwritten
    // yet, so the failing read is ahead of the stream rather than behind it.
    wire [63:0] up_ready_count = up_coarse_start
        + SYMBOL_SAMPLES_U64 + SEARCH_RADIUS_U64;
    wire [63:0] down_ready_count = down_coarse_start
        + SYMBOL_SAMPLES_U64 + SEARCH_RADIUS_U64;
    wire signed [64:0] peak_signed = {1'b0, search_peak_sample_count};
    wire signed [64:0] down_coarse_signed = {1'b0, down_coarse_start};

    // Q12 fixed-point combination: each leg's offset is its captured integer
    // sample count, scaled to Q12, plus the interpolator's sub-sample
    // refinement in the same units, both captured into registers
    // (STATE_WAIT_UP_FRAC, STATE_WAIT_DOWN_FRAC). STATE_SUM registers the
    // sum and the difference; STATE_DECIDE rounds, range-checks and latches.
    wire signed [64:0] up_offset_q12 =
        (up_offset_int <<< 12)
        + {{49{up_offset_frac_q12[15]}}, up_offset_frac_q12};
    wire signed [64:0] down_offset_q12 =
        (down_offset_int <<< 12)
        + {{49{down_offset_frac_q12[15]}}, down_offset_frac_q12};
    wire signed [65:0] offset_sum_q12 =
        {{1{up_offset_q12[64]}}, up_offset_q12}
        + {{1{down_offset_q12[64]}}, down_offset_q12};
    wire signed [65:0] offset_sum_q12_abs =
        offset_sum_q12_r < 0 ? -offset_sum_q12_r : offset_sum_q12_r;
    // offset_sum_q12 is (up_offset + down_offset) in units of 1/4096 sample,
    // i.e. 2*timing*4096 = timing*8192. Round timing to the nearest whole
    // sample, ties away from zero, by adding half of that 8192 divisor before
    // truncating -- the same bias-before-shift trick the pre-interpolation
    // code used for its plain divide-by-2 (bias 1, shift 1), generalised to
    // this divisor (bias 4096, shift 13). Confirmed equivalent to the old
    // formula when both fractional parts are zero: with offset_sum_q12 =
    // 4096*offset_sum_old, (4096*offset_sum_old + 4096) >>> 13 collapses to
    // (offset_sum_old + 1) >>> 1.
    wire signed [65:0] rounded_abs =
        (offset_sum_q12_abs + TIMING_ROUND_BIAS_Q12x2) >>> 13;
    wire signed [65:0] rounded_timing =
        offset_sum_q12_r < 0 ? -rounded_abs : rounded_abs;
    // (up + down) / 2 in Q12. Halving the Q12 sum truncates 1/8192 sample,
    // below anything the interpolator resolves.
    wire signed [65:0] timing_q12 = offset_sum_q12_r >>> 1;
    wire signed [65:0] toa_fraction_wide = timing_q12 - (rounded_timing <<< 12);
    wire signed [65:0] cfo_q12_wide =
        ({{1{up_offset_q12[64]}}, up_offset_q12}
         - {{1{down_offset_q12[64]}}, down_offset_q12}) >>> 1;
    wire signed [65:0] toa_coarse_wide =
        $signed({2'b00, up_coarse_start}) + rounded_timing;
    wire timing_in_range =
        (rounded_timing >= -$signed(FINE_GUARD_U64))
        && (rounded_timing <= $signed(FINE_GUARD_U64));
    wire signed [65:0] guarded_skip =
        $signed({2'b00, FINE_GUARD_U64}) + rounded_timing;

    initial begin
        if (SAMPLES_PER_CHIP < 1)
            $error("SAMPLES_PER_CHIP must be positive");
        if (SYMBOL_SAMPLES < 2)
            $error("SYMBOL_SAMPLES must be at least two");
        if (SEARCH_RADIUS < 1)
            $error("SEARCH_RADIUS must be positive");
        if (FINE_GUARD_SAMPLES < SEARCH_RADIUS)
            $error("FINE_GUARD_SAMPLES must cover SEARCH_RADIUS");
    end

    always @(posedge clk) begin
        if (!resetn || stream_reset) begin
            state                     <= STATE_IDLE;
            up_coarse_start           <= 64'd0;
            down_coarse_start         <= 64'd0;
            up_offset_int             <= 65'sd0;
            up_offset_frac_q12        <= 16'sd0;
            down_offset_frac_q12      <= 16'sd0;
            offset_sum_q12_r          <= 66'sd0;
            cfo_q12_r                 <= 66'sd0;
            down_offset_int           <= 65'sd0;
            search_start              <= 1'b0;
            search_coarse_start       <= 64'd0;
            reference_down            <= 1'b0;
            busy                      <= 1'b0;
            timing_correction_samples <= 32'sd0;
            fine_skip                 <= 32'd0;
            fine_resync_valid         <= 1'b0;
            timing_valid              <= 1'b0;
            restart_error             <= 1'b0;
            timing_range_error        <= 1'b0;
            up_search_abort_error     <= 1'b0;
            down_search_abort_error   <= 1'b0;
            precise_correction_applied<= 1'b0;
            toa_coarse                <= 64'd0;
            toa_fraction_q12          <= 32'sd0;
            cfo_q12                   <= 32'sd0;
        end else begin
            search_start       <= 1'b0;
            fine_resync_valid  <= 1'b0;
            timing_valid       <= 1'b0;
            restart_error      <= 1'b0;
            timing_range_error <= 1'b0;
            up_search_abort_error      <= 1'b0;
            down_search_abort_error    <= 1'b0;
            precise_correction_applied <= 1'b0;

            if (packet_start_valid && busy)
                restart_error <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    if (packet_start_valid) begin
                        up_coarse_start <= packet_chirp_start[63:0];
                        down_coarse_start <= packet_chirp_start[63:0]
                            + PREAMBLE_TO_SFD_SYMBOLS * SYMBOL_SAMPLES_U64;
                        search_coarse_start <= packet_chirp_start[63:0];
                        reference_down <= 1'b0;
                        busy <= 1'b1;
                        state <= STATE_LAUNCH_UP;
                    end
                end

                STATE_LAUNCH_UP: begin
                    if (!search_busy
                        && history_next_sample_count >= up_ready_count) begin
                        search_start <= 1'b1;
                        state <= STATE_WAIT_UP;
                    end
                end

                STATE_WAIT_UP: begin
                    if (search_failed) begin
                        // Withholding the guard is unconditional, so returning
                        // it must be too. Abandoning the request here leaves
                        // the grid permanently FINE_GUARD_SAMPLES short, which
                        // is strictly worse than never attempting the
                        // correction. Give the guard back with a zero
                        // correction and degrade to the coarse-only grid.
                        fine_skip <= FINE_GUARD_U64[31:0];
                        fine_resync_valid <= 1'b1;
                        up_search_abort_error <= 1'b1;
                        busy <= 1'b0;
                        state <= STATE_IDLE;
                    end else if (search_triplet_valid) begin
                        up_offset_int <= peak_signed - $signed({1'b0, up_coarse_start});
                        state <= STATE_WAIT_UP_FRAC;
                    end
                end

                STATE_WAIT_UP_FRAC: begin
                    // The interpolator has no failure path and a fixed
                    // latency (38 cycles, 6 for a flat triplet): this pulse
                    // is guaranteed to arrive, nothing to abort here.
                    if (search_offset_valid) begin
                        up_offset_frac_q12 <= search_offset_q12;
                        state <= STATE_WAIT_DOWN_DATA;
                    end
                end

                STATE_WAIT_DOWN_DATA: begin
                    if (history_next_sample_count >= down_ready_count) begin
                        search_coarse_start <= down_coarse_start;
                        reference_down <= 1'b1;
                        state <= STATE_LAUNCH_DOWN;
                    end
                end

                STATE_LAUNCH_DOWN: begin
                    if (!search_busy) begin
                        search_start <= 1'b1;
                        state <= STATE_WAIT_DOWN;
                    end
                end

                STATE_WAIT_DOWN: begin
                    if (search_failed) begin
                        fine_skip <= FINE_GUARD_U64[31:0];
                        fine_resync_valid <= 1'b1;
                        down_search_abort_error <= 1'b1;
                        busy <= 1'b0;
                        state <= STATE_IDLE;
                    end else if (search_triplet_valid) begin
                        down_offset_int <= peak_signed - down_coarse_signed;
                        state <= STATE_WAIT_DOWN_FRAC;
                    end
                end

                STATE_WAIT_DOWN_FRAC: begin
                    if (search_offset_valid) begin
                        down_offset_frac_q12 <= search_offset_q12;
                        state <= STATE_SUM;
                    end
                end

                STATE_SUM: begin
                    offset_sum_q12_r <= offset_sum_q12;
                    cfo_q12_r <= cfo_q12_wide;
                    state <= STATE_DECIDE;
                end

                STATE_DECIDE: begin
                    begin
                        timing_correction_samples <= rounded_timing[31:0];
                        timing_valid <= 1'b1;
                        busy <= 1'b0;
                        state <= STATE_IDLE;
                        if (timing_in_range) begin
                            fine_skip <= guarded_skip[31:0];
                            fine_resync_valid <= 1'b1;
                            precise_correction_applied <= 1'b1;
                            toa_coarse <= toa_coarse_wide[63:0];
                            toa_fraction_q12 <= toa_fraction_wide[31:0];
                            cfo_q12 <= cfo_q12_r[31:0];
                        end else begin
                            // Same rule for a rejected out-of-range estimate:
                            // decline the correction, but still hand back the
                            // guard the coarse resync withheld.
                            fine_skip <= FINE_GUARD_U64[31:0];
                            fine_resync_valid <= 1'b1;
                            timing_range_error <= 1'b1;
                        end
                    end
                end

                default: begin
                    busy <= 1'b0;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
