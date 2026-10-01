`timescale 1ns/1ps
module tb_lora_joint_prefetch;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0, stream_reset=0;
    reg packet_valid=0, pre_valid=0, early=0;
    reg [63:0] packet_count=0, pre_count=0, history_count=200000;
    reg [15:0] chips=0, pre_chips=0;
    reg triplet=0, frac_valid=0, failed=0;
    reg [63:0] peak=0;
    reg [31:0] power=100;
    wire start, down, busy, fine, precise, restart;
    wire [63:0] coarse, toa;
    wire [31:0] skip;
    integer searches=0, fine_count=0, restarts=0;
    lora_joint_chirp_grid_controller #(.PREFETCH_UP(1)) dut (
        .clk(clk),.resetn(resetn),.stream_reset(stream_reset),
        .packet_start_valid(packet_valid),.packet_start_count(packet_count),
        .chips_to_boundary(chips),.packet_straddle(1'b0),.packet_early_sync(early),
        .preamble_start_valid(pre_valid),.preamble_start_count(pre_count),
        .preamble_chips_to_boundary(pre_chips),.history_next_sample_count(history_count),
        .search_busy(1'b0),.search_failed(failed),.search_triplet_valid(triplet),
        .search_peak_sample_count(peak),.search_offset_q12(16'sd0),.search_offset_valid(frac_valid),
        .search_peak_power(power),
        .search_start(start),.search_coarse_start(coarse),.reference_down(down),
        .busy(busy),.fine_skip(skip),.fine_resync_valid(fine),
        .precise_correction_applied(precise),.toa_coarse(toa),.restart_error(restart));
    always @(posedge clk) begin
        #1;
        if (start) searches=searches+1;
        if (fine) fine_count=fine_count+1;
        if (restart) restarts=restarts+1;
    end
    task automatic preamble(input [63:0] n,input [15:0] c);
        begin @(negedge clk); pre_count=n; pre_chips=c; pre_valid=1;
            @(negedge clk); pre_valid=0; end
    endtask
    task automatic packet(input [63:0] n,input [15:0] c,input e);
        begin @(negedge clk); packet_count=n; chips=c; early=e; packet_valid=1;
            @(negedge clk); packet_valid=0; end
    endtask
    task automatic wait_search(input is_down,input [63:0] n);
        integer timeout;
        begin
            timeout=0;
            while (!start && timeout<100) begin @(negedge clk); timeout=timeout+1; end
            if (!start || down!==is_down || coarse!==n)
                $fatal(1,"wrong/missing search down=%0d count=%0d expected=%0d",down,coarse,n);
            @(negedge clk);
        end
    endtask
    task automatic respond(input [63:0] n);
        begin @(negedge clk); peak=n; triplet=1;
            @(negedge clk); triplet=0; frac_valid=1;
            @(negedge clk); frac_valid=0; end
    endtask
    task automatic result(input [63:0] n,input [31:0] s);
        integer timeout;
        begin timeout=0;
            while(!fine && timeout<100) begin @(negedge clk); timeout=timeout+1; end
            if (!fine || !precise || toa!==n || skip!==s || restarts)
                $fatal(1,"wrong estimate toa=%0d skip=%0d precise=%0d",toa,skip,precise);
            @(negedge clk); end
    endtask
    initial begin
        repeat(3) @(negedge clk); resetn=1;
        // Confirmation while speculative up is still running; origin shifts
        // by a whole symbol, so reuse the offset, not its absolute timestamp.
        preamble(10000,40); wait_search(0,11344);
        packet(12048,40,0); respond(11348);
        wait_search(1,22608); respond(22620); result(12376,24);
        if(searches!=2) $fatal(1,"up prefetch was not reused");
        // A one-bin phase change is quantization, not a different chirp.
        // Translate the cached offset by -8 samples at the confirmed epoch.
        preamble(10000,40); wait_search(0,11344); respond(11348);
        packet(12048,41,0); wait_search(1,22616);
        respond(22628); result(12380,20);
        if(searches!=4) $fatal(1,"small phase change repeated up");
        // Early sync crosses the half-symbol unwrap due to CFO. Force the
        // earlier origin even though chips*8=496 is below the ordinary tie.
        preamble(6144,62); wait_search(0,7664); respond(7668);
        repeat(3) @(negedge clk); packet(7168,62,1);
        wait_search(1,16880); respond(16908); result(6656,32);
        // A phase change invalidates speculative data and repeats up.
        preamble(10000,40); wait_search(0,11344); respond(11348);
        packet(10000,43,0); wait_search(0,10344); respond(10346);
        wait_search(1,20584); respond(20590); result(10348,20);
        if(searches!=9) $fatal(1,"phase mismatch did not repeat up");
        // A preamble without sync cannot produce metadata or return a guard.
        preamble(30000,0); wait_search(0,31024); respond(31026);
        history_count=220000; repeat(5) @(negedge clk);
        if(busy || fine_count!=4) $fatal(1,"unconfirmed work did not expire silently");
        // A failed speculative read with a confirmed packet retries cleanly.
        history_count=300000;
        preamble(40000,0); wait_search(0,41024); packet(40000,0,0);
        @(negedge clk); failed=1; @(negedge clk); failed=0;
        wait_search(0,40000); respond(40002);
        wait_search(1,50240); respond(50246); result(40004,20);
        if(fine_count!=5 || restarts) $fatal(1,"speculative failure emitted invalid correction");
        // Stream reset invalidates the cached result and confirmation.
        preamble(60000,0); wait_search(0,61024); respond(61024);
        @(negedge clk); stream_reset=1; @(negedge clk); stream_reset=0;
        repeat(3) @(negedge clk);
        if(busy || fine_count!=5) $fatal(1,"reset retained prefetch state");
        // A half-symbol FFT tie names a preamble one symbol early. Its weak
        // SFD is rejected; the following full SFD resolves the absolute epoch.
        preamble(2048,64); wait_search(0,2560); respond(2556);
        packet(2048,64,0); wait_search(1,11776);
        power=1;respond(11764);power=100;
        wait_search(1,12800);respond(12796);result(2556,12);
        if(fine_count!=6) $fatal(1,"ambiguous epoch retry failed");
        // Neither candidate has a credible SFD: return only the guard.
        preamble(2048,64);wait_search(0,2560);respond(2556);
        packet(2048,64,0);wait_search(1,11776);
        power=1;respond(11764);wait_search(1,12800);respond(12796);
        repeat(4) @(negedge clk);power=100;
        if(busy || precise || fine_count!=7 || skip!=16)
            $fatal(1,"two weak SFD candidates did not decline precise ToA");
        $display("PASS tb_lora_joint_prefetch searches=%0d fine=%0d",searches,fine_count); $finish;
    end
    initial begin #100000; $fatal(1,"prefetch test timeout"); end
endmodule
