`timescale 1ns/1ps

module tb_lora_clg400_gpreg_bridge;

    reg ctrl_clk = 1'b0;
    reg sample_clk = 1'b0;
    // The receive clock is the AD9361 divided data clock and is far slower
    // than the receiver clock; on the board the ratio is 62.5, here 32.
    reg rx_clk = 1'b0;
    always #25 ctrl_clk = ~ctrl_clk;
    always #5 sample_clk = ~sample_clk;
    always #160 rx_clk = ~rx_clk;

    reg ctrl_resetn = 1'b0;
    reg sample_resetn = 1'b0;
    reg rx_resetn = 1'b0;
    reg [31:0] gp_ctrl = 32'd0;
    reg [32:0] rx_sample_bus = 33'd0;

    wire [31:0] gp_status;
    wire [31:0] gp_sequence;
    wire [31:0] gp_coarse_lo;
    wire [31:0] gp_coarse_hi;
    wire [31:0] gp_fractional_q12;
    wire [31:0] gp_log_peak_q12;
    wire [31:0] gp_debug;
    wire [31:0] gp_signature;
    integer i;

    lora_clg400_gpreg_bridge dut (
        .ctrl_clk(ctrl_clk),
        .ctrl_resetn(ctrl_resetn),
        .sample_clk(sample_clk),
        .sample_resetn(sample_resetn),
        .rx_clk(rx_clk),
        .rx_resetn(rx_resetn),
        .gp_ctrl(gp_ctrl),
        .rx_sample_bus(rx_sample_bus),
        .gp_status(gp_status),
        .gp_sequence(gp_sequence),
        .gp_coarse_lo(gp_coarse_lo),
        .gp_coarse_hi(gp_coarse_hi),
        .gp_fractional_q12(gp_fractional_q12),
        .gp_log_peak_q12(gp_log_peak_q12),
        .gp_debug(gp_debug),
        .gp_signature(gp_signature)
    );

    task automatic expect32(
        input [31:0] actual,
        input [31:0] expected,
        input [8*64-1:0] label
    );
        begin
            if (actual !== expected) begin
                $display("FAIL %0s actual=0x%08x expected=0x%08x",
                         label, actual, expected);
                $fatal(1);
            end
            $display("PASS %0s value=0x%08x", label, actual);
        end
    endtask

    task pulse_metadata(
        input [63:0] coarse,
        input [31:0] fractional,
        input [31:0] log_peak
    );
        begin
            @(negedge sample_clk);
            force dut.metadata_coarse = coarse;
            force dut.metadata_fractional_q12 = fractional;
            force dut.toa_log_peak_q12 = log_peak;
            force dut.metadata_valid = 1'b1;
            @(negedge sample_clk);
            force dut.metadata_valid = 1'b0;
        end
    endtask

    initial begin
        force dut.metadata_valid = 1'b0;
        force dut.metadata_overflow = 1'b0;
        force dut.packet_start_valid = 1'b0;
        force dut.packet_start_count = 64'd0;
        force dut.toa_search_busy = 1'b0;
        force dut.correlation_magnitude_valid = 1'b0;
        force dut.peak_triplet_valid = 1'b0;
        force dut.toa_offset_valid = 1'b0;
        force dut.alignment_error = 1'b0;
        force dut.symbol_index_width_error = 1'b0;
        force dut.toa_underflow_error = 1'b0;
        force dut.toa_search_restart_error = 1'b0;
        force dut.toa_mac_window_mismatch_error = 1'b0;
        force dut.toa_mac_read_miss_error = 1'b0;
        force dut.toa_mac_response_mismatch_error = 1'b0;
        force dut.toa_mac_restart_error = 1'b0;
        force dut.toa_peak_boundary_error = 1'b0;
        force dut.toa_peak_restart_error = 1'b0;
        force dut.metadata_coarse = 64'd0;
        force dut.metadata_fractional_q12 = 32'd0;
        force dut.toa_log_peak_q12 = 32'd0;
        force dut.packet_detected = 1'b0;
        force dut.preamble_bin = 16'd0;
        force dut.symbol_index = 32'd0;
        force dut.symbol_valid = 1'b0;
        force dut.symbol_confidence = 16'd0;
        force dut.symbol_sample_count = 64'd0;
        force dut.symbol_timestamp_valid = 1'b0;

        repeat (4) @(posedge ctrl_clk);
        ctrl_resetn = 1'b1;
        sample_resetn = 1'b1;
        rx_resetn = 1'b1;
        gp_ctrl = 32'h0000_1201;

        repeat (8) @(posedge ctrl_clk);
        expect32(gp_signature, 32'h4c4f5241, "signature");
        if (!gp_status[0] || !gp_status[1]) begin
            $display("FAIL receiver request/active status=0x%08x", gp_status);
            $fatal(1);
        end

        // Diagnostic stage/error pulses are sticky until stream reset, while
        // packet-start count is captured from the same sample-domain event.
        @(negedge sample_clk);
        force dut.packet_start_count = 64'h0000_0000_1234_abcd;
        force dut.packet_start_valid = 1'b1;
        force dut.toa_search_busy = 1'b1;
        force dut.correlation_magnitude_valid = 1'b1;
        force dut.toa_peak_boundary_error = 1'b1;
        @(negedge sample_clk);
        force dut.packet_start_valid = 1'b0;
        force dut.toa_search_busy = 1'b0;
        force dut.correlation_magnitude_valid = 1'b0;
        force dut.toa_peak_boundary_error = 1'b0;
        repeat (2) @(posedge sample_clk);
        repeat (3) @(posedge ctrl_clk);
        expect32(gp_debug, 32'h00b1_abcd,
                 "sticky diagnostic and packet-start count");

        // The control clock is deliberately slower than the sample clock. The
        // second event arrives while the first mailbox entry is pending and
        // must set overflow without tearing the first payload.
        pulse_metadata(64'h0123_4567_89ab_cdef, 32'hffff_f800,
                       32'h0001_2345);
        pulse_metadata(64'hdead_beef_0000_0002, 32'h0000_0100,
                       32'h0002_0000);

        wait (gp_sequence == 32'd1);
        repeat (3) @(posedge ctrl_clk);
        expect32(gp_coarse_lo, 32'h89ab_cdef, "atomic coarse low");
        expect32(gp_coarse_hi, 32'h0123_4567, "atomic coarse high");
        expect32(gp_fractional_q12, 32'hffff_f800, "atomic fractional");
        expect32(gp_log_peak_q12, 32'h0001_2345, "atomic log peak");
        if (!gp_status[2] || !gp_status[3]) begin
            $display("FAIL snapshot/overflow status=0x%08x", gp_status);
            $fatal(1);
        end

        // Once acknowledged, a later event transfers normally and increments
        // exactly once.
        repeat (5) @(posedge sample_clk);
        pulse_metadata(64'h1020_3040_5060_7080, 32'h0000_0400,
                       32'h0003_0000);
        wait (gp_sequence == 32'd2);
        repeat (2) @(posedge ctrl_clk);
        expect32(gp_coarse_lo, 32'h5060_7080, "second coarse low");
        expect32(gp_coarse_hi, 32'h1020_3040, "second coarse high");
        expect32(gp_fractional_q12, 32'h0000_0400, "second fractional");
        expect32(gp_log_peak_q12, 32'h0003_0000, "second log peak");

        // Re-arm the symbol trace, trigger on the packet decision, and then
        // provide the 128 following symbol decisions. The detector-cycle
        // symbol itself must not occupy entry zero.
        gp_ctrl = 32'h0000_1203;
        repeat (3) @(posedge sample_clk);
        gp_ctrl = 32'h0000_1201;
        repeat (3) @(posedge sample_clk);

        @(negedge sample_clk);
        force dut.packet_detected = 1'b1;
        force dut.preamble_bin = 16'd7;
        force dut.symbol_index = 32'h0000_007f;
        force dut.symbol_valid = 1'b1;
        force dut.symbol_confidence = 16'h7fff;
        force dut.symbol_sample_count = 64'd100;
        force dut.symbol_timestamp_valid = 1'b1;
        @(negedge sample_clk);
        force dut.packet_detected = 1'b0;

        for (i = 0; i < 128; i = i + 1) begin
            force dut.symbol_index = 32'h0000_0040 + i;
            force dut.symbol_confidence = 16'h0200 + i;
            force dut.symbol_sample_count = 64'd1000 + i*1024;
            @(negedge sample_clk);
        end
        force dut.symbol_valid = 1'b0;
        force dut.symbol_timestamp_valid = 1'b0;

        repeat (6) @(posedge ctrl_clk);
        // Page one, trace index five, receiver remains enabled with sync 0x12.
        gp_ctrl = 32'h0501_1201;
        repeat (5) @(posedge ctrl_clk);
        expect32(gp_status, 32'h5359_0280, "symbol trace complete status");
        expect32(gp_sequence, 32'd1, "symbol trace sequence");
        expect32(gp_coarse_lo, 32'h0000_0045, "symbol trace index");
        expect32(gp_coarse_hi, 32'd6120, "symbol trace sample count low");
        expect32(gp_fractional_q12, 32'd0, "symbol trace sample count high");
        expect32(gp_log_peak_q12, 32'h0002_0205,
                 "symbol trace flags and confidence");
        // Bit 8 reports that the grid was realigned for this capture. The
        // receiver instance inside the bridge does that on the detector pulse,
        // so a completed capture always shows it set.
        expect32(gp_debug, 32'h0007_0b80,
                 "symbol trace preamble bin, resync flag, index, and count");

        // Returning to page zero must preserve the timestamp snapshot ABI.
        gp_ctrl = 32'h0000_1201;
        repeat (2) @(posedge ctrl_clk);
        expect32(gp_sequence, 32'd2, "timestamp sequence after trace read");
        expect32(gp_coarse_lo, 32'h5060_7080,
                 "timestamp snapshot after trace read");

        // Page two reports what the receiver clock actually is. This is the
        // regression that would have caught the original defect: a receiver
        // clocked from the AD9361 divided data clock reports one clock per
        // sample, and the joint search budget assumes sixty-three.
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge rx_clk);
            rx_sample_bus = {1'b1, 16'sd100, 16'sd200};
            @(negedge rx_clk);
            rx_sample_bus = 33'd0;
        end
        repeat (4) @(posedge sample_clk);

        // Hold the search busy for a known number of receiver clocks.
        @(negedge sample_clk);
        force dut.toa_search_busy = 1'b1;
        repeat (40) @(negedge sample_clk);
        force dut.toa_search_busy = 1'b0;
        repeat (4) @(posedge sample_clk);

        gp_ctrl = 32'h0002_1201;
        repeat (6) @(posedge ctrl_clk);
        if (gp_status[31:16] !== 16'h434b) begin
            $display("FAIL clock page marker status=0x%08x", gp_status);
            $fatal(1);
        end
        if (gp_status[0] !== 1'b0) begin
            $display("FAIL receive crossing reported a dropped sample");
            $fatal(1);
        end
        // Two rx_clk periods per driven sample, 32 receiver clocks each, so
        // the accepted samples are 64 receiver clocks apart. The synchronizers
        // move that by a cycle or so; what must never pass is the single clock
        // per sample the AD9361-derived clock gave.
        if (gp_sequence < 32'd60 || gp_sequence > 32'd68) begin
            $display("FAIL clocks between samples=%0d expected about 64",
                     gp_sequence);
            $fatal(1);
        end
        $display("PASS clocks between accepted samples=%0d", gp_sequence);
        expect32(gp_coarse_lo, 32'd40, "joint search duration in clocks");
        expect32(gp_fractional_q12, 32'd1, "completed search count");
        if (gp_coarse_hi < 32'd60 || gp_coarse_hi > 32'd68) begin
            $display("FAIL minimum sample interval=%0d", gp_coarse_hi);
            $fatal(1);
        end
        $display("PASS minimum clocks between samples=%0d", gp_coarse_hi);

        gp_ctrl = 32'h0000_1201;
        repeat (2) @(posedge ctrl_clk);
        expect32(gp_coarse_lo, 32'h5060_7080,
                 "timestamp snapshot after clock page read");

        // Page three carries the joint estimator's own numbers. Without it
        // the board's correction can only be inferred from the skip it
        // applies, which cannot be compared with the reference model at all:
        // the two are measured from different origins.
        @(negedge sample_clk);
        force dut.joint_timing_correction_samples = -32'sd7;
        force dut.joint_up_offset_samples = 32'sd12;
        force dut.joint_up_coarse_start = 64'h0000_0000_0001_3880;
        force dut.packet_start_count = 64'h0000_0000_0001_2345;
        force dut.chips_to_boundary = 16'd31;
        force dut.preamble_bin = 16'd97;
        force dut.joint_timing_valid = 1'b1;
        @(negedge sample_clk);
        force dut.joint_timing_valid = 1'b0;
        repeat (4) @(posedge sample_clk);

        gp_ctrl = 32'h0004_1201;
        repeat (6) @(posedge ctrl_clk);
        if (gp_status[31:16] !== 16'h4a54) begin
            $display("FAIL joint page marker status=0x%08x", gp_status);
            $fatal(1);
        end
        if (gp_status[0] !== 1'b1) begin
            $display("FAIL joint page reports no estimate");
            $fatal(1);
        end
        expect32(gp_sequence, 32'hffff_fff9, "joint timing correction");
        expect32(gp_coarse_lo, 32'd12, "joint up offset");
        expect32(gp_coarse_hi, 32'h0001_3880, "joint up coarse start");
        expect32(gp_fractional_q12, 32'h0001_2345, "joint packet start");
        expect32(gp_log_peak_q12, 32'h001f_0061,
                 "joint chips to boundary and preamble bin");

        gp_ctrl = 32'h0000_1201;
        repeat (2) @(posedge ctrl_clk);
        expect32(gp_coarse_lo, 32'h5060_7080,
                 "timestamp snapshot after joint page read");

        // Sticky joint-controller outcome bits (joint_status bits 4:1): each
        // used to be indistinguishable from the others, and from the plain
        // single-search's own restart/boundary errors, once folded into
        // toa_search_restart_error / toa_peak_boundary_error upstream. Pulse
        // all four causes at once and confirm each lands in its own bit.
        @(negedge sample_clk);
        force dut.joint_up_search_abort_error = 1'b1;
        force dut.joint_down_search_abort_error = 1'b1;
        force dut.joint_timing_range_error = 1'b1;
        force dut.joint_precise_correction_applied = 1'b1;
        @(negedge sample_clk);
        force dut.joint_up_search_abort_error = 1'b0;
        force dut.joint_down_search_abort_error = 1'b0;
        force dut.joint_timing_range_error = 1'b0;
        force dut.joint_precise_correction_applied = 1'b0;
        repeat (4) @(posedge sample_clk);

        gp_ctrl = 32'h0004_1201;
        repeat (6) @(posedge ctrl_clk);
        if (gp_status[4:0] !== 5'b11111) begin
            $display("FAIL joint sticky bits after pulse status=0x%08x (want bits 4:0 all set)",
                     gp_status);
            $fatal(1);
        end
        $display("PASS joint sticky bits set: status=0x%08x", gp_status);

        // Sticky means sticky: switching away to another page and back must
        // not clear them (only a stream reset may).
        gp_ctrl = 32'h0000_1201;
        repeat (2) @(posedge ctrl_clk);
        gp_ctrl = 32'h0004_1201;
        repeat (2) @(posedge ctrl_clk);
        if (gp_status[4:0] !== 5'b11111) begin
            $display("FAIL joint sticky bits did not survive a page switch: status=0x%08x",
                     gp_status);
            $fatal(1);
        end
        $display("PASS joint sticky bits survive a page switch");

        // A stream reset (control bit 1, the same pulse already used above to
        // re-arm the symbol trace) must clear every sticky bit on this page,
        // including the pre-existing "estimate seen" bit 0.
        gp_ctrl = 32'h0000_1203;
        repeat (3) @(posedge sample_clk);
        gp_ctrl = 32'h0000_1201;
        repeat (3) @(posedge sample_clk);
        gp_ctrl = 32'h0004_1201;
        repeat (6) @(posedge ctrl_clk);
        if (gp_status[4:0] !== 5'b00000) begin
            $display("FAIL joint sticky bits survived a stream reset: status=0x%08x",
                     gp_status);
            $fatal(1);
        end
        $display("PASS joint sticky bits cleared by stream reset");

        // M6: trace_rearm (control bit 2) must clear the same per-capture
        // joint sticky bits as stream_reset, so a capture campaign that
        // re-arms with bit 2 between packets gets each packet's own outcome
        // -- but page 0's "a packet has been seen" bit belongs to the whole
        // campaign, not to one capture, and must survive a bit-2-alone pulse
        // (only a real stream_reset, bit 1, may clear it).
        //
        // The stream reset just above also cleared packet_seen_sample, so
        // it needs to be set again before testing that trace_rearm alone
        // leaves it alone.
        gp_ctrl = 32'h0000_1201;
        repeat (2) @(posedge ctrl_clk);
        @(negedge sample_clk);
        force dut.packet_start_valid = 1'b1;
        @(negedge sample_clk);
        force dut.packet_start_valid = 1'b0;
        repeat (3) @(posedge ctrl_clk);
        if (!gp_status[5]) begin
            $display("FAIL packet_seen not set on page 0 (test setup) status=0x%08x",
                     gp_status);
            $fatal(1);
        end

        @(negedge sample_clk);
        force dut.joint_up_search_abort_error = 1'b1;
        force dut.joint_down_search_abort_error = 1'b1;
        force dut.joint_timing_range_error = 1'b1;
        force dut.joint_precise_correction_applied = 1'b1;
        force dut.joint_timing_valid = 1'b1;
        force dut.packet_straddle_detected = 1'b1;
        force dut.packet_split_detected = 1'b1;
        force dut.packet_early_sync_detected = 1'b1;
        @(negedge sample_clk);
        force dut.joint_up_search_abort_error = 1'b0;
        force dut.joint_down_search_abort_error = 1'b0;
        force dut.joint_timing_range_error = 1'b0;
        force dut.joint_precise_correction_applied = 1'b0;
        force dut.joint_timing_valid = 1'b0;
        force dut.packet_straddle_detected = 1'b0;
        force dut.packet_split_detected = 1'b0;
        force dut.packet_early_sync_detected = 1'b0;
        repeat (4) @(posedge sample_clk);

        gp_ctrl = 32'h0004_1201;
        repeat (6) @(posedge ctrl_clk);
        // Bit 5 (M7): a packet was accepted only through the detector's
        // straddle-tolerant path.
        if (gp_status[7:0] !== 8'b11111111) begin
            $display("FAIL joint sticky bits before trace_rearm status=0x%08x (want bits 7:0 all set)",
                     gp_status);
            $fatal(1);
        end
        $display("PASS joint straddle (5), split (6) and early-sync (7) bits set with the other sticky bits");

        // Pulse bit 2 alone -- bit 1 (stream_reset) stays low throughout.
        gp_ctrl = 32'h0000_1205;
        repeat (3) @(posedge sample_clk);
        gp_ctrl = 32'h0000_1201;
        repeat (3) @(posedge sample_clk);

        gp_ctrl = 32'h0004_1201;
        repeat (6) @(posedge ctrl_clk);
        if (gp_status[7:0] !== 8'b00000000) begin
            $display("FAIL joint sticky bits (incl. straddle, split, early-sync) survived trace_rearm alone: status=0x%08x",
                     gp_status);
            $fatal(1);
        end
        $display("PASS joint sticky bits cleared by trace_rearm alone (no stream_reset)");

        gp_ctrl = 32'h0000_1201;
        repeat (2) @(posedge ctrl_clk);
        if (!gp_status[5]) begin
            $display("FAIL page 0 packet_seen was cleared by trace_rearm alone: status=0x%08x",
                     gp_status);
            $fatal(1);
        end
        $display("PASS page 0 packet_seen survives trace_rearm (only stream_reset clears it)");

        // Decision history (bit 3 freeze, bit 4 page, 12-bit index in 19-23 and
        // 24-30). Every decision is kept, detected packet or not, so the 129
        // decisions driven for the symbol trace above are all in the ring:
        // entry 0 the detector-cycle decision, entries 1..128 the trace ones.
        gp_ctrl = 32'h0000_1211;
        repeat (6) @(posedge ctrl_clk);
        expect32(gp_status, 32'h4448_0080, "history marker, not frozen, newest 128");
        expect32(gp_sequence, 32'd129, "history decisions written");

        // One more decision while the crossing's drop count reads 0x0105: the
        // entry must carry its low byte, and the live count must read in full
        // on the history page and on the clock page.
        force dut.rx_cdc_drop_count = 16'h0105;
        repeat (4) @(posedge sample_clk);
        @(negedge sample_clk);
        force dut.symbol_index = 32'h0000_0033;
        force dut.symbol_confidence = 16'h1234;
        force dut.symbol_sample_count = 64'h0000_0007_0000_0309;
        force dut.symbol_valid = 1'b1;
        @(negedge sample_clk);
        force dut.symbol_valid = 1'b0;
        repeat (8) @(posedge ctrl_clk);
        expect32(gp_log_peak_q12, 32'h0000_0105, "history page live drop count");
        gp_ctrl = 32'h0002_1201;
        repeat (4) @(posedge ctrl_clk);
        expect32(gp_log_peak_q12, 32'h0000_0105, "clock page live drop count");

        // Freeze, then decisions must no longer be written.
        gp_ctrl = 32'h0000_1219;
        repeat (8) @(posedge ctrl_clk);
        expect32(gp_status, 32'h4448_1081, "history frozen, newest 129");
        expect32(gp_sequence, 32'd130, "history written before freeze");
        @(negedge sample_clk);
        force dut.symbol_valid = 1'b1;
        repeat (5) @(negedge sample_clk);
        force dut.symbol_valid = 1'b0;
        repeat (8) @(posedge ctrl_clk);
        expect32(gp_sequence, 32'd130, "history frozen: no decision written");

        // Entry 0: the detector-cycle decision, detected flag set.
        gp_ctrl = 32'h0000_1219;
        repeat (5) @(posedge ctrl_clk);
        expect32(gp_debug, 32'h0000_0000, "history read index echo 0");
        expect32(gp_coarse_lo, 32'd100, "history entry 0 sample count");
        expect32(gp_fractional_q12, 32'h0000_007f, "history entry 0 bin");
        // Flags are {4'd0, grid_resync_armed, straddle, detected, valid} in
        // bits 31:24. grid_resync_armed (bit 27) is the receiver's own state
        // and is not asserted on here.
        if (gp_coarse_hi[26:24] !== 3'b011 || gp_coarse_hi[31:28] !== 4'd0 ||
                gp_coarse_hi[23:16] !== 8'h00 || gp_coarse_hi[15:0] !== 16'h7fff) begin
            $display("FAIL history entry 0 flags/drop/confidence 0x%08x (want valid+detected, drop 0, conf 7fff)",
                     gp_coarse_hi);
            $fatal(1);
        end
        $display("PASS history entry 0 = detector-cycle decision, detected flag set");

        // Entry 5 (low index bits only) and entry 128 (needs index bit 19).
        gp_ctrl = 32'h0500_1219;
        repeat (5) @(posedge ctrl_clk);
        expect32(gp_debug, 32'h0005_0000, "history read index echo 5");
        expect32(gp_coarse_lo, 32'd5096, "history entry 5 sample count");
        expect32(gp_fractional_q12, 32'h0000_0044, "history entry 5 bin");
        expect32({gp_coarse_hi[31:28], gp_coarse_hi[26:0]},
                 {4'd0, 3'b001, 8'h00, 16'h0204},
                 "history entry 5 flags (valid only), drop 0, confidence");
        gp_ctrl = 32'h0008_1219;
        repeat (5) @(posedge ctrl_clk);
        expect32(gp_debug, 32'h0080_0000, "history read index echo 128");
        expect32(gp_coarse_lo, 32'd131048, "history entry 128 sample count");
        expect32(gp_fractional_q12, 32'h0000_00bf, "history entry 128 bin");
        // Entry 129: the decision taken with the drop count at 0x0105.
        gp_ctrl = 32'h0108_1219;
        repeat (5) @(posedge ctrl_clk);
        expect32(gp_coarse_lo, 32'h0000_0309, "history entry 129 sample count low word");
        expect32(gp_fractional_q12, 32'h0000_0033, "history entry 129 bin");
        // The straddle pulse forced in the joint-page test above came with no
        // decision; a detection or straddle pulse is held until the next
        // decision is written, so it lands on this entry (flag bit 26).
        expect32({gp_coarse_hi[31:28], gp_coarse_hi[26:0]},
                 {4'd0, 3'b101, 8'h05, 16'h1234},
                 "history entry 129 drop count low byte and confidence");

        // Release: the ring runs again.
        release dut.rx_cdc_drop_count;
        gp_ctrl = 32'h0000_1211;
        repeat (6) @(posedge ctrl_clk);
        @(negedge sample_clk);
        force dut.symbol_valid = 1'b1;
        @(negedge sample_clk);
        force dut.symbol_valid = 1'b0;
        repeat (8) @(posedge ctrl_clk);
        expect32(gp_status, 32'h4448_0082, "history released, newest 130");
        expect32(gp_sequence, 32'd131, "history writes again after release");

        // Page 0 is untouched by any of this.
        gp_ctrl = 32'h0000_1201;
        repeat (3) @(posedge ctrl_clk);
        if (gp_status[31:16] !== 16'h0001) begin
            $display("FAIL page 0 status after history reads 0x%08x", gp_status);
            $fatal(1);
        end
        $display("PASS decision history ring: writes, freeze, indexed read, drop count, release");

        $display("PASS tb_lora_clg400_gpreg_bridge");
        $finish;
    end

endmodule
