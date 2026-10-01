`timescale 1ns/1ps

// CLG400 board adapter for the portable LoRa timestamp receiver.
//
// The AD9361 FIFO supplies signed, formatted complex samples on the divided
// AD9361 data clock. That clock is not a fixed frequency: util_clkdiv divides
// the AD9361 data clock by four and the data clock is four times the sample
// rate, so it equals the sample rate exactly, at every rate the part can be
// programmed to. Clocking the receiver from it gave the fabric one clock per
// sample where the joint up/down search budget assumes sixty-three, which is
// why the search could never finish inside a packet. The receiver therefore
// runs on a fixed PL clock and rx_clk carries only the arriving samples, which
// cross in lora_async_sample_fifo.
//
// The course axi_gpreg control/status block lives on sys_cpu_clk, so this
// wrapper uses a request/acknowledge toggle to transfer each complete 128-bit
// timestamp record atomically. The payload is held stable from request until
// acknowledgement; only the toggles pass through ordinary two-flop
// synchronizers.
module lora_clg400_gpreg_bridge #(
    parameter REFERENCE_FILE = "fpga/rom/lora_sf7_l8_reference_q10.mem"
) (
    input  wire                    ctrl_clk,
    input  wire                    ctrl_resetn,
    input  wire                    sample_clk,
    input  wire                    sample_resetn,
    input  wire                    rx_clk,
    input  wire                    rx_resetn,
    input  wire [31:0]             gp_ctrl,
    input  wire [32:0]             rx_sample_bus,

    output wire [31:0]             gp_status,
    output wire [31:0]             gp_sequence,
    output wire [31:0]             gp_coarse_lo,
    output wire [31:0]             gp_coarse_hi,
    output wire [31:0]             gp_fractional_q12,
    output wire [31:0]             gp_log_peak_q12,
    output wire [31:0]             gp_debug,
    output wire [31:0]             gp_signature
);

    localparam [31:0] SIGNATURE = 32'h4c4f5241; // "LORA"

    wire                    rx_bus_valid = rx_sample_bus[32];
    wire signed [15:0]      rx_bus_i = rx_sample_bus[31:16];
    wire signed [15:0]      rx_bus_q = rx_sample_bus[15:0];

    wire [31:0] rx_payload;
    wire        rx_valid;
    wire        rx_cdc_overflow;
    wire [15:0] rx_cdc_drop_count;

    lora_async_sample_fifo #(
        .WIDTH(32),
        .ADDR_WIDTH(4)
    ) u_rx_sample_cdc (
        .wr_clk(rx_clk),
        .wr_resetn(rx_resetn),
        .wr_valid(rx_bus_valid),
        .wr_data({rx_bus_i, rx_bus_q}),
        .wr_overflow(rx_cdc_overflow),
        .rd_clk(sample_clk),
        .rd_resetn(sample_resetn),
        .rd_valid(rx_valid),
        .rd_data(rx_payload),
        .rd_drop_count(rx_cdc_drop_count)
    );

    wire signed [15:0]      rx_i = rx_payload[31:16];
    wire signed [15:0]      rx_q = rx_payload[15:0];

    (* ASYNC_REG = "TRUE" *) reg [31:0] ctrl_sample_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] ctrl_sample_sync;

    wire receiver_requested = ctrl_sample_sync[0];
    wire stream_reset = !receiver_requested || ctrl_sample_sync[1];
    // gp_ctrl bit layout: 0 receiver_requested, 1 stream_reset, 2 trace_rearm,
    // 3 decision-history freeze, 4 decision-history page select,
    // 8-15 configured_sync_word, 16/17/18 symbol/clock/joint page select,
    // 24-30 trace read index, which with 19-23 above it is also the 12-bit
    // decision-history read index. Bits 5-7 and 31 are unused.
    //
    // trace_rearm re-arms the one-shot 128-entry symbol trace and the grid
    // resync's "armed" latch for the next packet without stream_reset's
    // wider effect of zeroing the absolute sample counter in
    // lora_iq_history_buffer -- see docs/clg400-joint-grid-experiment.md,
    // the M6 investigation, for why a long capture campaign needs this
    // distinction and why every other module in the receiver already
    // returns to a ready state between packets on its own.
    wire trace_rearm = ctrl_sample_sync[2];
    // Holding bit 3 stops the decision-history ring so software can read it;
    // see lora_decision_history_buffer.v.
    wire history_freeze = ctrl_sample_sync[3];
    wire [7:0] configured_sync_word =
        (ctrl_sample_sync[15:8] == 8'h00) ? 8'h12 : ctrl_sample_sync[15:8];

    wire [63:0] metadata_coarse;
    wire signed [31:0] metadata_fractional_q12;
    wire metadata_valid;
    wire metadata_overflow;
    wire signed [31:0] toa_log_peak_q12;
    wire toa_search_busy;
    wire [63:0] packet_start_count;
    wire packet_start_valid;
    wire correlation_magnitude_valid;
    wire peak_triplet_valid;
    wire toa_offset_valid;
    wire alignment_error;
    wire symbol_index_width_error;
    wire toa_underflow_error;
    wire toa_search_restart_error;
    wire toa_mac_window_mismatch_error;
    wire toa_mac_read_miss_error;
    wire toa_mac_response_mismatch_error;
    wire toa_mac_restart_error;
    wire toa_peak_boundary_error;
    wire toa_peak_restart_error;
    wire internal_receiver_enable;
    wire [31:0] symbol_index;
    wire symbol_valid;
    wire [15:0] symbol_confidence;
    wire [63:0] symbol_sample_count;
    wire symbol_timestamp_valid;
    wire packet_detected;
    wire [15:0] preamble_bin;
    wire grid_resync_armed;
    wire [15:0] chips_to_boundary;
    wire [63:0] joint_up_coarse_start;
    wire signed [31:0] joint_up_offset_samples;
    wire signed [31:0] joint_timing_correction_samples;
    wire joint_timing_valid;
    // Split, unconflated joint-controller outcomes (see
    // lora_packet_toa_receiver_top.v): distinguish an up-search abort from a
    // down-search abort from an out-of-range rejection, plus a positive
    // "the precise correction was actually applied" flag that timing_valid
    // alone cannot give (it also pulses on a rejected estimate).
    wire joint_up_search_abort_error;
    wire joint_down_search_abort_error;
    wire joint_timing_range_error;
    wire joint_precise_correction_applied;
    // The detector accepted the sync word only through its straddle-tolerant
    // path (M7): a packet the generated rule alone would have lost.
    wire packet_straddle_detected;
    // ... or only through its split-tolerant path (M9).
    wire packet_split_detected;
    // ... or only through its early-sync path.
    wire packet_early_sync_detected;

    wire unused_awready;
    wire unused_wready;
    wire [1:0] unused_bresp;
    wire unused_bvalid;
    wire unused_arready;
    wire [31:0] unused_rdata;
    wire [1:0] unused_rresp;
    wire unused_rvalid;

    lora_packet_toa_receiver_top #(
        .DEFAULT_RECEIVER_ENABLE(1'b1),
        .REFERENCE_FILE(REFERENCE_FILE)
    ) u_receiver (
        .clk(sample_clk),
        .resetn(sample_resetn),
        .iq_in_re(rx_i),
        .iq_in_im(rx_q),
        .valid_in(rx_valid && receiver_requested),
        .reset_in(stream_reset),
        .trace_rearm_in(trace_rearm),
        .resync_valid(1'b0),
        .resync_skip(32'd0),
        .sync_word(configured_sync_word),

        .s_axi_awaddr(6'd0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(unused_awready),
        .s_axi_wdata(32'd0),
        .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(unused_wready),
        .s_axi_bresp(unused_bresp),
        .s_axi_bvalid(unused_bvalid),
        .s_axi_bready(1'b1),
        .s_axi_araddr(6'd0),
        .s_axi_arvalid(1'b0),
        .s_axi_arready(unused_arready),
        .s_axi_rdata(unused_rdata),
        .s_axi_rresp(unused_rresp),
        .s_axi_rvalid(unused_rvalid),
        .s_axi_rready(1'b1),

        .receiver_enable(internal_receiver_enable),
        .symbol_index(symbol_index),
        .symbol_valid(symbol_valid),
        .symbol_confidence(symbol_confidence),
        .symbol_sample_count(symbol_sample_count),
        .symbol_timestamp_valid(symbol_timestamp_valid),
        .detected(packet_detected),
        .packet_straddle_detected(packet_straddle_detected),
        .packet_split_detected(packet_split_detected),
        .packet_early_sync_detected(packet_early_sync_detected),
        .preamble_detected(),
        .sync_valid(),
        .preamble_bin(preamble_bin),
        .grid_resync_armed(grid_resync_armed),
        .chips_to_boundary(chips_to_boundary),
        .joint_up_coarse_start(joint_up_coarse_start),
        .joint_up_offset_samples(joint_up_offset_samples),
        .joint_timing_correction_samples(joint_timing_correction_samples),
        .joint_timing_valid(joint_timing_valid),
        .joint_up_search_abort_error(joint_up_search_abort_error),
        .joint_down_search_abort_error(joint_down_search_abort_error),
        .joint_timing_range_error(joint_timing_range_error),
        .joint_precise_correction_applied(joint_precise_correction_applied),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .toa_search_busy(toa_search_busy),
        .toa_search_first_count(),
        .correlation_magnitude(),
        .correlation_magnitude_valid(correlation_magnitude_valid),
        .correlation_sample_count(),
        .peak_index(),
        .peak_sample_count(),
        .peak_triplet_valid(peak_triplet_valid),
        .toa_offset_q12(),
        .toa_offset_valid(toa_offset_valid),
        .toa_log_peak_q12(toa_log_peak_q12),
        .metadata_coarse(metadata_coarse),
        .metadata_fractional_q12(metadata_fractional_q12),
        .metadata_valid(metadata_valid),
        .history_next_sample_count(),
        .history_oldest_sample_count(),
        .history_samples_retained(),
        .alignment_error(alignment_error),
        .symbol_index_width_error(symbol_index_width_error),
        .metadata_overflow(metadata_overflow),
        .toa_underflow_error(toa_underflow_error),
        .toa_search_restart_error(toa_search_restart_error),
        .toa_mac_window_mismatch_error(toa_mac_window_mismatch_error),
        .toa_mac_read_miss_error(toa_mac_read_miss_error),
        .toa_mac_response_mismatch_error(toa_mac_response_mismatch_error),
        .toa_mac_restart_error(toa_mac_restart_error),
        .toa_peak_boundary_error(toa_peak_boundary_error),
        .toa_peak_restart_error(toa_peak_restart_error)
    );

    // Sample-domain event mailbox. A new record may replace the holding
    // register only after the control domain acknowledges the previous one.
    reg [127:0] event_hold_sample;
    reg event_request_toggle;
    reg bridge_overflow_sample;
    reg packet_seen_sample;
    reg sample_seen_sample;
    reg [15:0] packet_start_count_low_sample;
    reg [14:0] diagnostic_sticky_sample;
    (* ASYNC_REG = "TRUE" *) reg event_ack_meta;
    (* ASYNC_REG = "TRUE" *) reg event_ack_sync;

    // Control-domain mailbox receiver.
    (* ASYNC_REG = "TRUE" *) reg event_request_meta;
    (* ASYNC_REG = "TRUE" *) reg event_request_sync;
    reg event_ack_toggle;
    reg snapshot_valid_ctrl;
    reg [31:0] timestamp_sequence_ctrl;
    reg [31:0] timestamp_coarse_lo_ctrl;
    reg [31:0] timestamp_coarse_hi_ctrl;
    reg [31:0] timestamp_fractional_ctrl;
    reg [31:0] timestamp_log_peak_ctrl;

    // A second software page exposes a frozen 128-decision symbol trace while
    // preserving the qualified timestamp ABI at page zero. gp_ctrl[16] selects
    // the page and gp_ctrl[30:24] selects a trace entry. The trace starts with
    // the first SFD decision after the detector pulse.
    wire [31:0] trace_symbol_index_ctrl;
    wire [63:0] trace_sample_count_ctrl;
    wire [15:0] trace_confidence_ctrl;
    wire [7:0] trace_flags_ctrl;
    wire [15:0] trace_preamble_bin_ctrl;
    wire [7:0] trace_captured_count_ctrl;
    wire trace_capture_active_ctrl;
    wire trace_capture_complete_ctrl;
    wire [31:0] trace_capture_sequence_ctrl;

    lora_symbol_trace_buffer #(
        .TRACE_DEPTH(128),
        .TRACE_ADDR_WIDTH(7)
    ) u_symbol_trace (
        .sample_clk(sample_clk),
        .sample_resetn(sample_resetn),
        .stream_reset(stream_reset || trace_rearm),
        .packet_detected(packet_detected),
        .preamble_bin(preamble_bin),
        .symbol_index(symbol_index),
        .symbol_valid(symbol_valid),
        .confidence(symbol_confidence),
        .symbol_sample_count(symbol_sample_count),
        .symbol_timestamp_valid(symbol_timestamp_valid),
        .ctrl_clk(ctrl_clk),
        .ctrl_resetn(ctrl_resetn),
        .ctrl_read_index(gp_ctrl[30:24]),
        .ctrl_symbol_index(trace_symbol_index_ctrl),
        .ctrl_sample_count(trace_sample_count_ctrl),
        .ctrl_confidence(trace_confidence_ctrl),
        .ctrl_flags(trace_flags_ctrl),
        .ctrl_preamble_bin(trace_preamble_bin_ctrl),
        .ctrl_captured_count(trace_captured_count_ctrl),
        .ctrl_capture_active(trace_capture_active_ctrl),
        .ctrl_capture_complete(trace_capture_complete_ctrl),
        .ctrl_capture_sequence(trace_capture_sequence_ctrl)
    );

    // Every detector decision, detected packet or not (see the module header
    // for the five M7 misses this is for).
    wire [11:0] history_read_index_ctrl = {gp_ctrl[23:19], gp_ctrl[30:24]};
    wire [31:0] history_sample_count_ctrl;
    wire [7:0]  history_bin_ctrl;
    wire [15:0] history_confidence_ctrl;
    wire [7:0]  history_drop_low_ctrl;
    wire [7:0]  history_flags_ctrl;
    wire [11:0] history_newest_ctrl;
    wire [31:0] history_written_ctrl;
    wire        history_frozen_ctrl;

    lora_decision_history_buffer #(
        .ADDR_WIDTH(12)
    ) u_decision_history (
        .sample_clk(sample_clk),
        .sample_resetn(sample_resetn),
        .freeze(history_freeze),
        .symbol_valid(symbol_valid),
        .symbol_index(symbol_index),
        .confidence(symbol_confidence),
        .symbol_sample_count(symbol_sample_count),
        .packet_detected(packet_detected),
        .straddle_detected(packet_straddle_detected),
        .grid_resync_armed(grid_resync_armed),
        .drop_count(rx_cdc_drop_count),
        .ctrl_clk(ctrl_clk),
        .ctrl_resetn(ctrl_resetn),
        .ctrl_read_index(history_read_index_ctrl),
        .ctrl_sample_count(history_sample_count_ctrl),
        .ctrl_bin(history_bin_ctrl),
        .ctrl_confidence(history_confidence_ctrl),
        .ctrl_drop_low(history_drop_low_ctrl),
        .ctrl_flags(history_flags_ctrl),
        .ctrl_newest_index(history_newest_ctrl),
        .ctrl_written_count(history_written_ctrl),
        .ctrl_frozen(history_frozen_ctrl)
    );

    // The crossing's drop count, re-crossed to the control domain as Gray
    // code (it advances by at most one per sample clock).
    wire [15:0] drop_gray_sample = rx_cdc_drop_count ^ (rx_cdc_drop_count >> 1);
    (* ASYNC_REG = "TRUE" *) reg [15:0] drop_gray_ctrl_meta;
    (* ASYNC_REG = "TRUE" *) reg [15:0] drop_gray_ctrl_sync;
    reg [15:0] drop_count_ctrl;
    integer drop_bit;
    always @(posedge ctrl_clk) begin
        if (!ctrl_resetn) begin
            drop_gray_ctrl_meta <= 16'd0;
            drop_gray_ctrl_sync <= 16'd0;
            drop_count_ctrl     <= 16'd0;
        end else begin
            drop_gray_ctrl_meta <= drop_gray_sample;
            drop_gray_ctrl_sync <= drop_gray_ctrl_meta;
            for (drop_bit = 0; drop_bit < 16; drop_bit = drop_bit + 1)
                drop_count_ctrl[drop_bit] <= ^(drop_gray_ctrl_sync >> drop_bit);
        end
    end

    // Joint estimator numbers, frozen when the estimate completes.
    //
    // The correction the board applies is not the one the reference model
    // derives from the same packet, but the two are measured from
    // different origins - the board's from packet_start_count plus
    // chips_to_boundary, the model's from the trace alignment - so
    // comparing them compares nothing. These are the inputs and the
    // intermediate, which put both sides in one epoch.
    reg [31:0] joint_correction_sample;
    reg [31:0] joint_up_offset_sample;
    reg [31:0] joint_up_coarse_sample;
    reg [31:0] joint_packet_start_sample;
    reg [15:0] joint_chips_sample;
    reg [15:0] joint_preamble_bin_sample;
    reg        joint_seen_sample;
    // Sticky per-outcome bits, one per silent path plus one for genuine
    // success. Unlike joint_seen_sample (which only means "an estimate
    // completed", true for both an applied and a rejected correction) and
    // unlike joint_timing_valid (a one-cycle pulse that never fires at all
    // on an abort), these let software tell all four outcomes apart after
    // the fact from a single frozen read. Cleared by stream_reset or by
    // trace_rearm, like the rest of this page (M6): a capture campaign that
    // re-arms with trace_rearm between packets needs each packet's own
    // outcome, not every earlier packet's abort still latched in from the
    // start of the whole campaign.
    reg        joint_up_abort_sticky_sample;
    reg        joint_down_abort_sticky_sample;
    reg        joint_range_error_sticky_sample;
    reg        joint_precise_applied_sticky_sample;
    // Sticky like the four above (joint_status bit 5): at least one packet
    // since the last re-arm was accepted through the straddle-tolerant path.
    reg        joint_straddle_sticky_sample;
    // joint_status bit 6: at least one packet since the last re-arm was
    // accepted only through the split-tolerant path (M9).
    reg        joint_split_sticky_sample;
    reg        joint_early_sticky_sample;

    always @(posedge sample_clk) begin
        if (!sample_resetn) begin
            joint_correction_sample   <= 32'd0;
            joint_up_offset_sample    <= 32'd0;
            joint_up_coarse_sample    <= 32'd0;
            joint_packet_start_sample <= 32'd0;
            joint_chips_sample        <= 16'd0;
            joint_preamble_bin_sample <= 16'd0;
            joint_seen_sample         <= 1'b0;
            joint_up_abort_sticky_sample        <= 1'b0;
            joint_down_abort_sticky_sample      <= 1'b0;
            joint_range_error_sticky_sample     <= 1'b0;
            joint_precise_applied_sticky_sample <= 1'b0;
            joint_straddle_sticky_sample        <= 1'b0;
            joint_split_sticky_sample           <= 1'b0;
            joint_early_sticky_sample           <= 1'b0;
        end else if (stream_reset || trace_rearm) begin
            joint_seen_sample         <= 1'b0;
            joint_up_abort_sticky_sample        <= 1'b0;
            joint_down_abort_sticky_sample      <= 1'b0;
            joint_range_error_sticky_sample     <= 1'b0;
            joint_precise_applied_sticky_sample <= 1'b0;
            joint_straddle_sticky_sample        <= 1'b0;
            joint_split_sticky_sample           <= 1'b0;
            joint_early_sticky_sample           <= 1'b0;
        end else begin
            if (packet_straddle_detected)
                joint_straddle_sticky_sample <= 1'b1;
            if (packet_split_detected)
                joint_split_sticky_sample <= 1'b1;
            if (packet_early_sync_detected)
                joint_early_sticky_sample <= 1'b1;
            if (joint_up_search_abort_error)
                joint_up_abort_sticky_sample <= 1'b1;
            if (joint_down_search_abort_error)
                joint_down_abort_sticky_sample <= 1'b1;
            if (joint_timing_range_error)
                joint_range_error_sticky_sample <= 1'b1;
            if (joint_precise_correction_applied)
                joint_precise_applied_sticky_sample <= 1'b1;

            if (joint_timing_valid) begin
                joint_correction_sample   <= joint_timing_correction_samples;
                joint_up_offset_sample    <= joint_up_offset_samples;
                joint_up_coarse_sample    <= joint_up_coarse_start[31:0];
                joint_packet_start_sample <= packet_start_count[31:0];
                joint_chips_sample        <= chips_to_boundary;
                joint_preamble_bin_sample <= preamble_bin;
                joint_seen_sample         <= 1'b1;
            end
        end
    end

    // Clock accounting, measured in the receiver's own domain.
    //
    // That the receiver used to get one clock per sample was established from
    // the util_clkdiv divider setting and ADI's clock monitor on the AD9361
    // data clock - both static facts, neither of them a measurement at the
    // point that matters. An earlier estimate of the same quantity, taken from
    // how long toa_search_busy stayed high, was wrong by more than a factor of
    // two. These counters measure it where it is actually consumed, so the
    // fixed-clock rebuild can be checked rather than believed.
    reg [31:0] sample_interval_count;
    reg [31:0] sample_interval_last;
    reg [14:0] sample_interval_min;
    reg        sample_interval_seen;
    reg [31:0] search_clock_count;
    reg [31:0] search_clock_last;
    reg [15:0] search_done_count;
    reg        search_busy_delayed;
    reg        rx_cdc_overflow_sample;

    always @(posedge sample_clk) begin
        if (!sample_resetn) begin
            sample_interval_count  <= 32'd0;
            sample_interval_last   <= 32'd0;
            sample_interval_min    <= 15'h7fff;
            sample_interval_seen   <= 1'b0;
            search_clock_count     <= 32'd0;
            search_clock_last      <= 32'd0;
            search_done_count      <= 16'd0;
            search_busy_delayed    <= 1'b0;
            rx_cdc_overflow_sample <= 1'b0;
        end else begin
            // Sticky across a stream reset: a dropped sample invalidates every
            // sample count that follows it, including in the capture before.
            if (rx_cdc_overflow)
                rx_cdc_overflow_sample <= 1'b1;

            if (stream_reset) begin
                sample_interval_count <= 32'd0;
                sample_interval_last  <= 32'd0;
                sample_interval_min   <= 15'h7fff;
                sample_interval_seen  <= 1'b0;
                search_clock_count    <= 32'd0;
                search_clock_last     <= 32'd0;
                search_done_count     <= 16'd0;
                search_busy_delayed   <= 1'b0;
            end else begin
                if (rx_valid) begin
                    sample_interval_count <= 32'd1;
                    sample_interval_seen  <= 1'b1;
                    if (sample_interval_seen) begin
                        sample_interval_last <= sample_interval_count;
                        if (sample_interval_count < {17'd0, sample_interval_min})
                            sample_interval_min <= sample_interval_count[14:0];
                    end
                end else if (!(&sample_interval_count)) begin
                    sample_interval_count <= sample_interval_count + 32'd1;
                end

                search_busy_delayed <= toa_search_busy;
                if (toa_search_busy) begin
                    search_clock_count <= search_clock_count + 32'd1;
                end else if (search_busy_delayed) begin
                    search_clock_last <= search_clock_count;
                    search_clock_count <= 32'd0;
                    if (!(&search_done_count))
                        search_done_count <= search_done_count + 16'd1;
                end else begin
                    search_clock_count <= 32'd0;
                end
            end
        end
    end

    // Low-rate diagnostic flags cross independently; they are status only and
    // do not form part of the atomic timestamp record.
    (* ASYNC_REG = "TRUE" *) reg [4:0] status_meta;
    (* ASYNC_REG = "TRUE" *) reg [4:0] status_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] debug_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] debug_sync;
    // Status only: the flag is static once a capture has frozen, so software
    // never samples it while the sample domain is changing it.
    (* ASYNC_REG = "TRUE" *) reg grid_resync_meta;
    (* ASYNC_REG = "TRUE" *) reg grid_resync_sync;
    // Clock accounting is static between captures, so software never reads it
    // while the sample domain is changing it. Two flops each, like the other
    // status words.
    (* ASYNC_REG = "TRUE" *) reg [31:0] diag_interval_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] diag_interval_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] diag_search_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] diag_search_sync;
    (* ASYNC_REG = "TRUE" *) reg joint_seen_meta;
    (* ASYNC_REG = "TRUE" *) reg joint_seen_sync;
    // {precise_applied, range_error, down_abort, up_abort}: see
    // joint_*_sticky_sample above.
    (* ASYNC_REG = "TRUE" *) reg [3:0] joint_sticky_meta;
    (* ASYNC_REG = "TRUE" *) reg [3:0] joint_sticky_sync;
    (* ASYNC_REG = "TRUE" *) reg       joint_straddle_meta;
    (* ASYNC_REG = "TRUE" *) reg       joint_straddle_sync;
    (* ASYNC_REG = "TRUE" *) reg       joint_split_meta;
    (* ASYNC_REG = "TRUE" *) reg       joint_split_sync;
    (* ASYNC_REG = "TRUE" *) reg       joint_early_meta;
    (* ASYNC_REG = "TRUE" *) reg       joint_early_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_a_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_a_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_b_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_b_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_c_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_c_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_d_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_d_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_e_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] joint_e_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] diag_misc_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] diag_misc_sync;

    always @(posedge sample_clk) begin
        if (!sample_resetn) begin
            ctrl_sample_meta      <= 32'd0;
            ctrl_sample_sync      <= 32'd0;
            event_ack_meta        <= 1'b0;
            event_ack_sync        <= 1'b0;
            event_hold_sample     <= 128'd0;
            event_request_toggle  <= 1'b0;
            bridge_overflow_sample<= 1'b0;
            packet_seen_sample    <= 1'b0;
            sample_seen_sample    <= 1'b0;
            packet_start_count_low_sample <= 16'd0;
            diagnostic_sticky_sample <= 15'd0;
        end else begin
            ctrl_sample_meta <= gp_ctrl;
            ctrl_sample_sync <= ctrl_sample_meta;
            event_ack_meta   <= event_ack_toggle;
            event_ack_sync   <= event_ack_meta;

            // packet_seen/sample_seen/packet_start_count_low are page-0's own
            // continuous liveness bits (host tooling already reads page 0
            // without ever pulsing a reset between packets) and stay tied to
            // stream_reset only, not trace_rearm: a capture campaign that
            // re-arms the symbol trace between packets must not also wipe
            // page 0's independent, already-continuous history.
            if (stream_reset) begin
                packet_seen_sample <= 1'b0;
                sample_seen_sample <= 1'b0;
                packet_start_count_low_sample <= 16'd0;
            end else begin
                if (rx_valid)
                    sample_seen_sample <= 1'b1;
                if (packet_start_valid) begin
                    packet_seen_sample <= 1'b1;
                    packet_start_count_low_sample <= packet_start_count[15:0];
                end
            end

            // diagnostic_sticky_sample belongs to the symbol-trace page (M6):
            // it is per-capture diagnostic like the joint_*_sticky_sample
            // bits above, so it clears on trace_rearm too, not only on a full
            // stream_reset.
            if (stream_reset || trace_rearm) begin
                diagnostic_sticky_sample <= 15'd0;
            end else begin
                diagnostic_sticky_sample <= diagnostic_sticky_sample | {
                    alignment_error,
                    symbol_index_width_error,
                    toa_underflow_error,
                    toa_search_restart_error,
                    toa_mac_window_mismatch_error,
                    toa_mac_read_miss_error,
                    toa_mac_response_mismatch_error,
                    toa_mac_restart_error,
                    toa_peak_boundary_error,
                    toa_peak_restart_error,
                    toa_search_busy,
                    correlation_magnitude_valid,
                    peak_triplet_valid,
                    toa_offset_valid,
                    metadata_valid
                };
            end

            if (metadata_overflow)
                bridge_overflow_sample <= 1'b1;

            if (metadata_valid) begin
                if (event_request_toggle == event_ack_sync) begin
                    event_hold_sample <= {
                        toa_log_peak_q12,
                        metadata_fractional_q12,
                        metadata_coarse
                    };
                    event_request_toggle <= !event_request_toggle;
                end else begin
                    bridge_overflow_sample <= 1'b1;
                end
            end
        end
    end

    always @(posedge ctrl_clk) begin
        if (!ctrl_resetn) begin
            event_request_meta <= 1'b0;
            event_request_sync <= 1'b0;
            event_ack_toggle   <= 1'b0;
            status_meta        <= 5'd0;
            status_sync        <= 5'd0;
            debug_meta         <= 32'd0;
            debug_sync         <= 32'd0;
            grid_resync_meta   <= 1'b1;
            grid_resync_sync   <= 1'b1;
            diag_interval_meta <= 32'd0;
            diag_interval_sync <= 32'd0;
            diag_search_meta   <= 32'd0;
            diag_search_sync   <= 32'd0;
            diag_misc_meta     <= 32'd0;
            diag_misc_sync     <= 32'd0;
            joint_seen_meta    <= 1'b0;
            joint_seen_sync    <= 1'b0;
            joint_sticky_meta  <= 4'd0;
            joint_sticky_sync  <= 4'd0;
            joint_straddle_meta <= 1'b0;
            joint_straddle_sync <= 1'b0;
            joint_split_meta <= 1'b0;
            joint_split_sync <= 1'b0;
            joint_early_meta <= 1'b0;
            joint_early_sync <= 1'b0;
            joint_a_meta       <= 32'd0;
            joint_a_sync       <= 32'd0;
            joint_b_meta       <= 32'd0;
            joint_b_sync       <= 32'd0;
            joint_c_meta       <= 32'd0;
            joint_c_sync       <= 32'd0;
            joint_d_meta       <= 32'd0;
            joint_d_sync       <= 32'd0;
            joint_e_meta       <= 32'd0;
            joint_e_sync       <= 32'd0;
            timestamp_sequence_ctrl  <= 32'd0;
            timestamp_coarse_lo_ctrl <= 32'd0;
            timestamp_coarse_hi_ctrl <= 32'd0;
            timestamp_fractional_ctrl<= 32'd0;
            timestamp_log_peak_ctrl  <= 32'd0;
            snapshot_valid_ctrl<= 1'b0;
        end else begin
            event_request_meta <= event_request_toggle;
            event_request_sync <= event_request_meta;
            status_meta <= {
                sample_seen_sample,
                packet_seen_sample,
                toa_search_busy,
                bridge_overflow_sample,
                receiver_requested
            };
            status_sync <= status_meta;
            debug_meta <= {
                diagnostic_sticky_sample,
                internal_receiver_enable,
                packet_start_count_low_sample
            };
            debug_sync <= debug_meta;
            grid_resync_meta <= grid_resync_armed;
            grid_resync_sync <= grid_resync_meta;
            diag_interval_meta <= sample_interval_last;
            diag_interval_sync <= diag_interval_meta;
            diag_search_meta   <= search_clock_last;
            diag_search_sync   <= diag_search_meta;
            diag_misc_meta     <= {rx_cdc_overflow_sample,
                                   sample_interval_min,
                                   search_done_count};
            diag_misc_sync     <= diag_misc_meta;
            joint_seen_meta <= joint_seen_sample;
            joint_seen_sync <= joint_seen_meta;
            joint_sticky_meta <= {
                joint_precise_applied_sticky_sample,
                joint_range_error_sticky_sample,
                joint_down_abort_sticky_sample,
                joint_up_abort_sticky_sample
            };
            joint_sticky_sync <= joint_sticky_meta;
            joint_straddle_meta <= joint_straddle_sticky_sample;
            joint_straddle_sync <= joint_straddle_meta;
            joint_split_meta <= joint_split_sticky_sample;
            joint_split_sync <= joint_split_meta;
            joint_early_meta <= joint_early_sticky_sample;
            joint_early_sync <= joint_early_meta;
            joint_a_meta <= joint_correction_sample;
            joint_a_sync <= joint_a_meta;
            joint_b_meta <= joint_up_offset_sample;
            joint_b_sync <= joint_b_meta;
            joint_c_meta <= joint_up_coarse_sample;
            joint_c_sync <= joint_c_meta;
            joint_d_meta <= joint_packet_start_sample;
            joint_d_sync <= joint_d_meta;
            joint_e_meta <= {joint_chips_sample, joint_preamble_bin_sample};
            joint_e_sync <= joint_e_meta;

            if (event_request_sync != event_ack_toggle) begin
                timestamp_coarse_lo_ctrl <= event_hold_sample[31:0];
                timestamp_coarse_hi_ctrl <= event_hold_sample[63:32];
                timestamp_fractional_ctrl<= event_hold_sample[95:64];
                timestamp_log_peak_ctrl  <= event_hold_sample[127:96];
                timestamp_sequence_ctrl  <= timestamp_sequence_ctrl + 32'd1;
                snapshot_valid_ctrl<= 1'b1;
                event_ack_toggle   <= event_request_sync;
            end
        end
    end

    wire [31:0] timestamp_status = {
        16'h0001,
        gp_ctrl[15:8],
        gp_ctrl[1],
        status_sync[4],
        status_sync[3],
        status_sync[2],
        status_sync[1],
        snapshot_valid_ctrl,
        status_sync[0],
        gp_ctrl[0]
    };
    wire [31:0] timestamp_debug = debug_sync;
    // The decision-history page wins over every other page; software that
    // never sets bit 4 sees the existing ABI unchanged.
    wire history_page_selected = gp_ctrl[4];
    wire joint_page_selected = gp_ctrl[18];
    wire symbol_page_selected =
        gp_ctrl[16] && !gp_ctrl[17] && !joint_page_selected;
    // bit 0: an estimate completed (applied or declined) -- unchanged, for
    // compatibility with already-saved captures and tools/read_clg400_symbol_trace.py.
    // bit 1: up-search aborted at least once since stream_reset.
    // bit 2: down-search aborted at least once since stream_reset.
    // bit 3: an estimate was rejected as outside +/-FINE_GUARD_SAMPLES.
    // bit 4: a precise correction was actually applied to the grid.
    // bit 5: at least one packet was accepted only through the detector's
    //        straddle-tolerant path (M7), sticky like bits 4:1.
    // bit 6: ... only through its split-tolerant path (M9), sticky likewise.
    // bit 7: ... only through its early-sync path, sticky likewise.
    // bits 15:8 are reserved, zero.
    wire [31:0] joint_status = {
        16'h4a54, // "JT": joint estimator ABI marker
        8'd0,
        joint_early_sync,
        joint_split_sync,
        joint_straddle_sync,
        joint_sticky_sync,
        joint_seen_sync
    };
    // A third page reports what the receiver clock actually is, in the
    // receiver's own domain. gp_ctrl[17] selects it and wins over the symbol
    // page, so the existing two-page ABI is untouched for software that never
    // sets it.
    wire clock_page_selected = gp_ctrl[17] && !joint_page_selected;
    wire [31:0] clock_status = {
        16'h434b, // "CK": clock-accounting ABI marker
        15'd0,
        diag_misc_sync[31] // receive crossing dropped a sample
    };
    wire [31:0] trace_status = {
        16'h5359, // "SY": symbol-trace ABI version marker
        6'd0,
        trace_capture_complete_ctrl,
        trace_capture_active_ctrl,
        trace_captured_count_ctrl
    };
    // Bit 8 reports that the symbol grid was realigned for this capture. It
    // separates "the aligner never fired" from "it fired and the arithmetic is
    // wrong", which are otherwise indistinguishable from the decoded trace and
    // cost a rebuild and a cold boot to tell apart.
    wire [31:0] trace_debug = {
        trace_preamble_bin_ctrl,
        gp_ctrl[30:24],
        ~grid_resync_sync,
        trace_captured_count_ctrl
    };

    wire [31:0] history_status = {
        16'h4448, // "DH": decision-history ABI marker
        3'd0,
        history_frozen_ctrl,
        history_newest_ctrl
    };

    assign gp_status = history_page_selected ? history_status :
        joint_page_selected ? joint_status :
        clock_page_selected ? clock_status :
        symbol_page_selected ? trace_status : timestamp_status;
    // Clocks between the last two accepted samples: sixty-three says the
    // receiver is on the fixed PL clock, one says it is back on the AD9361
    // divided data clock.
    assign gp_sequence = history_page_selected ? history_written_ctrl :
        joint_page_selected ? joint_a_sync :
        clock_page_selected ? diag_interval_sync :
        symbol_page_selected ? trace_capture_sequence_ctrl : timestamp_sequence_ctrl;
    // Clocks the last joint search held the fabric, against a budget of
    // 2304 samples of SFD.
    assign gp_coarse_lo = history_page_selected ? history_sample_count_ctrl :
        joint_page_selected ? joint_b_sync :
        clock_page_selected ? diag_search_sync :
        symbol_page_selected ? trace_symbol_index_ctrl : timestamp_coarse_lo_ctrl;
    assign gp_coarse_hi = history_page_selected ?
        {history_flags_ctrl, history_drop_low_ctrl, history_confidence_ctrl} :
        joint_page_selected ? joint_c_sync :
        clock_page_selected ? {17'd0, diag_misc_sync[30:16]} :
        symbol_page_selected ? trace_sample_count_ctrl[31:0] : timestamp_coarse_hi_ctrl;
    assign gp_fractional_q12 = history_page_selected ? {24'd0, history_bin_ctrl} :
        joint_page_selected ? joint_d_sync :
        clock_page_selected ? {16'd0, diag_misc_sync[15:0]} :
        symbol_page_selected ? trace_sample_count_ctrl[63:32] : timestamp_fractional_ctrl;
    // Samples the receive crossing has dropped since boot, live, on both the
    // history and the clock page: read before and after an attempt, it says
    // whether that attempt lost samples.
    assign gp_log_peak_q12 = (history_page_selected || clock_page_selected) ?
        {16'd0, drop_count_ctrl} :
        joint_page_selected ? joint_e_sync :
        symbol_page_selected ?
        {8'd0, trace_flags_ctrl, trace_confidence_ctrl} : timestamp_log_peak_ctrl;
    assign gp_debug = history_page_selected ?
        {4'd0, history_read_index_ctrl, 16'd0} :
        symbol_page_selected ? trace_debug : timestamp_debug;
    assign gp_signature = SIGNATURE;

endmodule
