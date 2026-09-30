`timescale 1ns/1ps

module tb_lora_joint_chirp_grid_controller;
    localparam integer SYMBOL_SAMPLES = 1024;
    localparam integer SEARCH_RADIUS = 16;
    localparam integer GUARD = 16;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg stream_reset = 1'b0;
    reg packet_start_valid = 1'b0;
    reg [63:0] packet_start_count = 64'd0;
    reg [15:0] chips_to_boundary = 16'd0;
    reg packet_straddle = 1'b0;
    reg [63:0] history_next_sample_count = 64'd0;
    reg search_busy = 1'b0;
    reg search_failed = 1'b0;
    reg search_triplet_valid = 1'b0;
    reg [63:0] search_peak_sample_count = 64'd0;
    reg signed [15:0] search_offset_q12 = 16'sd0;
    reg search_offset_valid = 1'b0;

    wire search_start;
    wire [63:0] search_coarse_start;
    wire reference_down;
    wire busy;
    wire signed [31:0] timing_correction_samples;
    wire [31:0] fine_skip;
    wire fine_resync_valid;
    wire timing_valid;
    wire restart_error;
    wire timing_range_error;
    wire up_search_abort_error;
    wire down_search_abort_error;
    wire precise_correction_applied;
    wire signed [15:0] diag_up_offset_frac_q12;
    wire [63:0] toa_coarse;
    wire signed [31:0] toa_fraction_q12;

    integer errors = 0;

    initial begin
        #1000000;
        $display("FAIL timeout state=%0d busy=%0d search_start=%0d down=%0d history=%0d down_start=%0d ready=%0d",
                 dut.state, busy, search_start, reference_down,
                 history_next_sample_count, dut.down_coarse_start,
                 dut.down_ready_count);
        $fatal(1);
    end

    lora_joint_chirp_grid_controller #(
        .SAMPLES_PER_CHIP(8),
        .SYMBOL_SAMPLES(SYMBOL_SAMPLES),
        .SEARCH_RADIUS(SEARCH_RADIUS),
        .FINE_GUARD_SAMPLES(GUARD),
        .PREAMBLE_TO_SFD_SYMBOLS(10)
    ) dut (
        .clk(clk), .resetn(resetn), .stream_reset(stream_reset),
        .packet_start_valid(packet_start_valid),
        .packet_start_count(packet_start_count),
        .chips_to_boundary(chips_to_boundary),
        .packet_straddle(packet_straddle),
        .history_next_sample_count(history_next_sample_count),
        .search_busy(search_busy),
        .search_failed(search_failed),
        .search_triplet_valid(search_triplet_valid),
        .search_peak_sample_count(search_peak_sample_count),
        .search_offset_q12(search_offset_q12),
        .search_offset_valid(search_offset_valid),
        .search_start(search_start),
        .search_coarse_start(search_coarse_start),
        .reference_down(reference_down), .busy(busy),
        .timing_correction_samples(timing_correction_samples),
        .diag_up_offset_frac_q12(diag_up_offset_frac_q12),
        .fine_skip(fine_skip), .fine_resync_valid(fine_resync_valid),
        .timing_valid(timing_valid), .restart_error(restart_error),
        .timing_range_error(timing_range_error),
        .up_search_abort_error(up_search_abort_error),
        .down_search_abort_error(down_search_abort_error),
        .precise_correction_applied(precise_correction_applied),
        .toa_coarse(toa_coarse),
        .toa_fraction_q12(toa_fraction_q12)
    );

    task automatic pulse_packet(
        input [63:0] start_count,
        input [15:0] chips,
        input straddle = 1'b0
    );
        begin
            @(negedge clk);
            packet_start_count <= start_count;
            chips_to_boundary <= chips;
            packet_straddle <= straddle;
            packet_start_valid <= 1'b1;
            @(negedge clk);
            packet_start_valid <= 1'b0;
        end
    endtask

    task automatic wait_search(
        input expected_down,
        input [63:0] expected_start
    );
        begin
            while (!search_start) @(negedge clk);
            if (reference_down !== expected_down ||
                search_coarse_start !== expected_start) begin
                errors = errors + 1;
                $display("FAIL search down=%0d start=%0d expected down=%0d start=%0d",
                         reference_down, search_coarse_start,
                         expected_down, expected_start);
            end
            search_busy <= 1'b1;
            @(negedge clk);
        end
    endtask

    // frac_q12 defaults to 0 so every pre-existing call site is unaffected:
    // with a zero interpolated fraction on both legs, the new Q12 arithmetic
    // in the DUT collapses back to the original integer-only formula exactly
    // (see the comment above rounded_abs in the DUT). Only the two new test
    // cases below pass a nonzero fraction. search_offset_valid is driven one
    // cycle after search_triplet_valid, matching the DUT's real dependency
    // (the interpolator's result always follows its triplet) without trying
    // to model the actual 38-cycle hardware latency, which the DUT does not
    // time out on.
    task automatic return_peak(
        input [63:0] count,
        input signed [15:0] frac_q12 = 16'sd0
    );
        begin
            search_busy <= 1'b0;
            search_peak_sample_count <= count;
            search_triplet_valid <= 1'b1;
            @(negedge clk);
            search_triplet_valid <= 1'b0;
            search_offset_q12 <= frac_q12;
            search_offset_valid <= 1'b1;
            @(negedge clk);
            search_offset_valid <= 1'b0;
        end
    endtask

    task automatic expect_result(
        input signed [31:0] expected_correction,
        input [31:0] expected_skip
    );
        begin
            while (!timing_valid) @(negedge clk);
            if (timing_correction_samples !== expected_correction ||
                fine_skip !== expected_skip || !fine_resync_valid ||
                timing_range_error || !precise_correction_applied) begin
                errors = errors + 1;
                $display("FAIL result correction=%0d skip=%0d fine=%0d range=%0d precise=%0d",
                         timing_correction_samples, fine_skip,
                         fine_resync_valid, timing_range_error,
                         precise_correction_applied);
            end
            @(negedge clk);
        end
    endtask

    // A completed estimate outside +/-FINE_GUARD_SAMPLES: timing_valid still
    // pulses, but the correction is declined -- precise_correction_applied
    // must stay clear and timing_range_error must fire instead.
    task automatic expect_rejected_result(
        input [31:0] expected_skip
    );
        begin
            while (!timing_valid) @(negedge clk);
            if (fine_skip !== expected_skip || !fine_resync_valid ||
                !timing_range_error || precise_correction_applied) begin
                errors = errors + 1;
                $display("FAIL rejected result skip=%0d fine=%0d range=%0d precise=%0d",
                         fine_skip, fine_resync_valid, timing_range_error,
                         precise_correction_applied);
            end
            @(negedge clk);
        end
    endtask

    // The packet time of arrival handed to the metadata path: up coarse start
    // plus (up + down) / 2, as a whole sample and a Q12 remainder. It must be
    // the joint time, not the up leg's peak, which a carrier offset moves.
    task automatic expect_toa(
        input [63:0] expected_coarse,
        input signed [31:0] expected_fraction
    );
        begin
            if (toa_coarse !== expected_coarse || toa_fraction_q12 !== expected_fraction) begin
                errors = errors + 1;
                $display("FAIL toa coarse=%0d fraction=%0d expected %0d %0d",
                         toa_coarse, toa_fraction_q12, expected_coarse, expected_fraction);
            end else begin
                $display("PASS toa coarse=%0d fraction_q12=%0d", toa_coarse, toa_fraction_q12);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        resetn <= 1'b1;
        repeat (2) @(posedge clk);

        // Capture 30: coarse up=10440, down=20680; offsets +8 and +14
        // have half-sum +11, so the guarded late skip is 16+11=27.
        history_next_sample_count <= 64'd200000;
        pulse_packet(64'd10000, 16'd55);
        wait_search(1'b0, 64'd10440);
        return_peak(64'd10448);
        wait_search(1'b1, 64'd20680);
        return_peak(64'd20694);
        expect_result(32'sd11, 32'd27);
        expect_toa(64'd10451, 32'sd0);

        // Synthetic negative half-sum: chirp origin 30832 is 192 samples
        // before FFT window 31024 (previous window 30000); its forward phase
        // is (1024-192)/8 = 104 chips. Offsets (-5 + 2)/2 round to -2.
        pulse_packet(64'd31024, 16'd104);
        wait_search(1'b0, 64'd30832);
        return_peak(64'd30827);
        wait_search(1'b1, 64'd41072);
        return_peak(64'd41074);
        expect_result(-32'sd2, 32'd14);
        // -1.5 rounds away to -2, leaving +0.5 sample: 30830 + 2048/4096.
        expect_toa(64'd30830, 32'sd2048);

        // Synthetic positive half-sum: chirp origin 50872 is 152 before 51024,
        // so its forward phase is (1024-152)/8 = 109 chips.
        // (-2 + 5)/2 = +1.5, rounded away from zero to +2.
        pulse_packet(64'd51024, 16'd109);
        wait_search(1'b0, 64'd50872);
        return_peak(64'd50870);
        wait_search(1'b1, 64'd61112);
        return_peak(64'd61117);
        expect_result(32'sd2, 32'd18);

        // A carrier offset: the up leg's peak sits 3.75 samples early and the
        // down leg's 2.875 late (equal and opposite about the true time plus
        // the timing). The up peak alone would put the packet at 10436.25;
        // the joint time is (-3.75 + 2.875) / 2 = -0.4375 from the coarse
        // start, i.e. 10440 with a -1792/4096 remainder.
        pulse_packet(64'd10000, 16'd55);
        wait_search(1'b0, 64'd10440);
        return_peak(64'd10436, 16'sd1024);
        wait_search(1'b1, 64'd20680);
        return_peak(64'd20683, -16'sd512);
        expect_result(32'sd0, 32'd16);
        expect_toa(64'd10440, -32'sd1792);

        // A packet at 60512 lies halfway between grid origins 60000/61024.
        // The later decision window represents it; phase 64 chips must point
        // backwards to that packet, with the SFD at 60512 + 10*1024.
        pulse_packet(64'd61024, 16'd64);
        wait_search(1'b0, 64'd60512);
        return_peak(64'd60512);
        wait_search(1'b1, 64'd70752);
        return_peak(64'd70752);
        expect_result(32'sd0, 32'd16);

        // M7: a packet the detector accepted through its straddle-tolerant
        // path never wraps. Same phase (64 chips) and same packet at 60512,
        // but the retained decision window is still the EARLIER one, 60000,
        // so the arrival is 512 samples forward of it instead of 512 back
        // of the later window. Without the flag this comes out a whole
        // symbol early and the down search lands on the second sync symbol.
        pulse_packet(64'd60000, 16'd64, 1'b1);
        wait_search(1'b0, 64'd60512);
        return_peak(64'd60512);
        wait_search(1'b1, 64'd70752);
        return_peak(64'd70752);
        expect_result(32'sd0, 32'd16);
        // The far end of the measured straddle band (73 chips = 584
        // samples of advance) also stays unwrapped.
        pulse_packet(64'd60000, 16'd73, 1'b1);
        wait_search(1'b0, 64'd60584);
        return_peak(64'd60584);
        wait_search(1'b1, 64'd70824);
        return_peak(64'd70824);
        expect_result(32'sd0, 32'd16);
        // And the flag is per packet: the next, unflagged packet wraps again.
        pulse_packet(64'd61024, 16'd64);
        wait_search(1'b0, 64'd60512);
        return_peak(64'd60512);
        wait_search(1'b1, 64'd70752);
        return_peak(64'd70752);
        expect_result(32'sd0, 32'd16);

        // Neither search may start until its complete window is stored. The
        // up window here ends at 70008+1024+16 = 71048; the down window ends
        // at 81288, so this level releases the up search and still holds the
        // down one back.
        history_next_sample_count <= 64'd0;
        pulse_packet(64'd70000, 16'd1);
        repeat (5) begin
            @(negedge clk);
            if (search_start) begin
                errors = errors + 1;
                $display("FAIL up search started before IQ was available");
            end
        end
        history_next_sample_count <= 64'd71048;
        wait_search(1'b0, 64'd70008);
        return_peak(64'd70008);
        repeat (5) begin
            @(negedge clk);
            if (search_start) begin
                errors = errors + 1;
                $display("FAIL down search started before IQ was available");
            end
        end
        history_next_sample_count <= 64'd81288;
        wait_search(1'b1, 64'd80248);
        return_peak(64'd80248);
        expect_result(32'sd0, 32'd16);

        // A new packet while the pair is active is diagnosed, not restarted.
        history_next_sample_count <= 64'd200000;
        pulse_packet(64'd90000, 16'd0);
        wait_search(1'b0, 64'd90000);
        packet_start_valid <= 1'b1;
        @(negedge clk);
        packet_start_valid <= 1'b0;
        if (!restart_error) begin
            errors = errors + 1;
            $display("FAIL missing restart error");
        end
        return_peak(64'd90000);
        wait_search(1'b1, 64'd100240);
        return_peak(64'd100240);
        expect_result(32'sd0, 32'd16);

        // A failed bounded search releases the controller for the next packet.
        // This exercises path 1 (up-search abort): up_search_abort_error must
        // fire and down_search_abort_error must not, distinguishing the two
        // paths that used to share one search_abort_error bit.
        pulse_packet(64'd120000, 16'd0);
        wait_search(1'b0, 64'd120000);
        search_busy <= 1'b0;
        search_failed <= 1'b1;
        @(negedge clk);
        // up_search_abort_error is a one-cycle pulse: sample it here, before
        // it clears on the next edge, not after the settle delay below.
        if (!up_search_abort_error || down_search_abort_error) begin
            errors = errors + 1;
            $display("FAIL up-search abort did not set up_search_abort_error alone: up=%0d down=%0d",
                     up_search_abort_error, down_search_abort_error);
        end
        search_failed <= 1'b0;
        repeat (2) @(negedge clk);
        if (busy) begin
            errors = errors + 1;
            $display("FAIL failed search left controller busy");
        end

        // Path 2: the down search aborts instead. down_search_abort_error
        // must fire and up_search_abort_error must not (it belongs to the
        // up-search leg only, and that leg already completed here).
        pulse_packet(64'd140000, 16'd0);
        wait_search(1'b0, 64'd140000);
        return_peak(64'd140000);
        wait_search(1'b1, 64'd150240);
        search_busy <= 1'b0;
        search_failed <= 1'b1;
        @(negedge clk);
        if (!down_search_abort_error || up_search_abort_error) begin
            errors = errors + 1;
            $display("FAIL down-search abort did not set down_search_abort_error alone: up=%0d down=%0d",
                     up_search_abort_error, down_search_abort_error);
        end
        search_failed <= 1'b0;
        repeat (2) @(negedge clk);
        if (busy) begin
            errors = errors + 1;
            $display("FAIL down-search failure left controller busy");
        end

        // Path 3: both searches complete but the rounded half-sum falls
        // outside +/-FINE_GUARD_SAMPLES (16 here). timing_valid must still
        // pulse (an estimate was computed), but as a decline: precise
        // correction not applied, timing_range_error set instead.
        pulse_packet(64'd160000, 16'd0);
        wait_search(1'b0, 64'd160000);
        return_peak(64'd160040);
        wait_search(1'b1, 64'd170240);
        return_peak(64'd170280);
        expect_rejected_result(32'd16);

        history_next_sample_count <= 64'd300000;

        // Sub-sample interpolation: up=2 int + 0.5 frac (Q12 2048), down=2 int
        // + 0.5 frac -> up=2.5, down=2.5, timing=2.5, correction=+3. The old
        // integer-only arithmetic (ignoring both fractions) would have summed
        // 2+2=4, timing=2.0, correction=+2 -- a different, wrong answer. This
        // is the class of one-sample error the whole investigation traced
        // CRC failures to; the fix must produce +3, not +2, here.
        pulse_packet(64'd180000, 16'd0);
        wait_search(1'b0, 64'd180000);
        return_peak(64'd180002, 16'sd2048);
        if (diag_up_offset_frac_q12 !== 16'sd2048) begin
            errors = errors + 1;
            $display("FAIL diag_up_offset_frac_q12=%0d expected 2048",
                     diag_up_offset_frac_q12);
        end
        wait_search(1'b1, 64'd190240);
        return_peak(64'd190242, 16'sd2048);
        expect_result(32'sd3, 32'd19);

        // The exact rounding tie this investigation started from: up=0 int +
        // 0.5 frac, down=0 int + 0.5 frac -> up=0.5, down=0.5, sum=1.0,
        // timing=0.5 exactly. Ties-away-from-zero must round this to +1, not
        // to 0 -- the boundary case where a rounding-convention mismatch
        // would first show up.
        pulse_packet(64'd200000, 16'd0);
        wait_search(1'b0, 64'd200000);
        return_peak(64'd200000, 16'sd2048);
        wait_search(1'b1, 64'd210240);
        return_peak(64'd210240, 16'sd2048);
        expect_result(32'sd1, 32'd17);

        if (errors) begin
            $display("FAIL tb_lora_joint_chirp_grid_controller (%0d errors)", errors);
            $fatal(1);
        end
        $display("PASS tb_lora_joint_chirp_grid_controller");
        $finish;
    end
endmodule
