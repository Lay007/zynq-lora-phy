`timescale 1ns/1ps

module tb_lora_detector_timestamp_align;
    reg clk = 1'b0;
    reg resetn = 1'b0;

    reg  [63:0] symbol_sample_count = 64'd0;
    reg         symbol_timestamp_valid = 1'b0;
    reg         preamble_detected = 1'b0;
    reg         packet_detected = 1'b0;

    wire [63:0] preamble_start_count;
    wire        preamble_start_valid;
    wire [63:0] packet_start_count;
    wire        packet_start_valid;
    wire        alignment_error;

    integer errors = 0;

    always #5 clk = ~clk;

    lora_detector_timestamp_align dut (
        .clk(clk),
        .resetn(resetn),
        .symbol_sample_count(symbol_sample_count),
        .symbol_timestamp_valid(symbol_timestamp_valid),
        .preamble_detected(preamble_detected),
        .packet_detected(packet_detected),
        .packet_start_from_current(1'b0),
        .preamble_start_count(preamble_start_count),
        .preamble_start_valid(preamble_start_valid),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .alignment_error(alignment_error)
    );

    task automatic expect64(
        input [63:0] got,
        input [63:0] expected,
        input [8*60-1:0] label
    );
        begin
            if (got !== expected) begin
                $display("FAIL %-60s got=0x%016x expected=0x%016x", label, got, expected);
                errors = errors + 1;
            end else begin
                $display("PASS %-60s value=0x%016x", label, got);
            end
        end
    endtask

    task automatic expect1(
        input got,
        input expected,
        input [8*60-1:0] label
    );
        begin
            if (got !== expected) begin
                $display("FAIL %-60s got=%0d expected=%0d", label, got, expected);
                errors = errors + 1;
            end else begin
                $display("PASS %-60s value=%0d", label, got);
            end
        end
    endtask

    task automatic push_symbol(
        input [63:0] timestamp,
        input preamble_event,
        input packet_event
    );
        begin
            @(negedge clk);
            symbol_sample_count = timestamp;
            symbol_timestamp_valid = 1'b1;
            preamble_detected = preamble_event;
            packet_detected = packet_event;
            @(negedge clk);
            symbol_timestamp_valid = 1'b0;
            preamble_detected = 1'b0;
            packet_detected = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        resetn = 1'b1;
        repeat (2) @(negedge clk);

        expect1(preamble_start_valid, 1'b0, "preamble valid reset");
        expect1(packet_start_valid, 1'b0, "packet valid reset");
        expect1(alignment_error, 1'b0, "alignment error reset");

        // Seven prior timestamps plus the current symbol make the first legal
        // newest-8 preamble window. Gaps without timestampValid must not shift
        // history.
        push_symbol(64'd100, 1'b0, 1'b0);
        push_symbol(64'd200, 1'b0, 1'b0);
        @(negedge clk);
        repeat (3) @(negedge clk);
        push_symbol(64'd300, 1'b0, 1'b0);
        push_symbol(64'd400, 1'b0, 1'b0);
        push_symbol(64'd500, 1'b0, 1'b0);
        push_symbol(64'd600, 1'b0, 1'b0);
        push_symbol(64'd700, 1'b0, 1'b0);
        push_symbol(64'd800, 1'b1, 1'b0);
        expect1(preamble_start_valid, 1'b1, "first 8-symbol preamble candidate valid");
        expect64(preamble_start_count, 64'd100, "first 8-symbol window selects oldest timestamp");

        @(negedge clk);
        expect1(preamble_start_valid, 1'b0, "preamble valid is one-cycle pulse");

        // Sliding one symbol advances the oldest timestamp from 100 to 200.
        push_symbol(64'd900, 1'b1, 1'b0);
        expect1(preamble_start_valid, 1'b1, "sliding preamble candidate valid");
        expect64(preamble_start_count, 64'd200, "sliding 8-symbol window advances timestamp");

        // The tenth symbol completes the 8-preamble + 2-sync detector window.
        // The confirmed packet start must still be the first timestamp of the
        // 10-symbol window: 100.
        push_symbol(64'd1000, 1'b0, 1'b1);
        expect1(packet_start_valid, 1'b1, "10-symbol confirmed packet timestamp valid");
        expect64(packet_start_count, 64'd100, "10-symbol detector selects first window timestamp");

        @(negedge clk);
        expect1(packet_start_valid, 1'b0, "packet valid is one-cycle pulse");

        // A detector pulse without the correlator timestamp sideband is an
        // integration fault and must not emit an aligned timestamp.
        preamble_detected = 1'b1;
        @(negedge clk);
        expect1(alignment_error, 1'b1, "detector without timestamp raises alignment error");
        expect1(preamble_start_valid, 1'b0, "misaligned detector emits no timestamp");
        preamble_detected = 1'b0;
        @(negedge clk);
        expect1(alignment_error, 1'b0, "alignment error is one-cycle pulse");

        // Reset clears history, so an immediate detector event cannot produce a
        // stale timestamp even if timestampValid is asserted.
        resetn = 1'b0;
        repeat (2) @(negedge clk);
        resetn = 1'b1;
        repeat (2) @(negedge clk);
        push_symbol(64'd5000, 1'b1, 1'b1);
        expect1(preamble_start_valid, 1'b0, "reset clears preamble timestamp history");
        expect1(packet_start_valid, 1'b0, "reset clears packet timestamp history");

        if (errors == 0) begin
            $display("PASS tb_lora_detector_timestamp_align");
            $finish;
        end

        $display("FAIL tb_lora_detector_timestamp_align errors=%0d", errors);
        $fatal(1);
    end
endmodule
