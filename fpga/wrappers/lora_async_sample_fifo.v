`timescale 1ns/1ps

// Dual-clock sample crossing for the receive stream.
//
// The receiver used to run on the AD9361 divided data clock, which is the
// sample rate itself: util_clkdiv is configured SEL_0_DIV = 4 and the AD9361
// data clock is four times the sample rate, so the fabric saw exactly one
// clock per sample at every rate the part can be programmed to. That is fine
// for a streaming datapath and hopeless for the joint up/down search, which
// needs tens of thousands of clocks inside one symbol. Clocking the receiver
// from a fixed PL clock fixes that and creates this crossing.
//
// A plain toggle would be enough while the write side is sixty times slower
// than the read side, but it fails silently if the sample rate is ever raised.
// Gray-coded pointers cost a few LUTs more and turn that case into an explicit
// wr_overflow rather than samples that quietly disappear.
module lora_async_sample_fifo #(
    parameter integer WIDTH = 32,
    parameter integer ADDR_WIDTH = 4
) (
    input  wire                   wr_clk,
    input  wire                   wr_resetn,
    input  wire                   wr_valid,
    input  wire [WIDTH-1:0]       wr_data,
    output reg                    wr_overflow,

    input  wire                   rd_clk,
    input  wire                   rd_resetn,
    output reg                    rd_valid,
    output reg  [WIDTH-1:0]       rd_data,
    // Number of samples dropped at a full FIFO since wr_resetn, saturating,
    // seen from the read domain. wr_overflow says "at least once since boot",
    // which on the board was set on every capture of the M7 series and so
    // could not say whether a given packet lost samples; a count read before
    // and after each attempt can.
    output reg  [15:0]            rd_drop_count
);

    localparam integer DEPTH = (1 << ADDR_WIDTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH:0] wr_bin;
    reg [ADDR_WIDTH:0] wr_gray;
    reg [ADDR_WIDTH:0] rd_bin;
    reg [ADDR_WIDTH:0] rd_gray;

    // Only the Gray-coded pointers cross, and only one of their bits can
    // change per step, so a two-flop synchronizer can never latch a value that
    // was never held.
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_gray_sync;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_gray_sync;

    // The two sides leave reset independently. On the board the write side
    // is released as soon as the AD9361 clock is up, while the read side
    // waits for the MMCM to lock, so samples arrive for a long window with
    // nothing draining them. That filled the FIFO and set wr_overflow on
    // every boot, permanently, which made the flag useless as a diagnostic.
    // Nothing is lost by discarding those samples: the receiver they feed is
    // held in reset for the same window.
    (* ASYNC_REG = "TRUE" *) reg rd_resetn_meta;
    (* ASYNC_REG = "TRUE" *) reg rd_resetn_sync;

    function [ADDR_WIDTH:0] bin_to_gray;
        input [ADDR_WIDTH:0] value;
        begin
            bin_to_gray = value ^ (value >> 1);
        end
    endfunction

    // The drop count crosses as Gray code for the same reason the pointers
    // do: it advances by at most one per write clock, so the synchronized
    // value is always one the counter actually held.
    reg [15:0] drop_bin;
    reg [15:0] drop_gray;
    (* ASYNC_REG = "TRUE" *) reg [15:0] drop_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [15:0] drop_gray_sync;
    wire [15:0] drop_bin_next = drop_bin + 16'd1;

    function [15:0] gray16_to_bin;
        input [15:0] g;
        integer k;
        begin
            gray16_to_bin[15] = g[15];
            for (k = 14; k >= 0; k = k - 1)
                gray16_to_bin[k] = gray16_to_bin[k + 1] ^ g[k];
        end
    endfunction

    wire [ADDR_WIDTH:0] wr_bin_next = wr_bin + {{ADDR_WIDTH{1'b0}}, 1'b1};
    wire [ADDR_WIDTH:0] wr_gray_next = bin_to_gray(wr_bin_next);
    wire full = (wr_gray_next == {~rd_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                                   rd_gray_sync[ADDR_WIDTH-2:0]});

    wire [ADDR_WIDTH:0] rd_bin_next = rd_bin + {{ADDR_WIDTH{1'b0}}, 1'b1};
    wire [ADDR_WIDTH:0] rd_gray_next = bin_to_gray(rd_bin_next);
    wire empty = (rd_gray == wr_gray_sync);

    always @(posedge wr_clk) begin
        if (!wr_resetn) begin
            wr_bin       <= {(ADDR_WIDTH+1){1'b0}};
            wr_gray      <= {(ADDR_WIDTH+1){1'b0}};
            wr_overflow  <= 1'b0;
            drop_bin     <= 16'd0;
            drop_gray    <= 16'd0;
            rd_gray_meta <= {(ADDR_WIDTH+1){1'b0}};
            rd_gray_sync <= {(ADDR_WIDTH+1){1'b0}};
            rd_resetn_meta <= 1'b0;
            rd_resetn_sync <= 1'b0;
        end else begin
            rd_gray_meta <= rd_gray;
            rd_gray_sync <= rd_gray_meta;
            rd_resetn_meta <= rd_resetn;
            rd_resetn_sync <= rd_resetn_meta;
            if (wr_valid && rd_resetn_sync) begin
                if (full) begin
                    // Sticky: one dropped sample invalidates every sample
                    // count downstream, so the fact has to survive to a
                    // register read rather than being a one-cycle pulse.
                    wr_overflow <= 1'b1;
                    if (!(&drop_bin)) begin
                        drop_bin  <= drop_bin_next;
                        drop_gray <= drop_bin_next ^ (drop_bin_next >> 1);
                    end
                end else begin
                    mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
                    wr_bin  <= wr_bin_next;
                    wr_gray <= wr_gray_next;
                end
            end
        end
    end

    always @(posedge rd_clk) begin
        if (!rd_resetn) begin
            rd_bin       <= {(ADDR_WIDTH+1){1'b0}};
            rd_gray      <= {(ADDR_WIDTH+1){1'b0}};
            rd_valid     <= 1'b0;
            rd_data      <= {WIDTH{1'b0}};
            wr_gray_meta <= {(ADDR_WIDTH+1){1'b0}};
            wr_gray_sync <= {(ADDR_WIDTH+1){1'b0}};
            drop_gray_meta <= 16'd0;
            drop_gray_sync <= 16'd0;
            rd_drop_count  <= 16'd0;
        end else begin
            wr_gray_meta <= wr_gray;
            wr_gray_sync <= wr_gray_meta;
            drop_gray_meta <= drop_gray;
            drop_gray_sync <= drop_gray_meta;
            rd_drop_count  <= gray16_to_bin(drop_gray_sync);
            rd_valid <= 1'b0;
            if (!empty) begin
                rd_data  <= mem[rd_bin[ADDR_WIDTH-1:0]];
                rd_valid <= 1'b1;
                rd_bin   <= rd_bin_next;
                rd_gray  <= rd_gray_next;
            end
        end
    end

endmodule
