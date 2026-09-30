`timescale 1ns/1ps

// lora_preamble_accumulator against tools/gen_preamble_accumulator_vectors.py (#36).
//
// Each case replays per-bin |X|^2 of real windows (bench packet at a known phase in AWGN, noise
// only for the last case) the way the M11 core emits them: 128 bins back to back, then the
// window's decision. Checks the trigger window, the accumulated peak bin, the sub-chip step q
// and the grid skip against the integer reference, that the request is held across exactly one
// accepted sample, that 'aligned' lasts ALIGNED_WINDOWS windows, and that a detection disarms.
module tb_lora_preamble_accumulator;
    localparam integer N = 128;
    localparam integer MAXW = 64;
    localparam integer CASES = 5;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg stream_reset = 1'b0;
    reg sample_valid = 1'b0;
    reg packet_detected = 1'b0;
    reg [39:0] bin_power = 40'd0;
    reg [31:0] bin_index = 32'd0;
    reg bin_valid = 1'b0;
    reg window_done = 1'b0;

    wire resync_request;
    wire [31:0] resync_skip;
    wire aligned;
    wire [15:0] trigger_bin;
    wire [3:0] trigger_fraction;
    wire triggered;

    lora_preamble_accumulator dut (
        .clk(clk), .resetn(resetn), .stream_reset(stream_reset), .enable(1'b1),
        .sample_valid(sample_valid), .packet_detected(packet_detected),
        .bin_power(bin_power), .bin_index(bin_index), .bin_valid(bin_valid),
        .window_done(window_done),
        .resync_request(resync_request), .resync_skip(resync_skip), .aligned(aligned),
        .trigger_bin(trigger_bin), .trigger_fraction(trigger_fraction), .triggered(triggered));

    reg [39:0] pw [0:MAXW*N-1];
    reg [7:0]  pb [0:MAXW*N-1];
    integer exp_win [0:CASES-1];
    integer exp_bin [0:CASES-1];
    integer exp_q [0:CASES-1];
    integer exp_skip [0:CASES-1];
    integer nwin [0:CASES-1];

    integer failures = 0;
    integer c, w, b, fd, r, cn;
    integer got_win, got_bin, got_q, got_skip, req_samples, aligned_windows;
    string path;

    task automatic one_sample;
        begin
            @(posedge clk); sample_valid <= 1'b1;
            @(posedge clk); sample_valid <= 1'b0;
            if (resync_request === 1'b1) req_samples = req_samples + 1;
        end
    endtask

    initial begin
        fd = $fopen("fpga/tb/vectors/preamble_accumulator/expected.txt", "r");
        for (c = 0; c < CASES; c = c + 1)
            r = $fscanf(fd, "%d %d %d %d %d %d\n", cn, exp_win[c], exp_bin[c], exp_q[c], exp_skip[c], nwin[c]);
        $fclose(fd);

        for (c = 0; c < CASES; c = c + 1) begin
            path = $sformatf("fpga/tb/vectors/preamble_accumulator/case_%0d.hex", c);
            fd = $fopen(path, "r");
            for (w = 0; w < nwin[c] * N; w = w + 1)
                r = $fscanf(fd, "%h %h\n", pw[w], pb[w]);
            $fclose(fd);

            resetn = 1'b0; repeat (3) @(posedge clk); resetn = 1'b1;
            stream_reset <= 1'b1; @(posedge clk); stream_reset <= 1'b0;
            got_win = -1; got_bin = 0; got_q = 0; got_skip = 0; req_samples = 0; aligned_windows = 0;
            for (w = 0; w < nwin[c]; w = w + 1) begin
                for (b = 0; b < N; b = b + 1) begin
                    @(posedge clk);
                    bin_valid <= 1'b1; bin_power <= pw[w * N + b]; bin_index <= pb[w * N + b];
                end
                @(posedge clk); bin_valid <= 1'b0;
                repeat (4) begin
                    @(posedge clk);
                    if (triggered && got_win < 0) begin
                        got_win = w; got_bin = trigger_bin;
                        got_q = $signed(trigger_fraction); got_skip = resync_skip;
                    end
                end
                // a few accepted samples between windows, like the real stream
                repeat (3) one_sample();
                @(posedge clk); window_done <= 1'b1;
                @(posedge clk); window_done <= 1'b0;
                if (aligned) aligned_windows = aligned_windows + 1;
            end
            if (got_win != exp_win[c] || (exp_win[c] >= 0 && (got_bin != exp_bin[c] ||
                got_q != exp_q[c] || got_skip != exp_skip[c]))) begin
                $display("FAIL case %0d: window %0d bin %0d q %0d skip %0d, expected %0d %0d %0d %0d",
                         c, got_win, got_bin, got_q, got_skip, exp_win[c], exp_bin[c], exp_q[c], exp_skip[c]);
                failures = failures + 1;
            end else
                $display("case %0d: trigger window %0d bin %0d q %0d skip %0d (matches the reference)",
                         c, got_win, got_bin, got_q, got_skip);
            if (exp_win[c] >= 0 && req_samples != 1) begin
                $display("FAIL case %0d: resync request held over %0d accepted samples, expected 1", c, req_samples);
                failures = failures + 1;
            end
            if (exp_win[c] >= 0) begin
                // aligned from the trigger window on, for ALIGNED_WINDOWS (18) windows or to the end
                if (aligned_windows != ((nwin[c] - exp_win[c]) < 18 ? (nwin[c] - exp_win[c]) : 18)) begin
                    $display("FAIL case %0d: aligned for %0d windows", c, aligned_windows);
                    failures = failures + 1;
                end
            end
        end

        // A detection disarms until stream_reset: replay case 0 with a detection before the trigger.
        resetn = 1'b0; repeat (3) @(posedge clk); resetn = 1'b1;
        path = "fpga/tb/vectors/preamble_accumulator/case_0.hex";
        fd = $fopen(path, "r");
        for (w = 0; w < nwin[0] * N; w = w + 1) r = $fscanf(fd, "%h %h\n", pw[w], pb[w]);
        $fclose(fd);
        @(posedge clk); packet_detected <= 1'b1; @(posedge clk); packet_detected <= 1'b0;
        got_win = -1;
        for (w = 0; w < nwin[0]; w = w + 1) begin
            for (b = 0; b < N; b = b + 1) begin
                @(posedge clk); bin_valid <= 1'b1; bin_power <= pw[w * N + b]; bin_index <= pb[w * N + b];
            end
            @(posedge clk); bin_valid <= 1'b0;
            repeat (4) begin @(posedge clk); if (triggered) got_win = w; end
            @(posedge clk); window_done <= 1'b1; @(posedge clk); window_done <= 1'b0;
        end
        if (got_win >= 0) begin
            $display("FAIL: triggered after a detection without re-arming");
            failures = failures + 1;
        end else
            $display("disarmed after a detection: no trigger");

        if (failures == 0) $display("PASS: lora_preamble_accumulator");
        else $display("FAILURES: %0d", failures);
        $finish;
    end
endmodule
