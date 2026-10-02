`timescale 1ns/1ps
module tb_lora_symbol_trace_limit;
    reg clk=0, ctrl_clk=0;
    always #5 clk=~clk;
    always #7 ctrl_clk=~ctrl_clk;
    reg resetn=0, stream_reset=0, detected=0, valid=0;
    reg [7:0] limit=0;
    reg [31:0] symbol=0;
    reg [63:0] count=0;
    reg [6:0] index=0;
    wire [31:0] read_symbol, capture_sequence;
    wire [7:0] captured;
    wire active, complete;
    lora_symbol_trace_buffer dut (
        .sample_clk(clk), .sample_resetn(resetn), .stream_reset(stream_reset),
        .capture_limit(limit), .packet_detected(detected), .preamble_bin(16'd4095),
        .symbol_index(symbol), .symbol_valid(valid), .confidence(16'd123),
        .symbol_sample_count(count), .symbol_timestamp_valid(valid),
        .ctrl_clk(ctrl_clk), .ctrl_resetn(resetn), .ctrl_read_index(index),
        .ctrl_symbol_index(read_symbol), .ctrl_sample_count(), .ctrl_confidence(),
        .ctrl_flags(), .ctrl_preamble_bin(), .ctrl_captured_count(captured),
        .ctrl_capture_active(active), .ctrl_capture_complete(complete),
        .ctrl_capture_sequence(capture_sequence));
    task automatic rearm(input [7:0] new_limit);
        @(negedge clk); stream_reset=1; valid=0; limit=new_limit;
        repeat(3) @(negedge clk);
        stream_reset=0; detected=1;
        @(negedge clk); detected=0;
    endtask
    integer i;
    initial begin
        repeat(5) @(negedge clk); resetn=1;
        rearm(3);
        // Changing the live limit while reading pages must not extend capture.
        limit=100;
        for(i=0;i<8;i=i+1) begin
            @(negedge clk); valid=1; symbol=3000+i; count=64'h123456789abc0000+i;
        end
        @(negedge clk); valid=0;
        repeat(8) @(negedge ctrl_clk);
        if(!complete || active || captured!=3 || capture_sequence!=1) $fatal(1,"short limit not latched");
        index=2; repeat(4) @(negedge ctrl_clk);
        if(read_symbol!=3002) $fatal(1,"16-bit symbol corrupted");
        rearm(0);
        for(i=0;i<128;i=i+1) begin
            @(negedge clk); valid=1; symbol=i; count=i;
        end
        @(negedge clk); valid=0;
        repeat(8) @(negedge ctrl_clk);
        if(!complete || captured!=128 || capture_sequence!=2) $fatal(1,"legacy default changed");
        index=127; repeat(4) @(negedge ctrl_clk);
        if(read_symbol!=127) $fatal(1,"last legacy symbol lost");
        $display("PASS variable trace limit, stable snapshot, wide symbols, legacy 128");
        $finish;
    end
endmodule
