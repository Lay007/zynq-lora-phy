// Boundary-register wrapper for physical implementation measurements.
//
// Since #32 the generated correlator is built with WordLength 20 (it was 16):
// every fixed-point boundary keeps its integer bits and gains four fraction
// bits. The 16-bit sample port stays as it was: a raw ADC sample is sfix16_En10
// and enters the core as sfix20_En14 by appending four zero bits, the same
// value. The three metrics leave through their old 16-bit ports at their old
// scale (the top 16 of 20 bits), except that a peak the 16-bit core would have
// truncated to zero reads 1: zero still means exactly zero, i.e. silence.
// With 16 bits the core worked from about 20 to 5000 LSB of input and lost
// weak board packets at its floor (194 of 295 at 0 dB RX gain); with 20 the
// floor is below 5 LSB and the ceiling unchanged (RTL replay, 2026-09-27).
//
// The generated DUT is kept untouched. Registering every functional input
// and output closes its external combinational paths so post-route timing is
// measured register-to-register. clk_enable is tied high because the
// correlator consumes one sample on every application clock.
//
// Older committed HDL used the generic module name DUT. New regeneration uses
// a target-specific ModulePrefix so several generated cores can coexist in one
// Vivado design. The implementation flow defines LORA_FFT_GENERATED_DUT to the
// prefixed name; the fallback keeps historical generated snapshots measurable.

`timescale 1 ns / 1 ns

`ifndef LORA_FFT_GENERATED_DUT
`ifdef LORA_NAMESPACED_GENERATED
`define LORA_FFT_GENERATED_DUT lora_fft_DUT
`else
`define LORA_FFT_GENERATED_DUT DUT
`endif
`endif

module fft_correlator_route_top
          (clk,
           reset,
           iqIn_re,
           iqIn_im,
           validIn,
           resetIn,
           resyncValid,
           resyncSkip,
           ce_out,
           symbolIndex,
           symbolValid,
           confidence,
           peakMagnitudeSquared,
           spectrumSum,
           symbolBoundary,
           symbolSampleCount,
           timestampValid);

  input clk;
  input reset;
  input signed [15:0] iqIn_re;
  input signed [15:0] iqIn_im;
  input validIn;
  input resetIn;
  input resyncValid;
  input [31:0] resyncSkip;
  output reg ce_out;
  output reg [31:0] symbolIndex;
  output reg symbolValid;
  output reg [15:0] confidence;
  output reg [15:0] peakMagnitudeSquared;
  output reg [15:0] spectrumSum;
  output reg symbolBoundary;
  output reg [63:0] symbolSampleCount;
  output reg timestampValid;

  reg signed [19:0] iqIn_re_reg;
  reg signed [19:0] iqIn_im_reg;
  reg validIn_reg;
  reg resetIn_reg;
  reg resyncValid_reg;
  reg [31:0] resyncSkip_reg;

  wire dut_ce_out;
  wire [31:0] dut_symbolIndex;
  wire dut_symbolValid;
  wire [19:0] dut_confidence;
  wire [19:0] dut_peakMagnitudeSquared;
  wire [19:0] dut_spectrumSum;
  wire dut_symbolBoundary;
  wire [63:0] dut_symbolSampleCount;
  wire dut_timestampValid;

  `LORA_FFT_GENERATED_DUT u_dut
        (.clk(clk),
         .reset(reset),
         .clk_enable(1'b1),
         .iqIn_re(iqIn_re_reg),
         .iqIn_im(iqIn_im_reg),
         .validIn(validIn_reg),
         .resetIn(resetIn_reg),
         .resyncValid(resyncValid_reg),
         .resyncSkip(resyncSkip_reg),
         .ce_out(dut_ce_out),
         .symbolIndex(dut_symbolIndex),
         .symbolValid(dut_symbolValid),
`ifdef LORA_NAMESPACED_GENERATED
         .confidence(dut_confidence),
`else
         .confidence_1(dut_confidence),
`endif
         .peakMagnitudeSquared(dut_peakMagnitudeSquared),
         .spectrumSum(dut_spectrumSum),
         .symbolBoundary(dut_symbolBoundary),
         .symbolSampleCount(dut_symbolSampleCount),
         .timestampValid(dut_timestampValid));

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      iqIn_re_reg <= 20'sd0;
      iqIn_im_reg <= 20'sd0;
      validIn_reg <= 1'b0;
      resetIn_reg <= 1'b0;
      resyncValid_reg <= 1'b0;
      resyncSkip_reg <= 32'd0;
      ce_out <= 1'b0;
      symbolIndex <= 32'd0;
      symbolValid <= 1'b0;
      confidence <= 16'd0;
      peakMagnitudeSquared <= 16'd0;
      spectrumSum <= 16'd0;
      symbolBoundary <= 1'b0;
      symbolSampleCount <= 64'd0;
      timestampValid <= 1'b0;
    end
    else begin
      iqIn_re_reg <= {iqIn_re, 4'b0000};
      iqIn_im_reg <= {iqIn_im, 4'b0000};
      validIn_reg <= validIn;
      resetIn_reg <= resetIn;
      resyncValid_reg <= resyncValid;
      resyncSkip_reg <= resyncSkip;
      ce_out <= dut_ce_out;
      symbolIndex <= dut_symbolIndex;
      symbolValid <= dut_symbolValid;
      confidence <= dut_confidence[19:4];
      peakMagnitudeSquared <= (dut_peakMagnitudeSquared[19:4] != 16'd0) ? dut_peakMagnitudeSquared[19:4] :
                              ((dut_peakMagnitudeSquared != 20'd0) ? 16'd1 : 16'd0);
      spectrumSum <= dut_spectrumSum[19:4];
      symbolBoundary <= dut_symbolBoundary;
      symbolSampleCount <= dut_symbolSampleCount;
      timestampValid <= dut_timestampValid;
    end
  end
endmodule
