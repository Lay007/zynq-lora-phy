`timescale 1ns/1ps

// Compose the generated fixed-point FFT correlator with the generated blind
// detector and hand-written detector timestamp alignment path.
//
// The generated correlator remains behind fft_correlator_route_top so the
// historical generic DUT name and future ModulePrefix regeneration share one
// integration boundary. All symbol/timestamp sidebands remain cycle-aligned.
module lora_fft_detector_timestamp_path (
    input  wire               clk,
    input  wire               resetn,
    input  wire signed [15:0] iq_in_re,
    input  wire signed [15:0] iq_in_im,
    input  wire               valid_in,
    input  wire               reset_in,
    input  wire               resync_valid,
    input  wire [31:0]        resync_skip,
    input  wire [7:0]         sync_word,
    // Carrier-offset removal ahead of the correlator (see lora_cfo_derotator):
    // cfo_load starts rotating by cfo_q12 (the joint estimate's displacement,
    // Q12 samples); cfo_clear stops. Tie all three low to leave the sample
    // stream untouched (it is then only delayed, bit for bit).
    input  wire               cfo_load,
    input  wire signed [31:0] cfo_q12,
    input  wire               cfo_clear,
    // Re-arms the accumulating preamble detector without a stream reset
    // (the capture path's trace re-arm), like lora_symbol_grid_resync.
    input  wire               accum_rearm,

    output wire [31:0]        symbol_index,
    output wire               symbol_valid,
    output wire [15:0]        confidence,
    output wire [63:0]        symbol_sample_count,
    output wire               timestamp_valid,

    output wire               detected,
    output wire               straddle_detected,
    output wire               split_detected,
    output wire               early_sync_detected,
    // High in the same cycle as `detected` when only the accumulated-preamble
    // path (#36) accepted the packet; accum_triggered pulses when the
    // accumulator fired and shifted the grid (a diagnostic: it also fires on
    // packets that another path then detects, and ~once per 17 min on noise).
    output wire               accum_detected,
    output wire               accum_triggered,
    output wire               preamble_detected,
    output wire               sync_valid,
    output wire [15:0]        preamble_bin,
    output wire [15:0]        chips_to_boundary,
    output wire [7:0]         bins_seen,

    output wire [63:0]        preamble_start_count,
    output wire               preamble_start_valid,
    output wire [63:0]        packet_start_count,
    output wire               packet_start_valid,
    output wire               alignment_error,
    output wire               symbol_index_width_error
);

    wire fft_ce_out;
    wire [15:0] peak_magnitude_squared;
    wire [15:0] spectrum_sum;
    wire symbol_boundary;

    // The grid-resync skip is applied inside the generated correlator, so the
    // request travels through the derotator's delay together with the samples
    // and the correlator sees the same sample/request order as without it.
    wire signed [15:0] rot_re;
    wire signed [15:0] rot_im;
    wire               rot_valid;
    wire               rot_resync_valid;
    wire [31:0]        rot_resync_skip;

    // Accumulating preamble detector (#36). Its grid shift joins the caller's
    // resync request ahead of the derotator, so it travels with the samples
    // exactly as that one does; the caller's request (the payload realignment
    // and the fine correction) wins if both are ever raised together.
    wire [39:0]  bin_power;
    wire [31:0]  bin_index;
    wire         bin_valid;
    wire         accum_request;
    wire [31:0]  accum_skip;
    wire         accum_aligned;
    wire         merged_resync_valid = resync_valid || accum_request;
    wire [31:0]  merged_resync_skip = resync_valid ? resync_skip : accum_skip;

    lora_cfo_derotator u_cfo_derotator (
        .clk(clk),
        .resetn(resetn),
        .in_re(iq_in_re),
        .in_im(iq_in_im),
        .in_valid(valid_in),
        .in_resync_valid(merged_resync_valid),
        .in_resync_skip(merged_resync_skip),
        .in_stream_reset(reset_in),
        .load(cfo_load),
        .cfo_q12(cfo_q12),
        .clear(cfo_clear),
        .out_re(rot_re),
        .out_im(rot_im),
        .out_valid(rot_valid),
        .out_resync_valid(rot_resync_valid),
        .out_resync_skip(rot_resync_skip),
        .out_stream_reset(),
        .rotating()
    );

    fft_correlator_route_top u_fft_correlator (
        .clk(clk),
        .reset(~resetn),
        .iqIn_re(rot_re),
        .iqIn_im(rot_im),
        .validIn(rot_valid),
        .resetIn(reset_in),
        .resyncValid(rot_resync_valid),
        .resyncSkip(rot_resync_skip),
        .ce_out(fft_ce_out),
        .symbolIndex(symbol_index),
        .symbolValid(symbol_valid),
        .confidence(confidence),
        .peakMagnitudeSquared(peak_magnitude_squared),
        .spectrumSum(spectrum_sum),
        .symbolBoundary(symbol_boundary),
        .symbolSampleCount(symbol_sample_count),
        .timestampValid(timestamp_valid),
        .binPower(bin_power),
        .binIndex(bin_index),
        .binValid(bin_valid)
    );

    lora_preamble_accumulator u_preamble_accumulator (
        .clk(clk),
        .resetn(resetn),
        .stream_reset(reset_in || accum_rearm),
        .enable(1'b1),
        .sample_valid(valid_in),
        .packet_detected(detected),
        .bin_power(bin_power),
        .bin_index(bin_index),
        .bin_valid(bin_valid),
        .window_done(symbol_valid),
        .resync_request(accum_request),
        .resync_skip(accum_skip),
        .aligned(accum_aligned),
        .trigger_bin(),
        .trigger_fraction(),
        .triggered(accum_triggered)
    );

    // symbol_valid is the actual transaction qualifier. Keeping the generated
    // detector enabled whenever the FFT path is enabled preserves HDL Coder's
    // state-update semantics while allowing arbitrary gaps in valid_in.
    lora_detector_timestamp_path u_detector_timestamp (
        .clk(clk),
        .resetn(resetn),
        .clk_enable(fft_ce_out),
        .reset_in(reset_in),
        .symbol_index(symbol_index),
        .symbol_valid(symbol_valid),
        .symbol_sample_count(symbol_sample_count),
        .timestamp_valid(timestamp_valid),
        .symbol_peak(peak_magnitude_squared),
        .sync_word(sync_word),
        .accum_aligned(accum_aligned),
        .detected(detected),
        .straddle_detected(straddle_detected),
        .split_detected(split_detected),
        .early_sync_detected(early_sync_detected),
        .accum_detected(accum_detected),
        .preamble_detected(preamble_detected),
        .sync_valid(sync_valid),
        .preamble_bin(preamble_bin),
        .chips_to_boundary(chips_to_boundary),
        .bins_seen(bins_seen),
        .preamble_start_count(preamble_start_count),
        .preamble_start_valid(preamble_start_valid),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .alignment_error(alignment_error),
        .symbol_index_width_error(symbol_index_width_error)
    );

endmodule
