`timescale 1ns/1ps

// Align the FFT-correlator symbol timestamp sideband with the sliding blind
// detector window.
//
// The generated correlator presents symbolSampleCount/timestampValid in the
// same cycle as symbolIndex/symbolValid. The blind detector evaluates:
//   * preambleDetected on the newest 8 valid symbols;
//   * detected on the newest 10 valid symbols (8 preamble + 2 sync).
//
// Therefore a detector decision must not latch the live sample counter. The
// packet-reference timestamp is already in the symbol timestamp history:
//   * preambleDetected -> oldest timestamp in the newest-8 window;
//   * detected         -> oldest timestamp in the newest-10 window.
// These counts are FFT window origins, not phase-corrected chirp onsets. The
// ToA consumer must resolve the circular preamble phase relative to the chosen
// decision window; a forward grid-resync skip has a different meaning.
//
// This module is deliberately transparent: every detector pulse produces a
// corresponding aligned timestamp pulse. Higher-level acquisition logic may
// decide which preamble candidate to retain/reject. No packet state machine is
// hidden here.
module lora_detector_timestamp_align #(
    parameter integer SYMBOL_SAMPLES = 1024
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire [63:0] symbol_sample_count,
    input  wire        symbol_timestamp_valid,
    input  wire        preamble_detected,
    input  wire        packet_detected,
    // With packet_detected: the packet start is the current window's count
    // minus nine symbols (the same position as history[1] on an unbroken
    // grid), for a detection whose grid was shifted inside the last nine
    // windows (lora_preamble_accumulator, #36). Tie low otherwise.
    input  wire        packet_start_from_current,

    output reg  [63:0] preamble_start_count,
    output reg         preamble_start_valid,
    output reg  [63:0] packet_start_count,
    output reg         packet_start_valid,
    output reg         alignment_error
);

    // history[9] is the newest previously accepted symbol timestamp;
    // history[0] is the oldest retained timestamp.
    reg [63:0] history [0:9];
    reg [3:0]  filled;
    integer i;

    always @(posedge clk) begin
        if (!resetn) begin
            for (i = 0; i < 10; i = i + 1)
                history[i] <= 64'd0;
            filled               <= 4'd0;
            preamble_start_count <= 64'd0;
            preamble_start_valid <= 1'b0;
            packet_start_count   <= 64'd0;
            packet_start_valid   <= 1'b0;
            alignment_error      <= 1'b0;
        end else begin
            preamble_start_valid <= 1'b0;
            packet_start_valid   <= 1'b0;
            alignment_error      <= 1'b0;

            // A detector decision is meaningful only on the matching symbol
            // timestamp cycle. Flag an integration error rather than silently
            // associating it with stale history.
            if ((preamble_detected || packet_detected) && !symbol_timestamp_valid)
                alignment_error <= 1'b1;

            if (symbol_timestamp_valid) begin
                // Before shifting, history[3] is seven symbols older than the
                // current symbol and history[1] is nine symbols older. After
                // inserting the current timestamp, those become respectively
                // the oldest entries of the newest-8 and newest-10 windows.
                if (preamble_detected && (filled >= 4'd7)) begin
                    preamble_start_count <= history[3];
                    preamble_start_valid <= 1'b1;
                end

                if (packet_detected && packet_start_from_current) begin
                    packet_start_count <= symbol_sample_count - SYMBOL_SAMPLES * 9;
                    packet_start_valid <= 1'b1;
                end else if (packet_detected && (filled >= 4'd9)) begin
                    packet_start_count <= history[1];
                    packet_start_valid <= 1'b1;
                end

                for (i = 0; i < 9; i = i + 1)
                    history[i] <= history[i + 1];
                history[9] <= symbol_sample_count;

                if (filled < 4'd10)
                    filled <= filled + 4'd1;
            end
        end
    end

endmodule
