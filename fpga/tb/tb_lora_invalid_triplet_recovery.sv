`timescale 1ns/1ps
// Inject matched-filter responses at its interface. Use the real generated
// interpolator and receiver top to verify a rejected zero triplet does not
// prevent the next packet's timestamp, without a receiver reset.
module tb_lora_invalid_triplet_recovery;
    reg clk=0, resetn=0;
    always #5 clk=~clk;
    wire fine, applied, up_abort, metadata_valid;
    integer timestamps=0;
    lora_packet_toa_receiver_top #(.DEFAULT_RECEIVER_ENABLE(1'b1)) dut (
        .clk(clk),.resetn(resetn),.iq_in_re(16'sd0),.iq_in_im(16'sd0),
        .valid_in(1'b0),.reset_in(1'b0),.trace_rearm_in(1'b0),
        .resync_valid(1'b0),.resync_skip(32'd0),.sync_word(8'h12),
        .s_axi_awaddr(6'd0),.s_axi_awvalid(1'b0),.s_axi_wdata(32'd0),
        .s_axi_wstrb(4'd0),.s_axi_wvalid(1'b0),.s_axi_bready(1'b1),
        .s_axi_araddr(6'd0),.s_axi_arvalid(1'b0),.s_axi_rready(1'b1),
        .joint_timing_valid(fine),.joint_precise_correction_applied(applied),
        .joint_up_search_abort_error(up_abort),.metadata_valid(metadata_valid));
    always @(posedge clk) if (metadata_valid) timestamps=timestamps+1;
    task packet(input [63:0] origin);
        begin
            force dut.packet_start_count=origin;
            force dut.packet_start_valid=1'b1;
            @(negedge clk);force dut.packet_start_valid=1'b0;
        end
    endtask
    task triplet(input [63:0] origin, input zero_neighbor);
        begin
            force dut.peak_sample_count=origin;
            if(zero_neighbor) force dut.magnitude_before=32'd0;
            else force dut.magnitude_before=32'd50;
            force dut.magnitude_peak=32'd100;
            force dut.magnitude_after=32'd50;
            force dut.raw_peak_triplet_valid=1'b1;
            @(negedge clk);force dut.raw_peak_triplet_valid=1'b0;
        end
    endtask
    initial begin
        #200000;$fatal(1,"recovery timeout");
    end
    initial begin
        force dut.packet_start_valid=1'b0;
        force dut.history_next_sample_count=64'd1000000;
        force dut.raw_search_busy=1'b0;
        force dut.raw_peak_triplet_valid=1'b0;
        force dut.toa_underflow_error=1'b0;
        force dut.raw_search_restart_error=1'b0;
        force dut.toa_mac_window_mismatch_error=1'b0;
        force dut.toa_mac_read_miss_error=1'b0;
        force dut.toa_mac_response_mismatch_error=1'b0;
        force dut.toa_mac_restart_error=1'b0;
        force dut.raw_peak_boundary_error=1'b0;
        force dut.toa_peak_restart_error=1'b0;
        repeat(5) @(negedge clk);resetn=1;
        repeat(5) @(negedge clk);
        packet(64'd20000);
        wait(dut.joint_search_start);@(negedge clk);
        triplet(64'd20000,1'b1);
        if (!up_abort || dut.joint_grid_busy || applied || fine)
            $fatal(1,"zero triplet must abort without precise timestamp");
        repeat(80) @(negedge clk);
        if(timestamps) $fatal(1,"invalid packet published a timestamp");
        packet(64'd40000);
        wait(dut.joint_search_start);@(negedge clk);
        triplet(64'd40000,1'b0);
        wait(dut.joint_search_start && dut.reference_down);@(negedge clk);
        triplet(64'd50240,1'b0);
        wait(applied);repeat(12) @(negedge clk);
        if(timestamps!=1) $fatal(1,"following valid packet did not publish once");
        $display("PASS zero interpolator input, guard restoration and next packet without reset");
        $finish;
    end
endmodule
