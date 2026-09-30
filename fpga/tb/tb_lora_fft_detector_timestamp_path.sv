`timescale 1ns/1ps

module tb_lora_fft_detector_timestamp_path;
    localparam integer SF = 7;
    localparam integer SAMPLES_PER_CHIP = 8;
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
    reg resync_valid = 1'b0;
    reg [31:0] resync_skip = 32'd0;
    reg [7:0] sync_word = 8'h12;

    wire [31:0] symbol_index;
    wire symbol_valid;
    wire [15:0] confidence;
    wire [63:0] symbol_sample_count;
    wire timestamp_valid;
    wire detected;
    wire preamble_detected;
    wire sync_valid;
    wire [15:0] preamble_bin;
    wire [15:0] chips_to_boundary;
    wire [7:0] bins_seen;
    wire [63:0] preamble_start_count;
    wire preamble_start_valid;
    wire [63:0] packet_start_count;
    wire packet_start_valid;
    wire alignment_error;
    wire symbol_index_width_error;

    integer errors = 0;
    integer symbol_seen = 0;
    integer timeout_cycles = 0;
    integer preamble_timestamp_seen = 0;
    integer packet_timestamp_seen = 0;
    reg [63:0] first_symbol_timestamp = 64'd0;
    reg first_symbol_timestamp_valid = 1'b0;
    reg [31:0] expected_symbol [0:9];

    lora_fft_detector_timestamp_path dut (
        .clk(clk),
        .resetn(resetn),
        .iq_in_re(iq_in_re),
        .iq_in_im(iq_in_im),
        .valid_in(valid_in),
        .reset_in(reset_in),
        .resync_valid(resync_valid),
        .resync_skip(resync_skip),
        .sync_word(sync_word),
        .cfo_load(1'b0),
        .cfo_q12(32'sd0),
        .cfo_clear(1'b0),
        .split_detected(),
        .symbol_index(symbol_index),
        .symbol_valid(symbol_valid),
        .confidence(confidence),
        .symbol_sample_count(symbol_sample_count),
        .timestamp_valid(timestamp_valid),
        .detected(detected),
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
                // MATLAB modulate_symbol uses circshift(reference_chirp,-k*L),
                // hence output sample n comes from reference sample n+k*L.
                source_n = (n + symbol_value * SAMPLES_PER_CHIP) % SAMPLES_PER_SYMBOL;
                phase_cycles = (0.5 * source_n * source_n) /
                               (SYMBOL_COUNT * SAMPLES_PER_CHIP * SAMPLES_PER_CHIP) -
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

    task automatic expect_true(input bit condition, input string label_text);
        begin
            if (condition) begin
                $display("PASS %-58s", label_text);
            end else begin
                errors = errors + 1;
                $display("FAIL %-58s", label_text);
            end
        end
    endtask

    // Observe the real generated FFT decisions. The timestamp sideband must be
    // valid on every symbol decision and the ten symbols must match the exact
    // preamble+sync sequence fed at the IQ input.
    always @(posedge clk) begin
        #1;
        if (resetn) begin
            if (alignment_error) begin
                errors = errors + 1;
                $display("FAIL unexpected timestamp alignment error");
            end
            if (symbol_index_width_error) begin
                errors = errors + 1;
                $display("FAIL unexpected symbol-index width error");
            end

            if (symbol_valid) begin
                if (symbol_seen < 10) begin
                    if (symbol_index === expected_symbol[symbol_seen])
                        $display("PASS FFT symbol[%0d] index                                      value=%0d", symbol_seen, symbol_index);
                    else begin
                        errors = errors + 1;
                        $display("FAIL FFT symbol[%0d] index got=%0d expected=%0d", symbol_seen, symbol_index, expected_symbol[symbol_seen]);
                    end
                end else begin
                    errors = errors + 1;
                    $display("FAIL unexpected extra FFT symbol index=%0d", symbol_index);
                end

                if (!timestamp_valid) begin
                    errors = errors + 1;
                    $display("FAIL FFT symbol[%0d] missing timestamp_valid", symbol_seen);
                end
                if (confidence == 16'd0) begin
                    errors = errors + 1;
                    $display("FAIL FFT symbol[%0d] confidence is zero", symbol_seen);
                end

                if (!first_symbol_timestamp_valid) begin
                    first_symbol_timestamp <= symbol_sample_count;
                    first_symbol_timestamp_valid <= 1'b1;
                end
                symbol_seen = symbol_seen + 1;
            end

            if (preamble_start_valid) begin
                preamble_timestamp_seen = preamble_timestamp_seen + 1;
                if (first_symbol_timestamp_valid && preamble_start_count == first_symbol_timestamp)
                    $display("PASS preamble timestamp returns first FFT-symbol boundary          value=0x%016h", preamble_start_count);
                else begin
                    errors = errors + 1;
                    $display("FAIL preamble timestamp got=0x%016h first=0x%016h", preamble_start_count, first_symbol_timestamp);
                end
            end

            if (packet_start_valid) begin
                packet_timestamp_seen = packet_timestamp_seen + 1;
                if (first_symbol_timestamp_valid && packet_start_count == first_symbol_timestamp)
                    $display("PASS packet timestamp returns first FFT-symbol boundary            value=0x%016h", packet_start_count);
                else begin
                    errors = errors + 1;
                    $display("FAIL packet timestamp got=0x%016h first=0x%016h", packet_start_count, first_symbol_timestamp);
                end
            end
        end
    end

    initial begin
        expected_symbol[0] = 32'd0;
        expected_symbol[1] = 32'd0;
        expected_symbol[2] = 32'd0;
        expected_symbol[3] = 32'd0;
        expected_symbol[4] = 32'd0;
        expected_symbol[5] = 32'd0;
        expected_symbol[6] = 32'd0;
        expected_symbol[7] = 32'd0;
        expected_symbol[8] = 32'd8;
        expected_symbol[9] = 32'd16;

        repeat (6) @(posedge clk);
        resetn <= 1'b1;
        repeat (3) @(posedge clk);

        // LoRa SF7 public sync word 0x12 maps to the two detector bins used by
        // the existing bit-exact detector regression: 8 then 16.
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(0);
        drive_css_symbol(8);
        drive_css_symbol(16);

        @(negedge clk);
        valid_in <= 1'b0;
        iq_in_re <= 16'sd0;
        iq_in_im <= 16'sd0;

        // Allow the final generated FFT pipeline and detector decision to drain.
        timeout_cycles = 0;
        while ((packet_timestamp_seen == 0) && (timeout_cycles < 20000)) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        repeat (10) @(posedge clk);
        #1;

        expect_true(symbol_seen == 10, "exactly ten FFT symbol decisions observed");
        expect_true(preamble_timestamp_seen >= 1, "generated path emits aligned preamble timestamp");
        expect_true(packet_timestamp_seen == 1, "generated path emits one confirmed packet timestamp");
        expect_true(detected == 1'b0, "packet detector pulse returns low after decision");
        expect_true(alignment_error == 1'b0, "no timestamp alignment error at end of stream");
        expect_true(symbol_index_width_error == 1'b0, "no symbol-index width error at end of stream");

        if (errors == 0)
            $display("PASS tb_lora_fft_detector_timestamp_path");
        else begin
            $display("FAIL tb_lora_fft_detector_timestamp_path errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end

endmodule
