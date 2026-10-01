// The receive stream must survive the move to a fixed receiver clock.
//
// Every sample the AD9361 domain writes has to appear exactly once, in order,
// on the receiver clock. A dropped or duplicated sample shifts every sample
// count after it, which is precisely the quantity the whole timestamp path is
// built on, so this checks the payload sequence rather than just a flag.
//
// The board case is a slow writer and a fast reader. The reverse is also
// driven, because that is the case a plain toggle handshake would lose
// silently, and the point of the FIFO is that it reports it instead.

`timescale 1ns/1ps

module tb_lora_async_sample_fifo;
    localparam integer WIDTH = 32;

    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    reg wr_resetn = 1'b0;
    reg rd_resetn = 1'b0;
    reg wr_valid = 1'b0;
    reg [WIDTH-1:0] wr_data = {WIDTH{1'b0}};
    wire wr_overflow;
    wire rd_valid;
    wire [WIDTH-1:0] rd_data;
    wire [15:0] rd_drop_count;
    integer phase2_reads = 0;
    reg counting2 = 1'b0;

    integer errors = 0;
    integer written = 0;
    integer read_back = 0;
    reg [WIDTH-1:0] expect_next = 32'd1;
    reg checking = 1'b0;

    lora_async_sample_fifo #(
        .WIDTH(WIDTH),
        .ADDR_WIDTH(4)
    ) dut (
        .wr_clk(wr_clk),
        .wr_resetn(wr_resetn),
        .wr_valid(wr_valid),
        .wr_data(wr_data),
        .wr_overflow(wr_overflow),
        .rd_clk(rd_clk),
        .rd_resetn(rd_resetn),
        .rd_valid(rd_valid),
        .rd_data(rd_data),
        .rd_drop_count(rd_drop_count)
    );

    // The board ratio: one sample clock per 62.5 receiver clocks. Deliberately
    // not an integer multiple, so the crossing is never accidentally
    // synchronous. The write half-period is a variable so the second phase can
    // invert the ratio without a second testbench.
    real wr_half = 500.0;
    localparam real RD_HALF = 8.0;

    always #(wr_half) wr_clk = ~wr_clk;
    always #(RD_HALF) rd_clk = ~rd_clk;

    always @(posedge rd_clk)
        if (rd_resetn && rd_valid && counting2)
            phase2_reads = phase2_reads + 1;

    always @(posedge rd_clk) begin
        if (rd_resetn && rd_valid && checking) begin
            read_back = read_back + 1;
            if (rd_data !== expect_next) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("FAIL out of order: got %0d expected %0d",
                             rd_data, expect_next);
            end
            expect_next = rd_data + 32'd1;
        end
    end

    task automatic write_one(input [WIDTH-1:0] value);
        begin
            @(negedge wr_clk);
            wr_data  <= value;
            wr_valid <= 1'b1;
            @(negedge wr_clk);
            wr_valid <= 1'b0;
        end
    endtask

    integer i;
    initial begin
        // The board releases these two independently: the write side as
        // soon as the AD9361 clock is up, the read side only once the MMCM
        // has locked. Samples arriving in that window used to fill the FIFO
        // and latch wr_overflow on every boot, which made the flag useless.
        repeat (4) @(posedge wr_clk);
        wr_resetn <= 1'b1;
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge wr_clk);
            wr_data  <= 32'hdead_0000 + i;
            wr_valid <= 1'b1;
            @(negedge wr_clk);
            wr_valid <= 1'b0;
        end
        if (wr_overflow !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL overflow latched while the read side was in reset");
        end else begin
            $display("PASS no overflow while the read side is held in reset");
        end

        rd_resetn <= 1'b1;
        repeat (8) @(posedge wr_clk);
        checking <= 1'b1;

        // Slow writer, fast reader: the board case.
        for (i = 1; i <= 200; i = i + 1) begin
            write_one(i[WIDTH-1:0]);
            written = written + 1;
        end
        repeat (40) @(posedge rd_clk);

        if (read_back != written) begin
            errors = errors + 1;
            $display("FAIL slow writer: wrote %0d read %0d", written, read_back);
        end
        if (wr_overflow !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL slow writer reported overflow");
        end
        if (rd_drop_count !== 16'd0) begin
            errors = errors + 1;
            $display("FAIL slow writer: drop count %0d, expected 0", rd_drop_count);
        end
        if (errors == 0)
            $display("PASS slow writer: %0d samples crossed in order", read_back);

        // Now outrun the reader. The FIFO must say so rather than lose
        // samples without a trace; once full, the checker is retired because
        // the sequence is legitimately broken.
        checking <= 1'b0;
        counting2 <= 1'b1;
        wr_half = 3.0;
        @(negedge wr_clk);
        wr_valid <= 1'b1;
        for (i = 0; i < 64; i = i + 1) begin
            wr_data <= 32'h8000_0000 + i;
            @(negedge wr_clk);
        end
        wr_valid <= 1'b0;
        repeat (20) @(posedge wr_clk);

        if (wr_overflow !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL writer outran reader without reporting overflow");
        end else begin
            $display("PASS overflow reported when the writer outruns the reader");
        end
        // Every sample written in the burst either crossed or was counted
        // as dropped: the count is exact, not merely non-zero.
        repeat (20) @(posedge rd_clk);
        if (rd_drop_count == 16'd0 || rd_drop_count != 64 - phase2_reads) begin
            errors = errors + 1;
            $display("FAIL drop count %0d, expected %0d (64 written, %0d read)",
                     rd_drop_count, 64 - phase2_reads, phase2_reads);
        end else begin
            $display("PASS drop count %0d = 64 written - %0d crossed", rd_drop_count, phase2_reads);
        end

        if (errors == 0)
            $display("PASS async sample FIFO");
        else
            $display("FAIL async sample FIFO errors=%0d", errors);
        if (errors != 0) $fatal(1, "async sample FIFO regression failed");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL timeout");
        $fatal(1, "timeout");
    end
endmodule
