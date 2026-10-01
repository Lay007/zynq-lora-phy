`timescale 1ns/1ps

// Complete portable SF7/L=8 packet timestamp path.
//
// Accepted IQ samples feed both the generated symbol/acquisition path and a
// circular sample history. A confirmed packet timestamp automatically starts a
// short, packet-rate matched-filter search around that coarse sample. The
// strongest preamble lag and the generated log-parabolic fractional estimate
// are joined atomically and exposed through AXI4-Lite. The same packet-rate MAC
// is then reused on the first full SFD downchirp; the up/down half-sum supplies
// a fine sample-grid correction before the header reaches the correlator.
//
// This top is intentionally single-clock. The board adapter must cross AD936x
// samples into this domain and cross the joined metadata record into the PS AXI
// domain if those clocks differ. It must not synchronize the multiword record
// with unrelated two-flop synchronizers.
`ifdef LORA_NAMESPACED_GENERATED
`define LORA_TOA_INTERPOLATOR_MODULE lora_toa_ToaInterpolator
`else
`define LORA_TOA_INTERPOLATOR_MODULE ToaInterpolator
`endif

module lora_packet_toa_receiver_top #(
    parameter integer AUTO_GRID_RESYNC = 1,
    parameter integer HISTORY_DEPTH = 65536,
    parameter integer REF_SAMPLES = 1024,
    parameter integer SEARCH_RADIUS = 16,
    parameter integer GRID_FINE_GUARD_SAMPLES = 16,
    parameter integer MATCH_ACC_WIDTH = 48,
    parameter integer MATCH_POWER_SHIFT = 30,
    parameter DEFAULT_RECEIVER_ENABLE = 1'b0,
    parameter REFERENCE_FILE = "fpga/rom/lora_sf7_l8_reference_q10.mem"
) (
    input  wire               clk,
    input  wire               resetn,

    input  wire signed [15:0] iq_in_re,
    input  wire signed [15:0] iq_in_im,
    input  wire               valid_in,
    input  wire               reset_in,
    // Re-arms lora_symbol_grid_resync's one-shot "armed" latch without the
    // rest of reset_in's effect (the absolute sample counter in
    // lora_iq_history_buffer, the FFT detector's internal state, and every
    // other module here besides this one already return to a ready state on
    // their own between packets -- see the M6 investigation in
    // docs/clg400-joint-grid-experiment.md). Ties into the same
    // stream_reset port lora_symbol_grid_resync already had; that module is
    // unmodified.
    input  wire               trace_rearm_in,
    input  wire               resync_valid,
    input  wire [31:0]        resync_skip,
    input  wire [7:0]         sync_word,

    input  wire [5:0]         s_axi_awaddr,
    input  wire               s_axi_awvalid,
    output wire               s_axi_awready,
    input  wire [31:0]        s_axi_wdata,
    input  wire [3:0]         s_axi_wstrb,
    input  wire               s_axi_wvalid,
    output wire               s_axi_wready,
    output wire [1:0]         s_axi_bresp,
    output wire               s_axi_bvalid,
    input  wire               s_axi_bready,

    input  wire [5:0]         s_axi_araddr,
    input  wire               s_axi_arvalid,
    output wire               s_axi_arready,
    output wire [31:0]        s_axi_rdata,
    output wire [1:0]         s_axi_rresp,
    output wire               s_axi_rvalid,
    input  wire               s_axi_rready,

    output wire               receiver_enable,

    output wire [31:0]        symbol_index,
    output wire               symbol_valid,
    output wire [15:0]        symbol_confidence,
    output wire [63:0]        symbol_sample_count,
    output wire               symbol_timestamp_valid,
    output wire               detected,
    // High in the same cycle as `detected` when the sync word was accepted
    // only by the detector's straddle-tolerant path (M7).
    output wire               packet_straddle_detected,
    // The detector accepted the packet only through its split-tolerant path
    // (M9), in the same cycle as `detected`.
    output wire               packet_split_detected,
    // ... or only through its early-sync path (the tie window at half a
    // symbol read as the first sync symbol).
    output wire               packet_early_sync_detected,
    output wire               preamble_detected,
    output wire               sync_valid,
    output wire [15:0]        preamble_bin,
    output wire [15:0]        chips_to_boundary,
    output wire               grid_resync_armed,
    output wire [15:0]        grid_resync_chips,
    output wire [63:0]        packet_start_count,
    output wire               packet_start_valid,

    output wire               toa_search_busy,
    output wire [63:0]        toa_search_first_count,
    output wire [31:0]        correlation_magnitude,
    output wire               correlation_magnitude_valid,
    output wire [63:0]        correlation_sample_count,
    output wire [15:0]        peak_index,
    output wire [63:0]        peak_sample_count,
    output wire               peak_triplet_valid,
    output wire signed [31:0] toa_offset_q12,
    output wire               toa_offset_valid,
    output wire signed [31:0] toa_log_peak_q12,

    output wire [63:0]        metadata_coarse,
    output wire signed [31:0] metadata_fractional_q12,
    output wire               metadata_valid,

    output wire [63:0]        history_next_sample_count,
    output wire [63:0]        history_oldest_sample_count,
    output wire [31:0]        history_samples_retained,

    output wire               alignment_error,
    output wire               symbol_index_width_error,
    output wire               metadata_overflow,
    output wire               toa_underflow_error,
    output wire               toa_search_restart_error,
    output wire               toa_mac_window_mismatch_error,
    output wire               toa_mac_read_miss_error,
    output wire               toa_mac_response_mismatch_error,
    output wire               toa_mac_restart_error,
    output wire               toa_peak_boundary_error,
    output wire               toa_peak_restart_error,
    // Joint estimator diagnostics. Held from the cycle the estimate
    // completes until the next stream reset, so software can compare
    // what the search was told, what it found, and what it concluded
    // against the reference model in one epoch.
    output wire [63:0]        joint_up_coarse_start,
    output wire signed [31:0] joint_up_offset_samples,
    output wire signed [31:0] joint_timing_correction_samples,
    output wire               joint_timing_valid,
    // Split, unconflated joint-controller outcomes. Previously these three
    // were OR'd into the single-search's own toa_search_restart_error /
    // toa_peak_boundary_error bits (see the removed comment below this
    // module's joint controller instance), which meant an abort of either
    // joint search, an out-of-range rejection, and the plain single-search's
    // own restart/boundary conditions were indistinguishable from software.
    output wire               joint_up_search_abort_error,
    output wire               joint_down_search_abort_error,
    output wire               joint_timing_range_error,
    output wire               joint_precise_correction_applied
);

    wire gated_valid_in = valid_in && receiver_enable;
    wire datapath_resetn = resetn && !reset_in;

    // HDL Coder implements the active-high reset of the generated ToA block as
    // an asynchronous clear. Do not drive those clear pins from the
    // combinational resetn/reset_in expression: that creates a LUT-controlled
    // asynchronous reset which can glitch. Register the stream-reset request;
    // global reset still asserts this register asynchronously and all release
    // paths are clocked.
    reg toa_reset_reg;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)
            toa_reset_reg <= 1'b1;
        else
            toa_reset_reg <= reset_in;
    end

    wire [7:0] bins_seen_unused;
    wire [63:0] preamble_start_count_unused;
    wire preamble_start_valid_unused;

    // A caller-supplied request wins, so an integration that owns its own
    // timing policy keeps the port it always had. With nothing driving it the
    // receiver aligns its own grid to the packet it just acquired.
    // Declared here because the correlator path below uses them before the
    // joint controller that drives them is instantiated.
    wire joint_grid_precise_correction_applied;
    wire signed [31:0] joint_cfo_q12;

    wire auto_resync_valid;
    wire [31:0] auto_resync_skip;
    wire fine_resync_valid;
    wire [31:0] fine_resync_skip;
    wire effective_resync_valid = resync_valid || auto_resync_valid;
    wire [31:0] effective_resync_skip =
        resync_valid ? resync_skip : auto_resync_skip;

    generate
        if (AUTO_GRID_RESYNC != 0) begin : g_grid_resync
            lora_symbol_grid_resync #(
                .SPREADING_FACTOR(7),
                .SAMPLES_PER_CHIP(8),
                .FINE_GUARD_SAMPLES(GRID_FINE_GUARD_SAMPLES)
            ) u_grid_resync (
                .clk(clk),
                .resetn(resetn),
                .stream_reset(reset_in || trace_rearm_in),
                .sample_valid(gated_valid_in),
                .packet_detected(detected),
                .chips_to_boundary(chips_to_boundary),
                .fine_resync_valid(fine_resync_valid),
                .fine_resync_skip(fine_resync_skip),
                .resync_valid(auto_resync_valid),
                .resync_skip(auto_resync_skip),
                .resync_armed(grid_resync_armed),
                .resync_chips(grid_resync_chips)
            );
        end else begin : g_no_grid_resync
            assign auto_resync_valid = 1'b0;
            assign auto_resync_skip = 32'd0;
            assign grid_resync_armed = 1'b0;
            assign grid_resync_chips = 16'd0;
        end
    endgenerate

    wire detector_straddle;
    assign packet_straddle_detected = detector_straddle;

    lora_fft_detector_timestamp_path u_fft_detector_timestamp (
        .clk(clk),
        .resetn(resetn),
        .iq_in_re(iq_in_re),
        .iq_in_im(iq_in_im),
        .valid_in(gated_valid_in),
        .reset_in(reset_in),
        .resync_valid(effective_resync_valid),
        .resync_skip(effective_resync_skip),
        .sync_word(sync_word),
        // Remove the packet's carrier offset from every decision after the
        // joint estimate (see lora_cfo_derotator): start on the precise
        // correction, stop at the next detection, re-arm or reset, so the
        // preamble of the next packet is searched on the raw stream as
        // before. The IQ history the joint search reads stays raw.
        .cfo_load(joint_grid_precise_correction_applied),
        .cfo_q12(joint_cfo_q12),
        .cfo_clear(detected || reset_in || trace_rearm_in),
        .symbol_index(symbol_index),
        .symbol_valid(symbol_valid),
        .confidence(symbol_confidence),
        .symbol_sample_count(symbol_sample_count),
        .timestamp_valid(symbol_timestamp_valid),
        .detected(detected),
        .straddle_detected(detector_straddle),
        .split_detected(packet_split_detected),
        .early_sync_detected(packet_early_sync_detected),
        .preamble_detected(preamble_detected),
        .sync_valid(sync_valid),
        .preamble_bin(preamble_bin),
        .chips_to_boundary(chips_to_boundary),
        .bins_seen(bins_seen_unused),
        .preamble_start_count(preamble_start_count_unused),
        .preamble_start_valid(preamble_start_valid_unused),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .alignment_error(alignment_error),
        .symbol_index_width_error(symbol_index_width_error)
    );

    wire history_read_req;
    wire [63:0] history_read_sample_count;
    wire signed [15:0] history_read_iq_re;
    wire signed [15:0] history_read_iq_im;
    wire [63:0] history_read_sample_count_out;
    wire history_read_valid;
    wire history_read_miss;

    lora_iq_history_buffer #(
        .DEPTH(HISTORY_DEPTH)
    ) u_iq_history (
        .clk(clk),
        .resetn(resetn),
        .stream_reset(reset_in),
        .iq_in_re(iq_in_re),
        .iq_in_im(iq_in_im),
        .sample_valid(gated_valid_in),
        .read_req(history_read_req),
        .read_sample_count(history_read_sample_count),
        .read_iq_re(history_read_iq_re),
        .read_iq_im(history_read_iq_im),
        .read_sample_count_out(history_read_sample_count_out),
        .read_valid(history_read_valid),
        .read_miss(history_read_miss),
        .next_sample_count(history_next_sample_count),
        .oldest_sample_count(history_oldest_sample_count),
        .samples_retained(history_samples_retained)
    );

    wire [15:0] reference_index;
    wire signed [15:0] reference_re;
    wire signed [15:0] reference_up_im;
    wire reference_down;
    wire signed [15:0] reference_im =
        reference_down ? -reference_up_im : reference_up_im;

    lora_reference_chirp_rom #(
        .REF_SAMPLES(REF_SAMPLES),
        .INIT_FILE(REFERENCE_FILE)
    ) u_reference_rom (
        .reference_index(reference_index),
        .reference_re(reference_re),
        .reference_im(reference_up_im)
    );

    wire [31:0] magnitude_before;
    wire [31:0] magnitude_peak;
    wire [31:0] magnitude_after;
    wire raw_search_busy;
    wire raw_peak_triplet_valid;
    wire raw_search_restart_error;
    wire raw_peak_boundary_error;
    wire joint_grid_busy;
    wire joint_grid_restart_error;
    wire joint_grid_timing_range_error;
    wire joint_grid_up_search_abort_error;
    wire joint_grid_down_search_abort_error;
    wire joint_search_start;
    wire [63:0] joint_search_coarse_start;
    wire signed [31:0] joint_timing_correction_unused;
    wire joint_timing_valid_unused;
    // CFO-free packet time of arrival from the joint up/down pair; see
    // lora_joint_chirp_grid_controller's toa_coarse.
    wire [63:0] joint_toa_coarse;
    wire signed [31:0] joint_toa_fraction_q12;
    // The interpolator's own logPeak (up and down legs alike); the port
    // toa_log_peak_q12 carries the up leg's, see below.
    wire signed [31:0] raw_toa_log_peak_q12;

    // The detector presents chips_to_boundary on `detected`. The joint
    // controller starts on `packet_start_valid`, a later pulse, by which
    // time the detector output has returned to zero, so the controller
    // was always given an arrival phase of zero and searched up to 1016
    // samples away from the chirp it was looking for. Hold the value
    // from the pulse that carries it until the pulse that consumes it.
    // The coarse resync reads the same signal on `detected` and was
    // never affected, which is why only the joint estimate was wrong.
    reg [15:0] held_chips_to_boundary;
    // Held for the same reason: whether the sync word was accepted by the
    // straddle-tolerant path (M7) decides how the controller unwraps the
    // arrival phase, and it too is only valid on `detected`.
    reg        held_packet_straddle;
    always @(posedge clk) begin
        if (!resetn) begin
            held_chips_to_boundary <= 16'd0;
            held_packet_straddle   <= 1'b0;
        end else if (reset_in) begin
            held_chips_to_boundary <= 16'd0;
            held_packet_straddle   <= 1'b0;
        end else if (detected) begin
            held_chips_to_boundary <= chips_to_boundary;
            held_packet_straddle   <= detector_straddle;
        end
    end
    wire raw_search_failure = toa_underflow_error || raw_search_restart_error ||
        toa_mac_window_mismatch_error || toa_mac_read_miss_error ||
        toa_mac_response_mismatch_error || toa_mac_restart_error ||
        raw_peak_boundary_error || toa_peak_restart_error;

    generate
        if (AUTO_GRID_RESYNC != 0) begin : g_joint_grid_timing
            lora_joint_chirp_grid_controller #(
                .SAMPLES_PER_CHIP(8),
                .SYMBOL_SAMPLES(REF_SAMPLES),
                .SEARCH_RADIUS(SEARCH_RADIUS),
                .FINE_GUARD_SAMPLES(GRID_FINE_GUARD_SAMPLES),
                .PREAMBLE_TO_SFD_SYMBOLS(10)
            ) u_joint_grid_timing (
                .clk(clk),
                .resetn(resetn),
                .stream_reset(reset_in),
                .packet_start_valid(packet_start_valid && receiver_enable),
                .packet_start_count(packet_start_count),
                .chips_to_boundary(held_chips_to_boundary),
                .packet_straddle(held_packet_straddle),
                .history_next_sample_count(history_next_sample_count),
                .search_busy(raw_search_busy),
                .search_failed(raw_search_failure),
                .search_triplet_valid(raw_peak_triplet_valid),
                .search_peak_sample_count(peak_sample_count),
                .search_offset_q12(toa_offset_q12[15:0]),
                .search_offset_valid(toa_offset_valid),
                .search_start(joint_search_start),
                .search_coarse_start(joint_search_coarse_start),
                .reference_down(reference_down),
                .busy(joint_grid_busy),
                .timing_correction_samples(joint_timing_correction_unused),
                .diag_up_coarse_start(joint_up_coarse_start),
                .diag_up_offset_samples(joint_up_offset_samples),
                .fine_skip(fine_resync_skip),
                .fine_resync_valid(fine_resync_valid),
                .timing_valid(joint_timing_valid_unused),
                .restart_error(joint_grid_restart_error),
                .timing_range_error(joint_grid_timing_range_error),
                .up_search_abort_error(joint_grid_up_search_abort_error),
                .down_search_abort_error(joint_grid_down_search_abort_error),
                .precise_correction_applied(joint_grid_precise_correction_applied),
                .toa_coarse(joint_toa_coarse),
                .toa_fraction_q12(joint_toa_fraction_q12),
                .cfo_q12(joint_cfo_q12)
            );
        end else begin : g_legacy_toa_search
            assign joint_search_start = packet_start_valid && receiver_enable;
            assign joint_search_coarse_start = packet_start_count;
            assign reference_down = 1'b0;
            assign joint_grid_busy = raw_search_busy;
            assign joint_up_coarse_start = 64'd0;
            assign joint_up_offset_samples = 32'sd0;
            assign fine_resync_skip = 32'd0;
            assign fine_resync_valid = 1'b0;
            assign joint_timing_correction_unused = 32'sd0;
            assign joint_toa_coarse = 64'd0;
            assign joint_toa_fraction_q12 = 32'sd0;
            assign joint_cfo_q12 = 32'sd0;
            assign joint_timing_valid_unused = 1'b0;
            assign joint_grid_restart_error = 1'b0;
            assign joint_grid_timing_range_error = 1'b0;
            assign joint_grid_up_search_abort_error = 1'b0;
            assign joint_grid_down_search_abort_error = 1'b0;
            assign joint_grid_precise_correction_applied = 1'b0;
        end
    endgenerate

    assign toa_search_busy = joint_grid_busy;
    assign joint_timing_correction_samples = joint_timing_correction_unused;
    assign joint_timing_valid = joint_timing_valid_unused;
    assign joint_up_search_abort_error = joint_grid_up_search_abort_error;
    assign joint_down_search_abort_error = joint_grid_down_search_abort_error;
    assign joint_timing_range_error = joint_grid_timing_range_error;
    assign joint_precise_correction_applied = joint_grid_precise_correction_applied;

    assign peak_triplet_valid = raw_peak_triplet_valid && !reference_down;
    // Unconflated: these used to also carry the joint controller's restart,
    // out-of-range, and abort conditions (see joint_up_search_abort_error /
    // joint_down_search_abort_error / joint_timing_range_error above), which
    // meant a joint-search failure looked identical to a plain single-search
    // restart or boundary condition to software. joint_grid_restart_error
    // (a new packet arriving while the joint pair is still in flight) has no
    // dedicated port yet and is intentionally not folded in here either.
    assign toa_search_restart_error = raw_search_restart_error;
    assign toa_peak_boundary_error = raw_peak_boundary_error;

    lora_matched_filter_search #(
        .REF_SAMPLES(REF_SAMPLES),
        .SEARCH_RADIUS(SEARCH_RADIUS),
        .ACC_WIDTH(MATCH_ACC_WIDTH),
        .POWER_SHIFT(MATCH_POWER_SHIFT)
    ) u_toa_search (
        .clk(clk),
        .resetn(resetn),
        .stream_reset(reset_in),
        .start(joint_search_start),
        .coarse_start_count(joint_search_coarse_start),
        .iq_read_req(history_read_req),
        .iq_read_sample_count(history_read_sample_count),
        .iq_read_re(history_read_iq_re),
        .iq_read_im(history_read_iq_im),
        .iq_read_sample_count_out(history_read_sample_count_out),
        .iq_read_valid(history_read_valid),
        .iq_read_miss(history_read_miss),
        .reference_index(reference_index),
        .reference_re(reference_re),
        .reference_im(reference_im),
        .busy(raw_search_busy),
        .search_first_count(toa_search_first_count),
        .correlation_magnitude(correlation_magnitude),
        .correlation_magnitude_valid(correlation_magnitude_valid),
        .correlation_sample_count(correlation_sample_count),
        .magnitude_before(magnitude_before),
        .magnitude_peak(magnitude_peak),
        .magnitude_after(magnitude_after),
        .peak_index(peak_index),
        .peak_sample_count(peak_sample_count),
        .triplet_valid(raw_peak_triplet_valid),
        .underflow_error(toa_underflow_error),
        .search_restart_error(raw_search_restart_error),
        .mac_window_mismatch_error(toa_mac_window_mismatch_error),
        .mac_read_miss_error(toa_mac_read_miss_error),
        .mac_response_mismatch_error(toa_mac_response_mismatch_error),
        .mac_restart_error(toa_mac_restart_error),
        .peak_boundary_error(raw_peak_boundary_error),
        .peak_restart_error(toa_peak_restart_error)
    );

    // Both joint-grid legs share this one interpolator instance, sequenced by
    // the joint controller itself (down never launches until up's own wait
    // states have consumed its triplet), so ungating the trigger here is safe.
    // raw_peak_triplet_valid == peak_triplet_valid whenever reference_down is
    // tied low, which is always true in the g_legacy_toa_search branch, so
    // this is a no-op for that mode and only changes behaviour when the joint
    // controller is active. u_metadata_join below stays on peak_triplet_valid
    // (up leg only) so the legacy single-search metadata semantics are
    // untouched.
    `LORA_TOA_INTERPOLATOR_MODULE u_toa_interpolator (
        .clk(clk),
        .reset(toa_reset_reg),
        .enb(1'b1),
        .magnitudeBefore(magnitude_before),
        .magnitudePeak(magnitude_peak),
        .magnitudeAfter(magnitude_after),
        .tripletValid(raw_peak_triplet_valid),
        .offsetSamples(toa_offset_q12),
        .offsetValid(toa_offset_valid),
        .logPeak(raw_toa_log_peak_q12)
    );

    // The interpolator above now runs for both joint-grid legs (up and down),
    // so its offsetValid pulses twice per packet in joint mode. coarse_valid
    // still only pulses once (up leg). Gate fractional_valid the same way
    // coarse_valid already is, or the down leg's unmatched fractional
    // fragment sits in lora_timestamp_metadata_join waiting for a coarse
    // fragment that never comes, and can wrongly pair with the NEXT packet's
    // coarse count instead. reference_down is guaranteed stable low for the
    // entire up-leg interpolation window and stable high for the entire
    // down-leg one -- the joint controller does not start the down search
    // until its own wait state has consumed the up leg's offsetValid -- so
    // sampling it here reliably attributes each pulse to its leg.
    wire toa_offset_valid_up = toa_offset_valid && !reference_down;

    // Which fragments make the packet's timestamp.
    //
    // With the joint grid it is the controller's toa_coarse/toa_fraction_q12:
    // the up leg's coarse start plus (up + down) / 2, which cancels the
    // carrier offset. It used to be the up leg's peak alone, and an upchirp's
    // matched-filter peak moves by the CFO displacement: measured on 923
    // board captures, the up peak sat -3.15 samples (mean) from the joint
    // timing, equal to the reference model's CFO displacement on the same
    // packets, and on synthetic packets through this RTL the old metadata
    // was off by exactly that displacement. Both fragments now arrive on the
    // precise_correction_applied pulse, after the down leg. A packet whose
    // joint estimate aborts or is rejected gets no timestamp: an up-leg-only
    // value would carry the CFO error, and the joint page's sticky bits say
    // what happened.
    //
    // Without the joint grid (legacy build) nothing changes.
    wire [63:0] metadata_coarse_in = (AUTO_GRID_RESYNC != 0)
        ? joint_toa_coarse : peak_sample_count;
    wire metadata_coarse_valid_in = (AUTO_GRID_RESYNC != 0)
        ? joint_grid_precise_correction_applied : peak_triplet_valid;
    wire signed [31:0] metadata_fraction_in = (AUTO_GRID_RESYNC != 0)
        ? joint_toa_fraction_q12 : toa_offset_q12;
    wire metadata_fraction_valid_in = (AUTO_GRID_RESYNC != 0)
        ? joint_grid_precise_correction_applied : toa_offset_valid_up;

    // The log-peak reported with the timestamp stays the up leg's. The
    // timestamp now completes after the down leg, whose interpolation
    // overwrites the interpolator's logPeak, so hold the up leg's value.
    reg  signed [31:0] held_up_log_peak_q12;
    always @(posedge clk) begin
        if (!resetn)
            held_up_log_peak_q12 <= 32'sd0;
        else if (toa_offset_valid_up)
            held_up_log_peak_q12 <= raw_toa_log_peak_q12;
    end
    assign toa_log_peak_q12 = (AUTO_GRID_RESYNC != 0)
        ? held_up_log_peak_q12 : raw_toa_log_peak_q12;

    lora_timestamp_metadata_join u_metadata_join (
        .clk(clk),
        .resetn(datapath_resetn),
        .coarse_sample_count(metadata_coarse_in),
        .coarse_valid(metadata_coarse_valid_in),
        .fractional_toa_q12(metadata_fraction_in),
        .fractional_valid(metadata_fraction_valid_in),
        .timestamp_coarse(metadata_coarse),
        .timestamp_fractional_q12(metadata_fractional_q12),
        .timestamp_valid(metadata_valid),
        .metadata_overflow(metadata_overflow)
    );

    lora_axi_lite_status #(
        .DEFAULT_RECEIVER_ENABLE(DEFAULT_RECEIVER_ENABLE)
    ) u_axi_status (
        .s_axi_aclk(clk),
        .s_axi_aresetn(resetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .metadata_coarse(metadata_coarse),
        .metadata_fractional_q12(metadata_fractional_q12),
        .metadata_valid(metadata_valid),
        .metadata_overflow(metadata_overflow),
        .receiver_enable(receiver_enable)
    );

endmodule

`undef LORA_TOA_INTERPOLATOR_MODULE
