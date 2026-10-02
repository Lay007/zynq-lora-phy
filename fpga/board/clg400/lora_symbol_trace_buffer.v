`timescale 1ns/1ps

// Freeze a bounded post-acquisition symbol trace for software inspection.
//
// The detector pulse is aligned with the second sync-word symbol. Capture
// starts with the following valid symbol, so entries 0 and 1 are the two full
// SFD downchirp decisions and entry 2 is the first explicit-header symbol for
// SF7. The buffer deliberately keeps accepting decisions after the RF packet
// ends: a fixed-size trace has a simple completion contract and software uses
// the decoded header/CRC to distinguish packet data from trailing noise.
//
// trace_memory is a simple dual-port, dual-clock RAM. Software may read it only
// after capture_complete is set; at that point the sample-domain writer is
// stopped and every data bit is stable. The two-stage synchronizers therefore
// carry only status/control, never a live multiword event.
module lora_symbol_trace_buffer #(
    parameter integer TRACE_DEPTH = 128,
    parameter integer TRACE_ADDR_WIDTH = 7
) (
    input  wire                    sample_clk,
    input  wire                    sample_resetn,
    input  wire                    stream_reset,
    // Zero retains the historical 128-entry contract. A nonzero limit is
    // latched at detection; later software page/index writes cannot change it.
    input  wire [7:0]              capture_limit,
    input  wire                    packet_detected,
    input  wire [15:0]             preamble_bin,
    input  wire [31:0]             symbol_index,
    input  wire                    symbol_valid,
    input  wire [15:0]             confidence,
    input  wire [63:0]             symbol_sample_count,
    input  wire                    symbol_timestamp_valid,

    input  wire                    ctrl_clk,
    input  wire                    ctrl_resetn,
    input  wire [TRACE_ADDR_WIDTH-1:0] ctrl_read_index,
    output reg  [31:0]             ctrl_symbol_index,
    output reg  [63:0]             ctrl_sample_count,
    output reg  [15:0]             ctrl_confidence,
    output reg  [7:0]              ctrl_flags,
    output wire [15:0]             ctrl_preamble_bin,
    output wire [7:0]              ctrl_captured_count,
    output wire                    ctrl_capture_active,
    output wire                    ctrl_capture_complete,
    output wire [31:0]             ctrl_capture_sequence
);

    localparam [7:0] TRACE_DEPTH_U8 = TRACE_DEPTH;

    reg [127:0] trace_memory [0:TRACE_DEPTH-1];
    reg [TRACE_ADDR_WIDTH-1:0] write_index_sample;
    reg [7:0] captured_count_sample;
    reg [7:0] capture_limit_sample;
    reg capture_active_sample;
    reg capture_complete_sample;
    reg [15:0] preamble_bin_sample;
    reg [31:0] capture_sequence_sample;

    always @(posedge sample_clk) begin
        if (!sample_resetn) begin
            write_index_sample       <= {TRACE_ADDR_WIDTH{1'b0}};
            captured_count_sample    <= 8'd0;
            capture_limit_sample     <= TRACE_DEPTH_U8;
            capture_active_sample    <= 1'b0;
            capture_complete_sample  <= 1'b0;
            preamble_bin_sample      <= 16'd0;
            capture_sequence_sample  <= 32'd0;
        end else if (stream_reset) begin
            write_index_sample       <= {TRACE_ADDR_WIDTH{1'b0}};
            captured_count_sample    <= 8'd0;
            capture_limit_sample     <= TRACE_DEPTH_U8;
            capture_active_sample    <= 1'b0;
            capture_complete_sample  <= 1'b0;
            preamble_bin_sample      <= 16'd0;
        end else begin
            if (packet_detected && !capture_active_sample &&
                !capture_complete_sample) begin
                capture_active_sample <= 1'b1;
                capture_limit_sample <= (capture_limit == 0 || capture_limit > TRACE_DEPTH_U8)
                    ? TRACE_DEPTH_U8 : capture_limit;
                preamble_bin_sample   <= preamble_bin;
            end

            if (capture_active_sample && symbol_valid) begin
                trace_memory[write_index_sample] <= {
                    8'd0,
                    6'd0,
                    symbol_timestamp_valid,
                    packet_detected,
                    confidence,
                    symbol_sample_count,
                    symbol_index
                };
                captured_count_sample <= captured_count_sample + 8'd1;

                if (captured_count_sample == capture_limit_sample - 8'd1) begin
                    capture_active_sample   <= 1'b0;
                    capture_complete_sample <= 1'b1;
                    capture_sequence_sample <= capture_sequence_sample + 32'd1;
                end else begin
                    write_index_sample <= write_index_sample + 1'b1;
                end
            end
        end
    end

    // Frozen RAM read port. Registering the selected entry in the control
    // domain makes index changes and all four software-visible words atomic at
    // a ctrl_clk edge.
    reg [127:0] trace_read_ctrl;
    always @(posedge ctrl_clk) begin
        if (!ctrl_resetn) begin
            trace_read_ctrl      <= 128'd0;
            ctrl_symbol_index    <= 32'd0;
            ctrl_sample_count    <= 64'd0;
            ctrl_confidence      <= 16'd0;
            ctrl_flags           <= 8'd0;
        end else begin
            trace_read_ctrl   <= trace_memory[ctrl_read_index];
            ctrl_symbol_index <= trace_read_ctrl[31:0];
            ctrl_sample_count <= trace_read_ctrl[95:32];
            ctrl_confidence   <= trace_read_ctrl[111:96];
            ctrl_flags        <= trace_read_ctrl[119:112];
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [15:0] preamble_bin_meta;
    (* ASYNC_REG = "TRUE" *) reg [15:0] preamble_bin_sync;
    (* ASYNC_REG = "TRUE" *) reg [7:0] captured_count_meta;
    (* ASYNC_REG = "TRUE" *) reg [7:0] captured_count_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] capture_state_meta;
    (* ASYNC_REG = "TRUE" *) reg [1:0] capture_state_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] capture_sequence_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] capture_sequence_sync;

    always @(posedge ctrl_clk) begin
        if (!ctrl_resetn) begin
            preamble_bin_meta    <= 16'd0;
            preamble_bin_sync    <= 16'd0;
            captured_count_meta  <= 8'd0;
            captured_count_sync  <= 8'd0;
            capture_state_meta   <= 2'd0;
            capture_state_sync   <= 2'd0;
            capture_sequence_meta<= 32'd0;
            capture_sequence_sync<= 32'd0;
        end else begin
            preamble_bin_meta     <= preamble_bin_sample;
            preamble_bin_sync     <= preamble_bin_meta;
            captured_count_meta   <= captured_count_sample;
            captured_count_sync   <= captured_count_meta;
            capture_state_meta    <= {
                capture_complete_sample,
                capture_active_sample
            };
            capture_state_sync    <= capture_state_meta;
            capture_sequence_meta <= capture_sequence_sample;
            capture_sequence_sync <= capture_sequence_meta;
        end
    end

    assign ctrl_preamble_bin     = preamble_bin_sync;
    assign ctrl_captured_count   = captured_count_sync;
    assign ctrl_capture_active   = capture_state_sync[0];
    assign ctrl_capture_complete = capture_state_sync[1];
    assign ctrl_capture_sequence = capture_sequence_sync;

endmodule
