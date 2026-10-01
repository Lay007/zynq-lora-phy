`timescale 1ns/1ps
module tb_lora_preamble_timestamp_presence;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0, valid=0;
    reg [31:0] bin=0;
    reg [15:0] peak=0;
    reg [63:0] count=0;
    wire pre_valid;
    wire [63:0] pre_count;
    integer seen=0;
    lora_detector_timestamp_path #(.QUALIFY_PREAMBLE_TIMESTAMP(1)) dut (
        .clk(clk),.resetn(resetn),.clk_enable(1'b1),.reset_in(1'b0),
        .symbol_index(bin),.symbol_valid(valid),.symbol_sample_count(count),
        .timestamp_valid(valid),.symbol_peak(peak),.sync_word(8'h12),
        .preamble_start_valid(pre_valid),.preamble_start_count(pre_count));
    always @(posedge clk) begin
        #1;
        if(pre_valid) begin
            seen=seen+1;
            if(pre_count!==2048) $fatal(1,"silent windows seeded prefetch: %0d",pre_count);
        end
    end
    initial begin
        repeat(3) @(negedge clk); resetn=1;
        // Two quiet zero-bin decisions followed by eight actual upchirps.
        for(integer k=0;k<10;k=k+1) begin
            @(negedge clk); count=k*1024; peak=k<2 ? 0 : 100; valid=1;
            @(negedge clk); valid=0;
        end
        repeat(3) @(negedge clk);
        if(seen!=1) $fatal(1,"qualified preamble count=%0d",seen);
        $display("PASS tb_lora_preamble_timestamp_presence"); $finish;
    end
endmodule
