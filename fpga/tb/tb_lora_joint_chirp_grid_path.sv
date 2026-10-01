`timescale 1ns/1ps

`ifdef LORA_NAMESPACED_GENERATED
`define LORA_TOA_INTERPOLATOR_MODULE lora_toa_ToaInterpolator
`else
`define LORA_TOA_INTERPOLATOR_MODULE ToaInterpolator
`endif

module tb_lora_joint_chirp_grid_path;
    localparam integer M = 1024;
    localparam integer SEARCH_RADIUS = 16;
    localparam integer HISTORY_DEPTH = 32768;
    // Sixty-three clocks per sample is a property of the board wiring, not of
    // this RTL: it holds because lora_overlay_injection.tcl clocks the
    // receiver from a fixed 62.5 MHz PL clock while the AD9361 runs at
    // 1 MS/s. It was false for the whole of the joint search's life before
    // that, when the receiver ran on util_ad9361_divclk/clk_out and got one
    // clock per sample, and this test passed anyway. Nothing here can detect
    // that; the board reports it, through the clock page of the CLG400
    // bridge, and run_clg400_payload_capture checks it on every capture.
    localparam integer CLOCKS_PER_SAMPLE_CEIL = 63;
    localparam integer SFD_SAMPLES = 2304;
    localparam real PI = 3.14159265358979323846;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg stream_reset = 1'b0;
    reg signed [15:0] iq_in_re = 16'sd0;
    reg signed [15:0] iq_in_im = 16'sd0;
    reg sample_valid = 1'b0;
    reg packet_start_valid = 1'b0;
    reg [63:0] packet_start_count = 64'd1000;
    // The arrival phase the detector hands the controller. It was a
    // constant zero here, so the controller's use of it was never
    // exercised at all: on the board it consumed the signal a pulse too
    // late and always saw zero, and this test could not tell.
    //
    // The stimulus puts the upchirp at 1008 and the downchirp at 11254
    // against a packet start of 1000, so up_coarse_start is 1000 + 8C
    // and the true timing correction is 11 - 8C.
    integer chips = 0;
    reg [15:0] chips_to_boundary = 16'd0;
    integer expected_timing;

    wire iq_read_req;
    wire [63:0] iq_read_sample_count;
    wire signed [15:0] iq_read_re;
    wire signed [15:0] iq_read_im;
    wire [63:0] iq_read_sample_count_out;
    wire iq_read_valid;
    wire iq_read_miss;
    wire [63:0] history_next_sample_count;
    wire [63:0] history_oldest_sample_count;
    wire [31:0] history_samples_retained;

    wire [15:0] reference_index;
    wire signed [15:0] reference_up_re;
    wire signed [15:0] reference_up_im;
    wire signed [15:0] selected_reference_im =
        reference_down ? -reference_up_im : reference_up_im;

    wire search_start;
    wire [63:0] search_coarse_start;
    wire reference_down;
    wire controller_busy;
    wire search_busy;
    wire [31:0] correlation_magnitude;
    wire correlation_magnitude_valid;
    wire [63:0] correlation_sample_count;
    wire [31:0] magnitude_before;
    wire [31:0] magnitude_peak;
    wire [31:0] magnitude_after;
    wire [15:0] peak_index;
    wire [63:0] peak_sample_count;
    wire triplet_valid;
    wire signed [31:0] toa_offset_q12;
    wire toa_offset_valid;
    wire signed [31:0] toa_log_peak_q12_unused;
    wire signed [31:0] timing_correction_samples;
    wire [31:0] fine_skip;
    wire fine_resync_valid;
    wire timing_valid;
    wire restart_error;
    wire timing_range_error;
    wire underflow_error;
    wire search_restart_error;
    wire mac_window_mismatch_error;
    wire mac_read_miss_error;
    wire mac_response_mismatch_error;
    wire mac_restart_error;
    wire peak_boundary_error;
    wire peak_restart_error;
    wire search_failed = underflow_error || search_restart_error ||
        mac_window_mismatch_error || mac_read_miss_error ||
        mac_response_mismatch_error || mac_restart_error ||
        peak_boundary_error || peak_restart_error;

    integer errors = 0;
    integer n;
    integer q_re;
    integer q_im;
    integer source_n;
    integer cycles_after_detection = 0;
    // The board never stops delivering samples while the joint search runs.
    // With the stream halted the write pointer is frozen, so the read window
    // cannot age out and read_write_collision cannot fire at all - the two
    // things that abort the search on hardware. +stream_during_search keeps
    // the stream going, and +stream_gap sets its pacing in idle clocks per
    // sample (63 is the 1 MS/s to 62.5 MHz ratio).
    integer stream_during_search = 0;
    integer stream_gap = 0;
    integer post_stream_gap = 0;
    wire [3:0] dut_state = controller.state;
    reg timing_seen = 1'b0;
    real phase_cycles;
    real angle;

    lora_iq_history_buffer #(.DEPTH(HISTORY_DEPTH)) history (
        .clk(clk), .resetn(resetn), .stream_reset(stream_reset),
        .iq_in_re(iq_in_re), .iq_in_im(iq_in_im),
        .sample_valid(sample_valid), .read_req(iq_read_req),
        .read_sample_count(iq_read_sample_count), .read_iq_re(iq_read_re),
        .read_iq_im(iq_read_im),
        .read_sample_count_out(iq_read_sample_count_out),
        .read_valid(iq_read_valid), .read_miss(iq_read_miss),
        .next_sample_count(history_next_sample_count),
        .oldest_sample_count(history_oldest_sample_count),
        .samples_retained(history_samples_retained)
    );

    lora_reference_chirp_rom #(
        .REF_SAMPLES(M),
        .INIT_FILE("fpga/rom/lora_sf7_l8_reference_q10.mem")
    ) reference_rom (
        .reference_index(reference_index),
        .reference_re(reference_up_re),
        .reference_im(reference_up_im)
    );

    lora_matched_filter_search #(
        .REF_SAMPLES(M), .SEARCH_RADIUS(SEARCH_RADIUS),
        .ACC_WIDTH(48), .POWER_SHIFT(30)
    ) search (
        .clk(clk), .resetn(resetn), .stream_reset(stream_reset),
        .start(search_start), .coarse_start_count(search_coarse_start),
        .iq_read_req(iq_read_req),
        .iq_read_sample_count(iq_read_sample_count),
        .iq_read_re(iq_read_re), .iq_read_im(iq_read_im),
        .iq_read_sample_count_out(iq_read_sample_count_out),
        .iq_read_valid(iq_read_valid), .iq_read_miss(iq_read_miss),
        .reference_index(reference_index), .reference_re(reference_up_re),
        .reference_im(selected_reference_im), .busy(search_busy),
        .search_first_count(), .correlation_magnitude(correlation_magnitude),
        .correlation_magnitude_valid(correlation_magnitude_valid),
        .correlation_sample_count(correlation_sample_count),
        .magnitude_before(magnitude_before), .magnitude_peak(magnitude_peak),
        .magnitude_after(magnitude_after), .peak_index(peak_index),
        .peak_sample_count(peak_sample_count), .triplet_valid(triplet_valid),
        .underflow_error(underflow_error),
        .search_restart_error(search_restart_error),
        .mac_window_mismatch_error(mac_window_mismatch_error),
        .mac_read_miss_error(mac_read_miss_error),
        .mac_response_mismatch_error(mac_response_mismatch_error),
        .mac_restart_error(mac_restart_error),
        .peak_boundary_error(peak_boundary_error),
        .peak_restart_error(peak_restart_error)
    );

    // Same generated interpolator the legacy single-search path uses,
    // reused here for both joint-grid legs sequentially -- see the wiring
    // note in lora_packet_toa_receiver_top.v that this mirrors.
    `LORA_TOA_INTERPOLATOR_MODULE u_toa_interpolator (
        .clk(clk),
        .reset(~resetn),
        .enb(1'b1),
        .magnitudeBefore(magnitude_before),
        .magnitudePeak(magnitude_peak),
        .magnitudeAfter(magnitude_after),
        .tripletValid(triplet_valid),
        .offsetSamples(toa_offset_q12),
        .offsetValid(toa_offset_valid),
        .logPeak(toa_log_peak_q12_unused)
    );

    lora_joint_chirp_grid_controller #(
        .SAMPLES_PER_CHIP(8), .SYMBOL_SAMPLES(M),
        .SEARCH_RADIUS(SEARCH_RADIUS), .FINE_GUARD_SAMPLES(16),
        .PREAMBLE_TO_SFD_SYMBOLS(10)
    ) controller (
        .clk(clk), .resetn(resetn), .stream_reset(stream_reset),
        .packet_start_valid(packet_start_valid),
        .packet_start_count(packet_start_count),
        .chips_to_boundary(chips_to_boundary),
        .packet_straddle(1'b0),
        .history_next_sample_count(history_next_sample_count),
        .search_busy(search_busy), .search_failed(search_failed),
        .search_triplet_valid(triplet_valid),
        .search_peak_sample_count(peak_sample_count),
        .search_offset_q12(toa_offset_q12[15:0]),
        .search_offset_valid(toa_offset_valid),
        .search_start(search_start),
        .search_coarse_start(search_coarse_start),
        .reference_down(reference_down), .busy(controller_busy),
        .timing_correction_samples(timing_correction_samples),
        .fine_skip(fine_skip), .fine_resync_valid(fine_resync_valid),
        .timing_valid(timing_valid), .restart_error(restart_error),
        .timing_range_error(timing_range_error)
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

    task automatic drive_history_sample(input integer sample_number);
        begin
            q_re = 0;
            q_im = 0;
            if (sample_number >= 1008 && sample_number < 1008 + M) begin
                source_n = sample_number - 1008;
                phase_cycles = (0.5 * source_n * source_n) / (128.0 * 64.0)
                               - (0.5 * source_n) / 8.0;
                angle = 2.0 * PI * phase_cycles;
                q_re = quantize_q10($cos(angle));
                q_im = quantize_q10($sin(angle));
            end else if (sample_number >= 11254 && sample_number < 11254 + M) begin
                source_n = sample_number - 11254;
                phase_cycles = (0.5 * source_n * source_n) / (128.0 * 64.0)
                               - (0.5 * source_n) / 8.0;
                angle = 2.0 * PI * phase_cycles;
                q_re = quantize_q10($cos(angle));
                q_im = -quantize_q10($sin(angle));
            end
            @(negedge clk);
            iq_in_re <= q_re;
            iq_in_im <= q_im;
            sample_valid <= 1'b1;
            if (stream_gap > 0) begin
                @(negedge clk);
                sample_valid <= 1'b0;
                repeat (stream_gap - 1) @(negedge clk);
            end
        end
    endtask

    always @(posedge clk) begin
        if (packet_start_valid)
            cycles_after_detection <= 0;
        else if (controller_busy)
            cycles_after_detection <= cycles_after_detection + 1;

        if (timing_valid) begin
            timing_seen <= 1'b1;
            if (timing_correction_samples !== expected_timing ||
                fine_skip !== (16 + expected_timing) ||
                !fine_resync_valid) begin
                errors <= errors + 1;
                $display("FAIL joint path correction=%0d skip=%0d fine=%0d",
                         timing_correction_samples, fine_skip, fine_resync_valid);
            end
            if (cycles_after_detection + fine_skip * CLOCKS_PER_SAMPLE_CEIL
                >= SFD_SAMPLES * CLOCKS_PER_SAMPLE_CEIL) begin
                errors <= errors + 1;
                $display("FAIL joint path misses SFD deadline cycles=%0d skip=%0d",
                         cycles_after_detection, fine_skip);
            end else begin
                $display("PASS joint path timing cycles=%0d fine_skip=%0d deadline=%0d",
                         cycles_after_detection, fine_skip,
                         SFD_SAMPLES * CLOCKS_PER_SAMPLE_CEIL);
            end
        end
    end

    initial begin
        if (!$value$plusargs("stream_during_search=%d", stream_during_search))
            stream_during_search = 0;
        if (!$value$plusargs("stream_gap=%d", post_stream_gap))
            post_stream_gap = 0;
        stream_gap = 0;
        if (!$value$plusargs("chips_to_boundary=%d", chips))
            chips = 0;
        chips_to_boundary = chips[15:0];
        expected_timing = 11 - 8 * chips;
        $display("INFO chips_to_boundary=%0d expected_timing=%0d",
                 chips, expected_timing);
        $display("INFO stream_during_search=%0d post_stream_gap=%0d",
                 stream_during_search, post_stream_gap);
        repeat (5) @(posedge clk);
        resetn <= 1'b1;
        repeat (3) @(posedge clk);

        for (n = 0; n < 13000; n = n + 1)
            drive_history_sample(n);
        @(negedge clk);
        sample_valid <= 1'b0;
        iq_in_re <= 16'sd0;
        iq_in_im <= 16'sd0;

        @(negedge clk);
        packet_start_valid <= 1'b1;
        @(negedge clk);
        packet_start_valid <= 1'b0;

        if (stream_during_search) begin
            // Keep feeding the history exactly as the board does. The search
            // now races the write pointer instead of reading a frozen buffer.
            stream_gap = post_stream_gap;
            n = 13000;
            while (!timing_seen && n < 13000 + 200000) begin
                drive_history_sample(n);
                n = n + 1;
            end
            @(negedge clk);
            sample_valid <= 1'b0;
        end
        while (!timing_seen) @(negedge clk);
        repeat (4) @(posedge clk);

        if (underflow_error || search_restart_error ||
            mac_window_mismatch_error || mac_read_miss_error ||
            mac_response_mismatch_error || mac_restart_error ||
            peak_boundary_error || peak_restart_error || restart_error ||
            timing_range_error) begin
            errors = errors + 1;
            $display("FAIL unexpected joint path error flag");
        end

        if (errors) begin
            $display("FAIL tb_lora_joint_chirp_grid_path (%0d errors)", errors);
            $fatal(1);
        end
        $display("PASS tb_lora_joint_chirp_grid_path cycles_after_detection=%0d fine_skip=%0d",
                 cycles_after_detection, fine_skip);
        $finish;
    end

    initial begin
        #200000000;
        // Name the flags: a bare timeout does not say whether the search
        // aborted, stalled, or simply had not finished yet.
        $display("FAIL tb_lora_joint_chirp_grid_path timeout: state=%0d busy=%0d cycles=%0d",
                 dut_state, controller_busy, cycles_after_detection);
        $display("     flags underflow=%0b restart=%0b window=%0b readmiss=%0b resp=%0b macrestart=%0b boundary=%0b peakrestart=%0b ctlrestart=%0b range=%0b",
                 underflow_error, search_restart_error, mac_window_mismatch_error,
                 mac_read_miss_error, mac_response_mismatch_error, mac_restart_error,
                 peak_boundary_error, peak_restart_error, restart_error,
                 timing_range_error);
        $fatal(1);
    end
endmodule
