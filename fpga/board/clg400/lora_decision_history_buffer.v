`timescale 1ns/1ps

// Free-running ring of the detector's last symbol decisions, frozen on demand.
//
// Why it exists: on the M7 guard image five of 798 packets were never
// detected on the board, and every one of those recordings is detected at
// every arrival phase when it is replayed through the same RTL. The symbol
// trace starts only after a detection, so a miss leaves nothing behind but
// "the detector never fired". This ring keeps every decision whether or not a
// packet was detected, so the decisions the board actually took over a missed
// packet can be put next to the ones the replay takes at the same grid phase.
// Each entry also carries the low byte of the receive crossing's drop counter,
// which says whether samples were lost between two decisions.
//
// The writer runs continuously and stops while `freeze` is held; software
// holds it, reads the entries, then releases it. The newest entry and the
// number of decisions written are reported so software can walk back from
// the newest entry. As with the symbol trace, memory is read only while the
// writer is stopped (ctrl_frozen), so only status crosses through
// synchronizers, never a live multiword entry.
module lora_decision_history_buffer #(
    parameter integer ADDR_WIDTH = 12
) (
    input  wire                    sample_clk,
    input  wire                    sample_resetn,
    input  wire                    freeze,
    input  wire                    symbol_valid,
    input  wire [31:0]             symbol_index,
    input  wire [15:0]             confidence,
    input  wire [63:0]             symbol_sample_count,
    input  wire                    packet_detected,
    input  wire                    straddle_detected,
    input  wire                    grid_resync_armed,
    input  wire [15:0]             drop_count,

    input  wire                    ctrl_clk,
    input  wire                    ctrl_resetn,
    input  wire [ADDR_WIDTH-1:0]   ctrl_read_index,
    output reg  [31:0]             ctrl_sample_count,
    output reg  [7:0]              ctrl_bin,
    output reg  [15:0]             ctrl_confidence,
    output reg  [7:0]              ctrl_drop_low,
    output reg  [7:0]              ctrl_flags,
    output wire [ADDR_WIDTH-1:0]   ctrl_newest_index,
    output wire [31:0]             ctrl_written_count,
    output wire                    ctrl_frozen
);

    localparam integer DEPTH = (1 << ADDR_WIDTH);

    reg [71:0] ring [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] write_index_sample;
    reg [ADDR_WIDTH-1:0] newest_index_sample;
    reg [31:0] written_count_sample;
    reg frozen_sample;
    // A detection is a one-cycle pulse that need not coincide with
    // symbol_valid; hold it until the next decision is written so the entry
    // it belongs to carries it.
    reg detected_pending;
    reg straddle_pending;

    always @(posedge sample_clk) begin
        if (!sample_resetn) begin
            write_index_sample   <= {ADDR_WIDTH{1'b0}};
            newest_index_sample  <= {ADDR_WIDTH{1'b0}};
            written_count_sample <= 32'd0;
            frozen_sample        <= 1'b0;
            detected_pending     <= 1'b0;
            straddle_pending     <= 1'b0;
        end else begin
            frozen_sample <= freeze;
            if (packet_detected)
                detected_pending <= 1'b1;
            if (straddle_detected)
                straddle_pending <= 1'b1;
            if (!freeze && !frozen_sample && symbol_valid) begin
                ring[write_index_sample] <= {
                    // flags
                    4'd0,
                    grid_resync_armed,
                    straddle_pending || straddle_detected,
                    detected_pending || packet_detected,
                    1'b1,                 // entry holds a decision
                    drop_count[7:0],
                    confidence,
                    symbol_index[7:0],
                    symbol_sample_count[31:0]
                };
                newest_index_sample  <= write_index_sample;
                write_index_sample   <= write_index_sample + 1'b1;
                written_count_sample <= written_count_sample + 32'd1;
                detected_pending     <= 1'b0;
                straddle_pending     <= 1'b0;
            end
        end
    end

    reg [71:0] read_ctrl;
    always @(posedge ctrl_clk) begin
        if (!ctrl_resetn) begin
            read_ctrl         <= 72'd0;
            ctrl_sample_count <= 32'd0;
            ctrl_bin          <= 8'd0;
            ctrl_confidence   <= 16'd0;
            ctrl_drop_low     <= 8'd0;
            ctrl_flags        <= 8'd0;
        end else begin
            read_ctrl         <= ring[ctrl_read_index];
            ctrl_sample_count <= read_ctrl[31:0];
            ctrl_bin          <= read_ctrl[39:32];
            ctrl_confidence   <= read_ctrl[55:40];
            ctrl_drop_low     <= read_ctrl[63:56];
            ctrl_flags        <= read_ctrl[71:64];
        end
    end

    (* ASYNC_REG = "TRUE" *) reg frozen_meta;
    (* ASYNC_REG = "TRUE" *) reg frozen_sync;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH-1:0] newest_meta;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH-1:0] newest_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] written_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] written_sync;

    always @(posedge ctrl_clk) begin
        if (!ctrl_resetn) begin
            frozen_meta  <= 1'b0;
            frozen_sync  <= 1'b0;
            newest_meta  <= {ADDR_WIDTH{1'b0}};
            newest_sync  <= {ADDR_WIDTH{1'b0}};
            written_meta <= 32'd0;
            written_sync <= 32'd0;
        end else begin
            frozen_meta  <= frozen_sample;
            frozen_sync  <= frozen_meta;
            newest_meta  <= newest_index_sample;
            newest_sync  <= newest_meta;
            written_meta <= written_count_sample;
            written_sync <= written_meta;
        end
    end

    assign ctrl_newest_index  = newest_sync;
    assign ctrl_written_count = written_sync;
    // Report frozen only once the writer has stopped (frozen_sample follows
    // freeze by a cycle and gates the write) and the counters above have had
    // time to settle through their synchronizers alongside it.
    assign ctrl_frozen = frozen_sync;

endmodule
