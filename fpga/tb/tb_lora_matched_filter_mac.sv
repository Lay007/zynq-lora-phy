`timescale 1ns/1ps

module tb_lora_matched_filter_mac;
    parameter integer REQUEST_ON_RESPONSE = 0;
    localparam integer REF_SAMPLES = 4;
    localparam integer ACC_WIDTH = 40;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg stream_reset = 1'b0;

    reg signed [15:0] iq_in_re = 16'sd0;
    reg signed [15:0] iq_in_im = 16'sd0;
    reg sample_valid = 1'b0;

    wire iq_read_req;
    wire [63:0] iq_read_sample_count;
    wire signed [15:0] iq_read_re;
    wire signed [15:0] iq_read_im;
    wire [63:0] iq_read_sample_count_out;
    wire iq_read_valid;
    wire iq_read_miss;

    wire [63:0] next_sample_count;
    wire [63:0] oldest_sample_count;
    wire [31:0] samples_retained;

    reg start = 1'b0;
    reg [63:0] window_start_count = 64'd0;
    wire [15:0] reference_index;
    reg signed [15:0] reference_re;
    reg signed [15:0] reference_im;

    wire busy;
    wire result_valid;
    wire [63:0] result_sample_count;
    wire signed [ACC_WIDTH-1:0] correlation_re;
    wire signed [ACC_WIDTH-1:0] correlation_im;
    wire [31:0] correlation_power;
    wire read_miss_error;
    wire response_mismatch_error;
    wire restart_error;

    integer errors = 0;
    integer result_seen = 0;
    integer restart_seen = 0;
    integer miss_seen = 0;
    integer mismatch_seen = 0;

    lora_iq_history_buffer #(
        .DEPTH(16)
    ) history (
        .clk(clk),
        .resetn(resetn),
        .stream_reset(stream_reset),
        .iq_in_re(iq_in_re),
        .iq_in_im(iq_in_im),
        .sample_valid(sample_valid),
        .read_req(iq_read_req),
        .read_sample_count(iq_read_sample_count),
        .read_iq_re(iq_read_re),
        .read_iq_im(iq_read_im),
        .read_sample_count_out(iq_read_sample_count_out),
        .read_valid(iq_read_valid),
        .read_miss(iq_read_miss),
        .next_sample_count(next_sample_count),
        .oldest_sample_count(oldest_sample_count),
        .samples_retained(samples_retained)
    );

    lora_matched_filter_mac #(
        .REF_SAMPLES(REF_SAMPLES),
        .ACC_WIDTH(ACC_WIDTH),
        .POWER_SHIFT(0),
        .REQUEST_ON_RESPONSE(REQUEST_ON_RESPONSE)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .stream_reset(stream_reset),
        .start(start),
        .window_start_count(window_start_count),
        .iq_read_req(iq_read_req),
        .iq_read_sample_count(iq_read_sample_count),
        .iq_read_re(iq_read_re),
        .iq_read_im(iq_read_im),
        .iq_read_sample_count_out(iq_read_sample_count_out),
        .iq_read_valid(iq_read_valid),
        .iq_read_miss(iq_read_miss),
        .reference_index(reference_index),
        .reference_re(reference_re),
        .reference_im(reference_im),
        .busy(busy),
        .result_valid(result_valid),
        .result_sample_count(result_sample_count),
        .correlation_re(correlation_re),
        .correlation_im(correlation_im),
        .correlation_power(correlation_power),
        .read_miss_error(read_miss_error),
        .response_mismatch_error(response_mismatch_error),
        .restart_error(restart_error)
    );

    // Four deliberately nontrivial complex coefficients. The first test
    // stores x[k] = reference[k], so C=sum |reference|^2 = 56 + j0.
    always @* begin
        case (reference_index)
            16'd0: begin reference_re =  16'sd3; reference_im =  16'sd4; end
            16'd1: begin reference_re = -16'sd2; reference_im =  16'sd1; end
            16'd2: begin reference_re =  16'sd1; reference_im = -16'sd3; end
            16'd3: begin reference_re =  16'sd4; reference_im =  16'sd0; end
            default: begin reference_re = 16'sd0; reference_im = 16'sd0; end
        endcase
    end

    task automatic push_sample(input integer re_value, input integer im_value);
        begin
            @(negedge clk);
            iq_in_re = re_value;
            iq_in_im = im_value;
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            iq_in_re = 16'sd0;
            iq_in_im = 16'sd0;
        end
    endtask

    task automatic pulse_start(input [63:0] start_count);
        begin
            @(negedge clk);
            window_start_count = start_count;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic pulse_stream_reset;
        begin
            @(negedge clk);
            stream_reset = 1'b1;
            @(negedge clk);
            stream_reset = 1'b0;
        end
    endtask

    task automatic expect_u64(input [63:0] got, input [63:0] expected, input string label_text);
        begin
            if (got === expected)
                $display("PASS %-58s value=0x%016h", label_text, got);
            else begin
                errors = errors + 1;
                $display("FAIL %-58s got=0x%016h expected=0x%016h", label_text, got, expected);
            end
        end
    endtask

    task automatic expect_signed(input signed [ACC_WIDTH-1:0] got,
                                 input integer expected,
                                 input string label_text);
        begin
            if (got === expected)
                $display("PASS %-58s value=%0d", label_text, $signed(got));
            else begin
                errors = errors + 1;
                $display("FAIL %-58s got=%0d expected=%0d", label_text, $signed(got), expected);
            end
        end
    endtask

    task automatic expect_u32(input [31:0] got, input [31:0] expected, input string label_text);
        begin
            if (got === expected)
                $display("PASS %-58s value=0x%08h", label_text, got);
            else begin
                errors = errors + 1;
                $display("FAIL %-58s got=0x%08h expected=0x%08h", label_text, got, expected);
            end
        end
    endtask

    task automatic wait_for_result(input integer previous_count);
        integer timeout;
        begin
            timeout = 0;
            while ((result_seen == previous_count) && (timeout < 100)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (result_seen == previous_count) begin
                errors = errors + 1;
                $display("FAIL timed out waiting for matched-filter result");
            end
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (result_valid)
            result_seen = result_seen + 1;
        if (restart_error)
            restart_seen = restart_seen + 1;
        if (read_miss_error)
            miss_seen = miss_seen + 1;
        if (response_mismatch_error)
            mismatch_seen = mismatch_seen + 1;
    end

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        if (!busy)
            $display("PASS matched-filter busy reset");
        else begin
            errors = errors + 1;
            $display("FAIL matched-filter busy reset");
        end
        if (!result_valid)
            $display("PASS matched-filter result valid reset");
        else begin
            errors = errors + 1;
            $display("FAIL matched-filter result valid reset");
        end

        // Absolute sample counts 0..1 are unrelated prefix samples.
        push_sample(9, -7);
        push_sample(-5, 6);

        // Counts 2..5 equal the reference exactly.
        push_sample( 3,  4);
        push_sample(-2,  1);
        push_sample( 1, -3);
        push_sample( 4,  0);

        // Counts 6..9 equal j*reference: (-imag, real). The matched filter
        // must therefore produce C = j*56 with the same power.
        push_sample(-4,  3);
        push_sample(-1, -2);
        push_sample( 3,  1);
        push_sample( 0,  4);

        expect_u64(next_sample_count, 64'd10, "history contains ten accepted samples");
        expect_u64(oldest_sample_count, 64'd0, "history has not wrapped before MAC tests");

        // Exact reference match.
        pulse_start(64'd2);
        wait_for_result(0);
        expect_u64(result_sample_count, 64'd2, "matched-filter result keeps requested absolute count");
        expect_signed(correlation_re, 56, "exact reference correlation real");
        expect_signed(correlation_im, 0, "exact reference correlation imag");
        expect_u32(correlation_power, 32'd3136, "exact reference correlation power");
        @(posedge clk); #1;
        if (!result_valid)
            $display("PASS matched-filter result valid is one-cycle pulse");
        else begin
            errors = errors + 1;
            $display("FAIL matched-filter result valid is one-cycle pulse");
        end

        // +90 degree phase rotation preserves power and moves the correlation
        // from the real to the imaginary axis.
        pulse_start(64'd6);
        wait_for_result(1);
        expect_u64(result_sample_count, 64'd6, "phase-rotated result keeps requested count");
        expect_signed(correlation_re, 0, "phase-rotated correlation real");
        expect_signed(correlation_im, 56, "phase-rotated correlation imag");
        expect_u32(correlation_power, 32'd3136, "phase-rotated correlation power invariant");

        // A second start while the first request is running is rejected and
        // must not redirect the in-flight MAC.
        pulse_start(64'd2);
        @(negedge clk);
        window_start_count = 64'd6;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        wait_for_result(2);
        if (restart_seen == 1)
            $display("PASS matched-filter restart while busy is reported");
        else begin
            errors = errors + 1;
            $display("FAIL matched-filter restart count got=%0d expected=1", restart_seen);
        end
        expect_u64(result_sample_count, 64'd2, "rejected restart preserves original window");
        expect_signed(correlation_re, 56, "rejected restart preserves original correlation");

        // Requesting a window outside retained IQ aborts cleanly on the first
        // history response and emits no matched-filter result.
        pulse_start(64'd100);
        begin : wait_for_abort
            integer timeout;
            timeout = 0;
            while (busy && timeout < 30) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
        end
        @(posedge clk); #1;
        if (miss_seen == 1)
            $display("PASS matched-filter propagates IQ history read miss");
        else begin
            errors = errors + 1;
            $display("FAIL matched-filter read miss count got=%0d expected=1", miss_seen);
        end
        if (result_seen == 3)
            $display("PASS read miss emits no matched-filter result");
        else begin
            errors = errors + 1;
            $display("FAIL read miss unexpectedly changed result count to %0d", result_seen);
        end
        if (mismatch_seen == 0)
            $display("PASS matched-filter history response counts stay aligned");
        else begin
            errors = errors + 1;
            $display("FAIL unexpected response mismatch count=%0d", mismatch_seen);
        end

        // A stream reset aborts a request and returns both the history buffer
        // and the MAC to the same accepted-sample epoch.
        pulse_start(64'd2);
        repeat (2) @(posedge clk);
        pulse_stream_reset();
        @(posedge clk); #1;
        if (!busy)
            $display("PASS stream reset aborts in-flight matched filter");
        else begin
            errors = errors + 1;
            $display("FAIL stream reset left matched filter busy");
        end
        expect_u64(next_sample_count, 64'd0, "stream reset also restarts history sample epoch");

        if (errors == 0)
            $display("PASS tb_lora_matched_filter_mac");
        else begin
            $display("FAIL tb_lora_matched_filter_mac errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule
