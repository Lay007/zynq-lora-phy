// Replay a recorded IQ window through the real receiver top and print what
// it decides. This is how the ~7% of packets the detector never saw were
// reproduced and explained (docs/clg400-joint-grid-experiment.md, M7).
//
// The stimulus is a hex file, one 32-bit word per sample ({I[15:0], Q[15:0]},
// the layout tools/replay_iq_through_rtl.py writes), driven one sample per
// clock. Detection does not care about the clock ratio; the joint search
// does, so the search runs to completion after the last sample and its
// outcome is printed, but read that as "what it concluded", not "whether it
// met the SFD deadline".
//
// Output lines: SYM <bin> <window origin>, PRE <bin> <chips> n=<sample>,
// SYN n=<sample>, DET <bin> <chips> n=<sample> straddle=<0|1> split=<0|1> early=<0|1>, META <coarse> <frac_q12>, PSC <packet_start_count>
// n=<sample>, JNT <joint controller result>, DONE.
//
// Compile from the repo root (the reference ROM path is relative) with the
// receiver-top source list from .github/workflows/ci.yml:
//   iverilog -g2012 -DLORA_NAMESPACED_GENERATED -s tb_replay_detect \
//     -o replay_tb <sources> fpga/tb/tb_replay_detect.sv

`timescale 1ns/1ps

module tb_replay_detect;
    localparam integer SF = 7;
    localparam integer SAMPLES_PER_CHIP = 8;
    parameter integer HISTORY_DEPTH = 65536;
    localparam integer SYMBOL_COUNT = (1 << SF);
    localparam integer SAMPLES_PER_SYMBOL = SYMBOL_COUNT * SAMPLES_PER_CHIP;
    localparam real PI = 3.14159265358979323846;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg signed [15:0] iq_in_re = 16'sd0;
    reg signed [15:0] iq_in_im = 16'sd0;
    reg valid_in = 1'b0;
    reg reset_in = 1'b0;
    reg trace_rearm_in = 1'b0;
    reg resync_valid = 1'b0;
    reg [31:0] resync_skip = 32'd0;
    reg [7:0] sync_word = 8'h12;

    reg [5:0] awaddr = 6'd0;
    reg awvalid = 1'b0;
    wire awready;
    reg [31:0] wdata = 32'd0;
    reg [3:0] wstrb = 4'd0;
    reg wvalid = 1'b0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready = 1'b0;
    reg [5:0] araddr = 6'd0;
    reg arvalid = 1'b0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready = 1'b0;

    wire receiver_enable;
    wire [31:0] symbol_index;
    wire symbol_valid;
    wire detected;
    wire preamble_detected;
    wire sync_valid;
    wire [63:0] packet_start_count;
    wire packet_start_valid;
    wire grid_resync_armed;
    wire toa_search_busy;
    wire [63:0] toa_search_first_count;
    wire [31:0] correlation_magnitude;
    wire correlation_magnitude_valid;
    wire [63:0] correlation_sample_count;
    wire [15:0] peak_index;
    wire [63:0] peak_sample_count;
    wire peak_triplet_valid;
    wire signed [31:0] toa_offset_q12;
    wire toa_offset_valid;
    wire signed [31:0] toa_log_peak_q12;
    wire [63:0] metadata_coarse;
    wire signed [31:0] metadata_fractional_q12;
    wire metadata_valid;
    wire [63:0] history_next_sample_count;
    wire [63:0] history_oldest_sample_count;
    wire [31:0] history_samples_retained;
    wire alignment_error;
    wire symbol_index_width_error;
    wire metadata_overflow;
    wire toa_underflow_error;
    wire toa_search_restart_error;
    wire toa_mac_window_mismatch_error;
    wire toa_mac_read_miss_error;
    wire toa_mac_response_mismatch_error;
    wire toa_mac_restart_error;
    wire toa_peak_boundary_error;
    wire toa_peak_restart_error;

    integer errors = 0;
    integer packet_start_seen = 0;
    integer metadata_seen = 0;
    integer joint_fine_resync_seen = 0;
    integer joint_search_failed_seen = 0;
    integer timeout_cycles = 0;
    reg [63:0] captured_metadata_coarse [0:1];
    reg signed [31:0] captured_metadata_fractional [0:1];
    reg [63:0] history_count_before_rearm = 64'd0;
    reg [63:0] history_count_at_second_start = 64'd0;

    lora_packet_toa_receiver_top #(.HISTORY_DEPTH(HISTORY_DEPTH)) dut (
        .clk(clk), .resetn(resetn),
        .iq_in_re(iq_in_re), .iq_in_im(iq_in_im), .valid_in(valid_in),
        .reset_in(reset_in), .trace_rearm_in(trace_rearm_in),
        .resync_valid(resync_valid),
        .resync_skip(resync_skip), .sync_word(sync_word),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata),
        .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .receiver_enable(receiver_enable), .symbol_index(symbol_index),
        .symbol_valid(symbol_valid), .detected(detected),
        .preamble_detected(preamble_detected), .sync_valid(sync_valid),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .grid_resync_armed(grid_resync_armed),
        .toa_search_busy(toa_search_busy),
        .toa_search_first_count(toa_search_first_count),
        .correlation_magnitude(correlation_magnitude),
        .correlation_magnitude_valid(correlation_magnitude_valid),
        .correlation_sample_count(correlation_sample_count),
        .peak_index(peak_index), .peak_sample_count(peak_sample_count),
        .peak_triplet_valid(peak_triplet_valid),
        .toa_offset_q12(toa_offset_q12), .toa_offset_valid(toa_offset_valid),
        .toa_log_peak_q12(toa_log_peak_q12),
        .metadata_coarse(metadata_coarse),
        .metadata_fractional_q12(metadata_fractional_q12),
        .metadata_valid(metadata_valid),
        .history_next_sample_count(history_next_sample_count),
        .history_oldest_sample_count(history_oldest_sample_count),
        .history_samples_retained(history_samples_retained),
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


    reg [31:0] mem [0:262143];
    integer n_samples = 0;
    integer i;
    integer det_count = 0;
    reg [4095:0] iq_file;
    integer sample_cnt = 0;
    integer joint_wait = 0;
    integer wait_joint = 1;
    // +gap=N: one sample every N clocks, as on the board (about 63). With the
    // default 1 the joint search finishes after the whole stream, so nothing
    // that depends on its result in time (grid correction, CFO removal) acts
    // on the packet's own symbols.
    integer gap = 1;
    // +gap_det=N: one sample every N clocks only from the detection until the
    // joint search reports, 1 elsewhere. That is the only stretch where the
    // clocks-per-sample ratio changes anything (the search has to finish before
    // the header), so the header and payload decisions come out as with +gap
    // for the whole stream, in a small fraction of the simulated clocks.
    integer gap_det = 1;
    integer g;
    integer this_gap;
    reg det_seen = 1'b0;
    reg joint_done = 1'b0;

    task automatic axi_write(input [5:0] address, input [31:0] value);
        begin
            @(negedge clk);
            awaddr = address; awvalid = 1'b1;
            wdata = value; wstrb = 4'hf; wvalid = 1'b1;
            while (!(awready && wready)) @(negedge clk);
            @(negedge clk);
            awvalid = 1'b0; wvalid = 1'b0; wstrb = 4'd0;
            while (!bvalid) @(negedge clk);
            bready = 1'b1;
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (resetn) begin
            if (valid_in) sample_cnt = sample_cnt + 1;
            if (symbol_valid)
                $display("SYM %0d %0d", symbol_index, dut.symbol_sample_count);
            if (preamble_detected)
                $display("PRE %0d %0d n=%0d", dut.preamble_bin, dut.chips_to_boundary, sample_cnt);
            if (packet_start_valid)
                $display("PSC %0d n=%0d", packet_start_count, sample_cnt);
            if (dut.g_joint_grid_timing.u_joint_grid_timing.fine_resync_valid) begin
                joint_done <= 1'b1;
                $display("JNT up_coarse=%0d corr=%0d range=%0d upab=%0d dnab=%0d precise=%0d up_off=%0d skip=%0d",
                         dut.g_joint_grid_timing.u_joint_grid_timing.up_coarse_start,
                         $signed(dut.g_joint_grid_timing.u_joint_grid_timing.timing_correction_samples),
                         dut.g_joint_grid_timing.u_joint_grid_timing.timing_range_error,
                         dut.g_joint_grid_timing.u_joint_grid_timing.up_search_abort_error,
                         dut.g_joint_grid_timing.u_joint_grid_timing.down_search_abort_error,
                         dut.g_joint_grid_timing.u_joint_grid_timing.precise_correction_applied,
                         $signed(dut.g_joint_grid_timing.u_joint_grid_timing.diag_up_offset_samples),
                         dut.g_joint_grid_timing.u_joint_grid_timing.fine_skip);
            end
            if (sync_valid)
                $display("SYN n=%0d", sample_cnt);
            // The packet's final timestamp as software receives it: coarse
            // sample count and Q12 fraction (the up leg's peak, see
            // lora_packet_toa_receiver_top's u_metadata_join).
            if (metadata_valid)
                $display("META %0d %0d", metadata_coarse, $signed(metadata_fractional_q12));
            if (detected) begin
                det_seen = 1'b1;
                det_count = det_count + 1;
`ifdef REPLAY_NO_SPLIT
                $display("DET %0d %0d n=%0d straddle=%0d split=0 early=0", dut.preamble_bin, dut.chips_to_boundary,
                         sample_cnt, dut.packet_straddle_detected);
`else
                $display("DET %0d %0d n=%0d straddle=%0d split=%0d early=%0d", dut.preamble_bin, dut.chips_to_boundary,
                         sample_cnt, dut.packet_straddle_detected, dut.packet_split_detected,
                         dut.packet_early_sync_detected);
`endif
            end
        end
    end

    initial begin
        if (!$value$plusargs("iq=%s", iq_file)) begin
            $display("FAIL no +iq=");
            $fatal(1);
        end
        if (!$value$plusargs("n=%d", n_samples)) n_samples = 0;
        // +wait_joint=0: stop after the last sample instead of waiting for
        // the joint search (much faster when only detection matters).
        if (!$value$plusargs("wait_joint=%d", wait_joint)) wait_joint = 1;
        if (!$value$plusargs("gap=%d", gap)) gap = 1;
        if (!$value$plusargs("gap_det=%d", gap_det)) gap_det = 1;
        $readmemh(iq_file, mem);
        $display("MEM %h %h %h n=%0d file=[%0s]", mem[0], mem[5000], mem[9000], n_samples, iq_file);
        repeat (6) @(posedge clk);
        resetn <= 1'b1;
        repeat (3) @(posedge clk);
        axi_write(6'h00, 32'h0000_0001);
        for (i = 0; i < n_samples; i = i + 1) begin
            @(negedge clk);
            iq_in_re <= $signed(mem[i][31:16]);
            iq_in_im <= $signed(mem[i][15:0]);
            valid_in <= 1'b1;
            this_gap = (det_seen && !joint_done && gap_det > gap) ? gap_det : gap;
            for (g = 1; g < this_gap; g = g + 1) begin
                @(negedge clk);
                valid_in <= 1'b0;
            end
        end
        @(negedge clk);
        valid_in <= 1'b0;
        iq_in_re <= 16'sd0;
        iq_in_im <= 16'sd0;
        joint_wait = 0;
        while (wait_joint != 0 && !joint_done && joint_wait < 450000) begin
            @(posedge clk);
            joint_wait = joint_wait + 1;
        end
        repeat (50) @(posedge clk);
        $display("DONE detected=%0d samples=%0d", det_count, sample_cnt);
        $finish;
    end
endmodule
