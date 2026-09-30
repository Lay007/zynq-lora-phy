// M6: a capture campaign must be able to re-arm the symbol trace and the
// grid resync for the next packet without a full stream reset, because a
// full stream reset also zeros the absolute sample counter in
// lora_iq_history_buffer -- the very timebase a long campaign needs to keep.
//
// Nothing in the existing suite drives two packets through the real
// receiver_top (with its real FFT detector, not the alternate BlindDetector
// path) with only one reset_in pulse at the very start. This is that
// regression: packet 1 completes as usual, trace_rearm_in re-arms the grid
// resync (lora_symbol_grid_resync.armed is a one-shot latch that only
// stream_reset used to restore) and the second packet must be detected and
// carried through the joint estimator exactly like the first, with the
// absolute sample counter never dropping.

`timescale 1ns/1ps

module tb_lora_joint_grid_multi_packet;
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

    function automatic integer quantize_q10(input real value);
        real scaled;
        begin
            scaled = value * 1024.0;
            if (scaled >= 0.0)
                quantize_q10 = $rtoi(scaled + 0.5);
            else
                quantize_q10 = $rtoi(scaled - 0.5);
        end
    endfunction

    task automatic drive_css_symbol(input integer symbol_value);
        integer n;
        integer source_n;
        integer q_re;
        integer q_im;
        real phase_cycles;
        real angle;
        begin
            for (n = 0; n < SAMPLES_PER_SYMBOL; n = n + 1) begin
                source_n = (n + symbol_value * SAMPLES_PER_CHIP) %
                           SAMPLES_PER_SYMBOL;
                phase_cycles = (0.5 * source_n * source_n) /
                               (SYMBOL_COUNT * SAMPLES_PER_CHIP *
                                SAMPLES_PER_CHIP) -
                               (0.5 * source_n) / SAMPLES_PER_CHIP;
                angle = 2.0 * PI * phase_cycles;
                q_re = quantize_q10($cos(angle));
                q_im = quantize_q10($sin(angle));
                @(negedge clk);
                iq_in_re <= q_re;
                iq_in_im <= q_im;
                valid_in <= 1'b1;
            end
        end
    endtask

    // A downchirp: the conjugate of symbol 0, for `count` samples (1024 for a
    // full SFD symbol, 256 for the final quarter). The joint grid's down leg
    // searches for it 10 symbols after the first preamble upchirp, so a
    // stimulus without it gives the down search nothing physical to find and
    // the packet timestamp (the joint (up + down) / 2 time) nothing to mean.
    task automatic drive_css_downchirp(input integer count);
        integer n;
        integer source_n;
        integer q_re;
        integer q_im;
        real phase_cycles;
        real angle;
        begin
            for (n = 0; n < count; n = n + 1) begin
                source_n = n;
                phase_cycles = (0.5 * source_n * source_n) /
                               (SYMBOL_COUNT * SAMPLES_PER_CHIP *
                                SAMPLES_PER_CHIP) -
                               (0.5 * source_n) / SAMPLES_PER_CHIP;
                angle = 2.0 * PI * phase_cycles;
                q_re = quantize_q10($cos(angle));
                q_im = quantize_q10(-$sin(angle));
                @(negedge clk);
                iq_in_re <= q_re;
                iq_in_im <= q_im;
                valid_in <= 1'b1;
            end
        end
    endtask

    task automatic drive_silence(input integer count);
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                @(negedge clk);
                iq_in_re <= 16'sd0;
                iq_in_im <= 16'sd0;
                valid_in <= 1'b1;
            end
        end
    endtask

    task automatic drive_packet;
        begin
            drive_css_symbol(37);
            drive_css_symbol(0); drive_css_symbol(0); drive_css_symbol(0);
            drive_css_symbol(0); drive_css_symbol(0); drive_css_symbol(0);
            drive_css_symbol(0); drive_css_symbol(0);
            drive_css_symbol(8); drive_css_symbol(16);
            // A real SFD for the joint grid's down leg, then header symbols
            // so its window completes; same as tb_lora_joint_grid_completion.
            drive_css_downchirp(1024); drive_css_downchirp(1024); drive_css_downchirp(256);
            drive_css_symbol(0); drive_css_symbol(0); drive_css_symbol(0);
            drive_css_symbol(0);
        end
    endtask

    task automatic axi_write(input [5:0] address, input [31:0] value);
        begin
            @(negedge clk);
            awaddr = address; awvalid = 1'b1;
            wdata = value; wstrb = 4'hf; wvalid = 1'b1;
            while (!(awready && wready)) @(negedge clk);
            @(negedge clk);
            awvalid = 1'b0; wvalid = 1'b0; wstrb = 4'd0;
            while (!bvalid) @(negedge clk);
            if (bresp !== 2'b00) errors = errors + 1;
            bready = 1'b1;
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (resetn) begin
            if (packet_start_valid)
                packet_start_seen = packet_start_seen + 1;
            if (dut.g_joint_grid_timing.u_joint_grid_timing.search_failed)
                joint_search_failed_seen = joint_search_failed_seen + 1;
            if (dut.g_joint_grid_timing.u_joint_grid_timing.fine_resync_valid)
                joint_fine_resync_seen = joint_fine_resync_seen + 1;
            if (metadata_valid) begin
                metadata_seen = metadata_seen + 1;
                if (metadata_seen <= 2) begin
                    captured_metadata_coarse[metadata_seen - 1] <= metadata_coarse;
                    captured_metadata_fractional[metadata_seen - 1] <= metadata_fractional_q12;
                end
            end
            if (alignment_error || symbol_index_width_error || metadata_overflow ||
                toa_underflow_error || toa_search_restart_error ||
                toa_mac_window_mismatch_error || toa_mac_read_miss_error ||
                toa_mac_response_mismatch_error || toa_mac_restart_error ||
                toa_peak_restart_error) begin
                errors = errors + 1;
                $display("FAIL receiver error flag: align=%0b symwidth=%0b metaovf=%0b toaunder=%0b searchrestart=%0b macwindow=%0b macreadmiss=%0b macresp=%0b macrestart=%0b peakrestart=%0b",
                         alignment_error, symbol_index_width_error, metadata_overflow,
                         toa_underflow_error, toa_search_restart_error,
                         toa_mac_window_mismatch_error, toa_mac_read_miss_error,
                         toa_mac_response_mismatch_error, toa_mac_restart_error,
                         toa_peak_restart_error);
            end
        end
    end

    initial begin
        repeat (6) @(posedge clk);
        resetn <= 1'b1;
        repeat (3) @(posedge clk);
        axi_write(6'h00, 32'h0000_0001);

        // Packet 1, identical stimulus to tb_lora_joint_grid_completion.
        drive_packet();
        @(negedge clk);
        valid_in <= 1'b0;
        iq_in_re <= 16'sd0;
        iq_in_im <= 16'sd0;

        while (joint_fine_resync_seen < 1 && timeout_cycles < 400000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        repeat (5) @(posedge clk);

        if (joint_fine_resync_seen != 1 || packet_start_seen != 1 || metadata_seen != 1) begin
            errors = errors + 1;
            $display("FAIL packet 1 did not complete: fine_resync=%0d packet_start=%0d metadata=%0d",
                      joint_fine_resync_seen, packet_start_seen, metadata_seen);
        end

        // Confirm the latch is actually disarmed here -- otherwise the check
        // after trace_rearm_in below would prove nothing.
        if (grid_resync_armed !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL grid_resync_armed=%0d after packet 1, expected 0 (test setup invalid)",
                      grid_resync_armed);
        end

        // The point of this test: re-arm with trace_rearm_in, never reset_in,
        // between the two packets. grid_resync_armed must come back to 1 --
        // that is the exact latch a full stream_reset used to be the only
        // way to restore.
        history_count_before_rearm = history_next_sample_count;
        @(negedge clk);
        trace_rearm_in <= 1'b1;
        @(negedge clk);
        trace_rearm_in <= 1'b0;
        repeat (3) @(posedge clk);

        if (grid_resync_armed !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL grid_resync_armed=%0d after trace_rearm_in, expected 1 (re-armed without reset_in)",
                      grid_resync_armed);
        end
        if (history_next_sample_count !== history_count_before_rearm) begin
            errors = errors + 1;
            $display("FAIL absolute sample counter moved on trace_rearm_in alone: before=%0d after=%0d",
                      history_count_before_rearm, history_next_sample_count);
        end

        // A silence gap distinguishes packet 2's arrival from packet 1's tail
        // and gives the coarse resync a real phase to remove again, same as
        // grid_phase does in tb_lora_joint_grid_completion.
        drive_silence(400);
        history_count_at_second_start = history_next_sample_count;
        drive_packet();
        @(negedge clk);
        valid_in <= 1'b0;
        iq_in_re <= 16'sd0;
        iq_in_im <= 16'sd0;

        timeout_cycles = 0;
        while (joint_fine_resync_seen < 2 && timeout_cycles < 400000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        repeat (5) @(posedge clk);

        if (packet_start_seen != 2) begin
            errors = errors + 1;
            $display("FAIL packet starts=%0d, expected 2 (second packet not detected after trace_rearm_in)",
                      packet_start_seen);
        end
        if (metadata_seen != 2) begin
            errors = errors + 1;
            $display("FAIL metadata records=%0d, expected 2", metadata_seen);
        end
        if (joint_fine_resync_seen != 2) begin
            errors = errors + 1;
            $display("FAIL fine_resync count=%0d, expected 2 (second joint search did not complete)",
                      joint_fine_resync_seen);
        end
        if (joint_search_failed_seen != 0) begin
            errors = errors + 1;
            $display("FAIL a joint search aborted (%0d times) across the two-packet run",
                      joint_search_failed_seen);
        end
        if (toa_mac_read_miss_error) begin
            errors = errors + 1;
            $display("FAIL history read miss during the second packet's joint search");
        end
        // The real proof the timebase survived: packet 2's coarse timestamp
        // is measured from the same absolute epoch as packet 1's, not reset
        // back near zero.
        if (metadata_seen >= 2 &&
            captured_metadata_coarse[1] <= captured_metadata_coarse[0]) begin
            errors = errors + 1;
            $display("FAIL packet 2 coarse=%0d did not advance past packet 1 coarse=%0d -- looks reset",
                      captured_metadata_coarse[1], captured_metadata_coarse[0]);
        end
        if (metadata_seen >= 2 &&
            (captured_metadata_fractional[1] < -32'sd2048 ||
             captured_metadata_fractional[1] > 32'sd2048)) begin
            errors = errors + 1;
            $display("FAIL packet 2 fractional ToA outside +/-0.5 sample: %0d",
                      captured_metadata_fractional[1]);
        end
        // dut.u_metadata_join's one-fragment-per-packet pairing invariant
        // (see tb_lora_joint_grid_completion) must still hold after a second
        // packet driven through trace_rearm_in rather than a fresh reset_in.
        if (dut.u_metadata_join.fractional_pending !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL fractional_pending=%0d leaked past the second packet",
                      dut.u_metadata_join.fractional_pending);
        end

        if (errors == 0)
            $display("PASS tb_lora_joint_grid_multi_packet packet1_coarse=%0d packet2_coarse=%0d history_before_rearm=%0d history_before_packet2=%0d",
                      captured_metadata_coarse[0], captured_metadata_coarse[1],
                      history_count_before_rearm, history_count_at_second_start);
        else begin
            $display("FAIL tb_lora_joint_grid_multi_packet errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #200000000;
        $display("FAIL tb_lora_joint_grid_multi_packet timeout: packet_start_seen=%0d metadata_seen=%0d fine_resync_seen=%0d",
                  packet_start_seen, metadata_seen, joint_fine_resync_seen);
        $fatal(1);
    end

endmodule
