`timescale 1ns/1ps
// Arithmetic and read protocol checked against an independent integer sum.
module tb_lora_mac_response_pipeline;
    parameter integer N = 17;
    parameter integer FAST = 1;
    reg clk = 0;
    always #5 clk = ~clk;
    reg resetn = 0, stream_reset = 0, start = 0;
    wire req, valid, busy, miss_error, mismatch_error, restart_error;
    wire [63:0] address, result_address;
    wire [15:0] ref_index;
    wire signed [47:0] cr, ci;
    wire [31:0] power_result;
    reg signed [15:0] xr = 0, xi = 0;
    reg [63:0] response_address = 0;
    reg response_valid = 0, response_miss = 0;
    integer cycle = 0, reads = 0, delay_cycles = 1, countdown = 0;
    integer inject = 0, injection_index;
    reg pending = 0;
    reg [63:0] saved_address;
    integer started_cycle, completed_cycle, results = 0, misses = 0, mismatches = 0;
    longint signed expected_re, expected_im, term_re, term_im;
    longint unsigned expected_power;
    function automatic integer xre(input integer k); xre = (k % 7 - 3) * 109; endfunction
    function automatic integer xim(input integer k); xim = (k % 11 - 5) * 73; endfunction
    function automatic integer rre(input integer k); rre = (k % 5 - 2) * 67; endfunction
    function automatic integer rim(input integer k); rim = (k % 3 - 1) * 131; endfunction
    wire signed [15:0] rr = rre(ref_index), ri = rim(ref_index);
    lora_matched_filter_mac #(.REF_SAMPLES(N), .POWER_SHIFT(8),
        .REQUEST_ON_RESPONSE(FAST)) dut (
        .clk(clk), .resetn(resetn), .stream_reset(stream_reset),
        .start(start), .window_start_count(64'd100), .iq_read_req(req),
        .iq_read_sample_count(address), .iq_read_re(xr), .iq_read_im(xi),
        .iq_read_sample_count_out(response_address), .iq_read_valid(response_valid),
        .iq_read_miss(response_miss), .reference_index(ref_index),
        .reference_re(rr), .reference_im(ri), .busy(busy), .result_valid(valid),
        .result_sample_count(result_address), .correlation_re(cr), .correlation_im(ci),
        .correlation_power(power_result), .read_miss_error(miss_error),
        .response_mismatch_error(mismatch_error), .restart_error(restart_error));
    always @(posedge clk) begin
        cycle = cycle + 1;
        response_valid <= 0;
        response_miss <= 0;
        if (!resetn || stream_reset) begin pending = 0; countdown = 0; end
        else begin
            if (start && !busy) started_cycle = cycle;
            if (req) begin
                if (pending) $fatal(1, "more than one outstanding read");
                if (address !== 100 + reads || ref_index !== reads)
                    $fatal(1, "request/reference skipped or repeated, read=%0d", reads);
                saved_address = address;
                pending = 1;
                countdown = delay_cycles;
                reads = reads + 1;
            end else if (pending) countdown = countdown - 1;
            // Registered one-cycle response in delay=1 mode, with longer stalls.
            if (pending && countdown == 1) begin
                xr <= xre(saved_address - 100);
                xi <= xim(saved_address - 100);
                response_address <= saved_address + ((inject == 1 && reads-1 == injection_index) ? 1 : 0);
                response_valid <= !(inject == 2 && reads-1 == injection_index);
                response_miss <= (inject == 2 && reads-1 == injection_index);
                pending = 0;
            end
        end
        #1;
        if (valid) begin results = results + 1; completed_cycle = cycle; end
        if (miss_error) misses = misses + 1;
        if (mismatch_error) mismatches = mismatches + 1;
    end
    task automatic launch;
        begin
            @(negedge clk); reads = 0; start = 1;
            @(negedge clk); start = 0;
        end
    endtask
    task automatic await_idle;
        integer ticks;
        begin
            ticks = 0;
            while (busy && ticks < 10*N+50) begin @(negedge clk); ticks = ticks + 1; end
            if (busy) $fatal(1, "MAC timeout");
        end
    endtask
    initial begin
        expected_re = 0; expected_im = 0;
        for (integer k=0; k<N; k=k+1) begin
            term_re = xre(k)*rre(k) + xim(k)*rim(k);
            term_im = xim(k)*rre(k) - xre(k)*rim(k);
            expected_re = expected_re + term_re;
            expected_im = expected_im + term_im;
        end
        expected_power = (expected_re*expected_re + expected_im*expected_im) >> 8;
        if (expected_power > 32'hffffffff) expected_power = 32'hffffffff;
        injection_index = N > 3 ? 3 : 0;
        repeat (3) @(negedge clk); resetn = 1;
        for (integer d=1; d<=4; d=d+3) begin
            delay_cycles = d;
            launch(); await_idle();
            if (cr !== expected_re || ci !== expected_im || power_result !== expected_power[31:0] || result_address !== 100)
                $fatal(1, "complex sum/power mismatch N=%0d delay=%0d: %0d+j%0d", N, d, cr, ci);
            if (reads != N) $fatal(1, "wrong read count");
            if (d == 1 && completed_cycle-started_cycle != (FAST ? N+3 : 2*N+2))
                $fatal(1, "unexpected latency %0d", completed_cycle-started_cycle);
            $display("LATENCY N=%0d fast=%0d response_delay=%0d clocks=%0d", N, FAST, d, completed_cycle-started_cycle);
        end
        delay_cycles = 1; inject = 1;
        launch(); await_idle();
        if (mismatches != 1 || results != 2 || reads != injection_index+1) $fatal(1, "bad address did not abort");
        inject = 2;
        launch(); await_idle();
        if (misses != 1 || results != 2 || reads != injection_index+1) $fatal(1, "missing read did not abort");
        inject = 0; delay_cycles = 4;
        launch(); @(negedge clk); stream_reset = 1;
        @(negedge clk); stream_reset = 0;
        repeat (8) @(negedge clk);
        if (busy || results != 2) $fatal(1, "reset emitted stale result");
        launch(); await_idle();
        if (results != 3 || cr !== expected_re || ci !== expected_im) $fatal(1, "post-reset recovery failed");
        $display("PASS tb_lora_mac_response_pipeline N=%0d fast=%0d", N, FAST);
        $finish;
    end
endmodule
