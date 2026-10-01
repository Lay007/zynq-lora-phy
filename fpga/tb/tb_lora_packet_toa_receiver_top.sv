`timescale 1ns/1ps

module tb_lora_packet_toa_receiver_top;
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
    integer symbol_seen = 0;
    integer packet_start_seen = 0;
    integer correlation_seen = 0;
    integer triplet_seen = 0;
    integer toa_seen = 0;
    integer metadata_seen = 0;
    integer timeout_cycles = 0;
    reg [31:0] expected_symbol [0:10];
    reg [31:0] read_value;
    reg [63:0] captured_metadata_coarse = 64'd0;
    reg signed [31:0] captured_metadata_fractional = 32'sd0;

    lora_packet_toa_receiver_top dut (
        .clk(clk), .resetn(resetn),
        .iq_in_re(iq_in_re), .iq_in_im(iq_in_im), .valid_in(valid_in),
        .reset_in(reset_in), .trace_rearm_in(1'b0), .resync_valid(resync_valid),
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

    task automatic axi_read(input [5:0] address, output [31:0] value);
        begin
            @(negedge clk);
            araddr = address; arvalid = 1'b1;
            while (!arready) @(negedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid) @(negedge clk);
            value = rdata;
            if (rresp !== 2'b00) errors = errors + 1;
            rready = 1'b1;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (resetn) begin
            if (symbol_valid) begin
                // The first eleven are the detection stimulus; the SFD and
                // header decisions after them are not asserted here.
                if (symbol_seen < 11 && symbol_index !== expected_symbol[symbol_seen]) begin
                    errors = errors + 1;
                    $display("FAIL integrated symbol[%0d] got=%0d", symbol_seen,
                             symbol_index);
                end
                symbol_seen = symbol_seen + 1;
            end
            if (packet_start_valid) begin
                packet_start_seen = packet_start_seen + 1;
                if (packet_start_count !== 64'd1024) begin
                    errors = errors + 1;
                    $display("FAIL packet start got=%0d expected=1024",
                             packet_start_count);
                end
            end
            // Two searches, each 2*16+1 correlations: the up leg around the
            // first preamble upchirp (1024 - 16 ..), then the down leg around
            // the first SFD downchirp, ten symbols later (11264 - 16 ..).
            if (correlation_magnitude_valid) begin
                if (correlation_sample_count !== (correlation_seen < 33
                        ? 64'd1008 + correlation_seen
                        : 64'd11248 + (correlation_seen - 33))) begin
                    errors = errors + 1;
                    $display("FAIL integrated correlation count[%0d] got=%0d",
                             correlation_seen, correlation_sample_count);
                end
                correlation_seen = correlation_seen + 1;
            end
            if (peak_triplet_valid) begin
                triplet_seen = triplet_seen + 1;
                if (peak_index !== 16'd16 || peak_sample_count !== 64'd1024) begin
                    errors = errors + 1;
                    $display("FAIL integrated peak index=%0d count=%0d",
                             peak_index, peak_sample_count);
                end
            end
            if (toa_offset_valid)
                toa_seen = toa_seen + 1;
            if (metadata_valid) begin
                metadata_seen = metadata_seen + 1;
                captured_metadata_coarse <= metadata_coarse;
                captured_metadata_fractional <= metadata_fractional_q12;
                if (metadata_coarse !== 64'd1024) begin
                    errors = errors + 1;
                    $display("FAIL integrated metadata coarse=%0d", metadata_coarse);
                end
                if (metadata_fractional_q12 < -32'sd2048 ||
                    metadata_fractional_q12 > 32'sd2048) begin
                    errors = errors + 1;
                    $display("FAIL fractional ToA outside +/-0.5 sample: %0d",
                             metadata_fractional_q12);
                end
            end

            if (alignment_error || symbol_index_width_error || metadata_overflow ||
                toa_underflow_error || toa_search_restart_error ||
                toa_mac_window_mismatch_error || toa_mac_read_miss_error ||
                toa_mac_response_mismatch_error || toa_mac_restart_error ||
                toa_peak_boundary_error || toa_peak_restart_error) begin
                errors = errors + 1;
                $display("FAIL unexpected integrated receiver error flag");
            end
        end
    end

    initial begin
        expected_symbol[0]=37;
        expected_symbol[1]=0; expected_symbol[2]=0; expected_symbol[3]=0;
        expected_symbol[4]=0; expected_symbol[5]=0; expected_symbol[6]=0;
        expected_symbol[7]=0; expected_symbol[8]=0;
        expected_symbol[9]=8; expected_symbol[10]=16;

        repeat (6) @(posedge clk);
        resetn <= 1'b1;
        repeat (3) @(posedge clk);
        axi_write(6'h00, 32'h0000_0001);

        // The non-preamble prefix keeps the confirmed packet timestamp away
        // from count zero, leaving a complete +/-16-sample ToA search window.
        drive_css_symbol(37);
        drive_css_symbol(0); drive_css_symbol(0); drive_css_symbol(0);
        drive_css_symbol(0); drive_css_symbol(0); drive_css_symbol(0);
        drive_css_symbol(0); drive_css_symbol(0);
        drive_css_symbol(8); drive_css_symbol(16);
        // The packet timestamp is the joint (up + down) / 2 time, so the
        // down leg needs its real SFD and the samples after it.
        drive_css_downchirp(1024); drive_css_downchirp(1024); drive_css_downchirp(256);
        drive_css_symbol(0); drive_css_symbol(0); drive_css_symbol(0);
        drive_css_symbol(0);
        @(negedge clk);
        valid_in <= 1'b0;
        iq_in_re <= 16'sd0;
        iq_in_im <= 16'sd0;

        while (metadata_seen == 0 && timeout_cycles < 400000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        repeat (5) @(posedge clk);

        // One packet: one packet start, the up leg's triplet (peak_triplet_valid
        // is the up leg only), both legs interpolated, and one timestamp --
        // the joint (up + down) / 2 time, which with no carrier offset is the
        // first preamble upchirp exactly (checked at 1024 above).
        if (symbol_seen < 11 || packet_start_seen != 1 ||
            correlation_seen != 66 || triplet_seen != 1 ||
            toa_seen != 2 || metadata_seen != 1) begin
            errors = errors + 1;
            $display("FAIL event counts symbols=%0d packet=%0d corr=%0d triplet=%0d toa=%0d metadata=%0d",
                     symbol_seen, packet_start_seen, correlation_seen,
                     triplet_seen, toa_seen, metadata_seen);
        end
        // 11 symbols of detection stimulus, 2.25 of SFD, 4 of header.
        if (history_next_sample_count !== 64'd17664 ||
            history_samples_retained !== 32'd17664 ||
            history_oldest_sample_count !== 64'd0) begin
            errors = errors + 1;
            $display("FAIL history accounting next=%0d retained=%0d oldest=%0d",
                     history_next_sample_count, history_samples_retained,
                     history_oldest_sample_count);
        end
        // The last search launched is the down leg's.
        if (toa_search_first_count !== 64'd11248) begin
            errors = errors + 1;
            $display("FAIL integrated search first count=%0d", toa_search_first_count);
        end

        axi_read(6'h08, read_value);
        if (read_value !== 32'd1) errors = errors + 1;
        axi_read(6'h0c, read_value);
        if (read_value !== captured_metadata_coarse[31:0]) errors = errors + 1;
        axi_read(6'h10, read_value);
        if (read_value !== captured_metadata_coarse[63:32]) errors = errors + 1;
        axi_read(6'h14, read_value);
        if (read_value !== captured_metadata_fractional) errors = errors + 1;

        if (errors == 0)
            $display("PASS tb_lora_packet_toa_receiver_top fractional_q12=%0d",
                     captured_metadata_fractional);
        else begin
            $display("FAIL tb_lora_packet_toa_receiver_top errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end

endmodule
