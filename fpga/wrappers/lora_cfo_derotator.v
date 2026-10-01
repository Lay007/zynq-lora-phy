`timescale 1ns/1ps

// Remove the packet's carrier offset from the samples the correlator decides on.
//
// Why: the joint up/down estimate removes the timing from the symbol grid but
// not the carrier offset, which stays in every decision. On the board the
// transmitter's offset is about -3.4 samples of matched-filter displacement,
// 0.43 of a chip, and a grid residual of about -0.5 sample pushes the peak onto
// the half-chip edge between two decision lags; 25 of 25 CRC failures of the
// 2026-09-24 series were exactly that. The reference model, with the IQ rotated
// by the joint estimate's own CFO before the decision, decodes all 25 on the
// grid the board used, keeps all 50 controls, and widens the window of grid
// offsets that decode from 1-3 to 7-8 samples.
//
// The joint pair measures the CFO as a matched-filter displacement d in
// samples (cfo_q12, Q12). A tone of f cycles/sample moves an upchirp's peak by
// -8192*f samples at SF7 x 8 samples/chip, so the offset is -d/8192 cycles per
// sample and y = x * exp(+j*2*pi*(d/8192)*n) removes it: the phase advances by
// d/8192 of a turn per sample, cfo_q12 * 2^7 in a 32-bit turn accumulator.
//
// The rotation is a pipelined CORDIC (one sample per clock at any valid
// pattern, no multipliers in the loop, no table). Everything that has to stay
// in order with the samples -- valid and the grid-resync request -- goes
// through the same LATENCY-clock delay, so the correlator sees exactly the
// sequence it saw before, LATENCY clocks later. The stream reset is not delayed
// (the correlator takes it directly); it flushes this pipeline instead. While rotation is
// off the output is the input sample itself, bit for bit, so behaviour with no
// estimate is unchanged.
module lora_cfo_derotator #(
    parameter integer ITERATIONS = 16
) (
    input  wire               clk,
    input  wire               resetn,

    input  wire signed [15:0] in_re,
    input  wire signed [15:0] in_im,
    input  wire               in_valid,
    // Carried in step with the samples.
    input  wire               in_resync_valid,
    input  wire [31:0]        in_resync_skip,
    input  wire               in_stream_reset,

    // Rotation control. load: start rotating by cfo_q12 from the next sample;
    // clear: stop (wins over load in the same cycle).
    input  wire               load,
    input  wire signed [31:0] cfo_q12,
    input  wire               clear,

    output wire signed [15:0] out_re,
    output wire signed [15:0] out_im,
    output wire               out_valid,
    output wire               out_resync_valid,
    output wire [31:0]        out_resync_skip,
    output wire               out_stream_reset,
    output wire               rotating
);
    localparam integer LATENCY = ITERATIONS + 3;

    // atan(2^-i) in units of 2^20 per turn (generated, rounded).
    function automatic [19:0] atan_turns(input integer i);
        begin
            case (i)
                0: atan_turns = 20'd131072;
                1: atan_turns = 20'd77376;
                2: atan_turns = 20'd40884;
                3: atan_turns = 20'd20753;
                4: atan_turns = 20'd10417;
                5: atan_turns = 20'd5213;
                6: atan_turns = 20'd2607;
                7: atan_turns = 20'd1304;
                8: atan_turns = 20'd652;
                9: atan_turns = 20'd326;
                10: atan_turns = 20'd163;
                11: atan_turns = 20'd81;
                12: atan_turns = 20'd41;
                13: atan_turns = 20'd20;
                14: atan_turns = 20'd10;
                15: atan_turns = 20'd5;
                default: atan_turns = 20'd0;
            endcase
        end
    endfunction

    // ---- control and phase ------------------------------------------------
    reg        rotate_en;
    reg [31:0] phase_inc;
    reg [31:0] phase_acc;
    always @(posedge clk) begin
        if (!resetn || clear) begin
            rotate_en <= 1'b0;
            phase_inc <= 32'd0;
            phase_acc <= 32'd0;
        end else if (load) begin
            rotate_en <= 1'b1;
            phase_inc <= cfo_q12 <<< 7;
            phase_acc <= 32'd0;
        end else if (in_valid && rotate_en) begin
            phase_acc <= phase_acc + phase_inc;
        end
    end
    assign rotating = rotate_en;

    // Angle in 2^20 per turn. Fold it into [-1/4, +1/4) turn by negating the
    // vector (a half-turn) when needed; CORDIC converges within +/-99 degrees.
    wire signed [19:0] angle_in = rotate_en ? $signed(phase_acc[31:12]) : 20'sd0;
    // [+1/4, +1/2) turn -> subtract a half turn; [-1/2, -1/4) -> add one.
    wire flip_pos = (angle_in >= 20'sd262144);
    wire flip_neg = (angle_in < -20'sd262144);
    wire flip = flip_pos || flip_neg;
    wire signed [20:0] angle_folded =
        flip_pos ? {angle_in[19], angle_in} - 21'sd524288 :
        flip_neg ? {angle_in[19], angle_in} + 21'sd524288 :
                   {angle_in[19], angle_in};

    // Pipeline arrays: index k holds stage k. Two guard bits below the sample
    // LSB; 20 bits hold the ~1.647 gain of a full-scale sample with them.
    reg signed [19:0] x_p [0:ITERATIONS];
    reg signed [19:0] y_p [0:ITERATIONS];
    reg signed [20:0] z_p [0:ITERATIONS];
    reg signed [15:0] raw_re_p [0:LATENCY-1];
    reg signed [15:0] raw_im_p [0:LATENCY-1];
    reg        rot_p   [0:LATENCY-1];
    reg        valid_p [0:LATENCY-1];
    reg        rv_p    [0:LATENCY-1];
    reg [31:0] rs_p    [0:LATENCY-1];
    reg        sr_p    [0:LATENCY-1];
    integer k;

    always @(posedge clk) begin
        if (!resetn) begin
            for (k = 0; k < LATENCY; k = k + 1) begin
                valid_p[k] <= 1'b0;
                rv_p[k] <= 1'b0;
                rs_p[k] <= 32'd0;
                sr_p[k] <= 1'b0;
                rot_p[k] <= 1'b0;
                raw_re_p[k] <= 16'sd0;
                raw_im_p[k] <= 16'sd0;
            end
            for (k = 0; k <= ITERATIONS; k = k + 1) begin
                x_p[k] <= 20'sd0;
                y_p[k] <= 20'sd0;
                z_p[k] <= 21'sd0;
            end
        end else if (in_stream_reset) begin
            // A stream reset resets the correlator directly, not through this
            // delay; drop what is in flight so nothing from before the reset
            // reaches it afterwards (the old design would have wiped it too).
            for (k = 0; k < LATENCY; k = k + 1) begin
                valid_p[k] <= 1'b0;
                rv_p[k] <= 1'b0;
            end
        end else begin
            // sideband and raw sample delay line
            valid_p[0]  <= in_valid;
            rv_p[0]     <= in_resync_valid;
            rs_p[0]     <= in_resync_skip;
            sr_p[0]     <= in_stream_reset;
            rot_p[0]    <= rotate_en;
            raw_re_p[0] <= in_re;
            raw_im_p[0] <= in_im;
            for (k = 1; k < LATENCY; k = k + 1) begin
                valid_p[k]  <= valid_p[k - 1];
                rv_p[k]     <= rv_p[k - 1];
                rs_p[k]     <= rs_p[k - 1];
                sr_p[k]     <= sr_p[k - 1];
                rot_p[k]    <= rot_p[k - 1];
                raw_re_p[k] <= raw_re_p[k - 1];
                raw_im_p[k] <= raw_im_p[k - 1];
            end

            // CORDIC stage 0: fold the angle (a half turn is a negated
            // vector) and add the guard bits.
            x_p[0] <= flip ? -({{2{in_re[15]}}, in_re, 2'b00}) : {{2{in_re[15]}}, in_re, 2'b00};
            y_p[0] <= flip ? -({{2{in_im[15]}}, in_im, 2'b00}) : {{2{in_im[15]}}, in_im, 2'b00};
            z_p[0] <= angle_folded;
            for (k = 0; k < ITERATIONS; k = k + 1) begin
                if (z_p[k] >= 0) begin
                    x_p[k + 1] <= x_p[k] - (y_p[k] >>> k);
                    y_p[k + 1] <= y_p[k] + (x_p[k] >>> k);
                    z_p[k + 1] <= z_p[k] - $signed({1'b0, atan_turns(k)});
                end else begin
                    x_p[k + 1] <= x_p[k] + (y_p[k] >>> k);
                    y_p[k + 1] <= y_p[k] - (x_p[k] >>> k);
                    z_p[k + 1] <= z_p[k] + $signed({1'b0, atan_turns(k)});
                end
            end
        end
    end

    // Gain compensation: the 16-iteration CORDIC gain is 1.64676; multiply by
    // 19898/2^15 (0.607239), drop the two guard bits, round, saturate.
    reg signed [15:0] rot_re;
    reg signed [15:0] rot_im;
    wire signed [36:0] gx = x_p[ITERATIONS] * $signed(17'sd19898);
    wire signed [36:0] gy = y_p[ITERATIONS] * $signed(17'sd19898);
    wire signed [36:0] gx_r = (gx + 37'sd65536) >>> 17;
    wire signed [36:0] gy_r = (gy + 37'sd65536) >>> 17;
    function automatic signed [15:0] sat16(input signed [36:0] v);
        begin
            if (v > 37'sd32767) sat16 = 16'sd32767;
            else if (v < -37'sd32768) sat16 = -16'sd32768;
            else sat16 = v[15:0];
        end
    endfunction
    always @(posedge clk) begin
        if (!resetn) begin
            rot_re <= 16'sd0;
            rot_im <= 16'sd0;
        end else begin
            rot_re <= sat16(gx_r);
            rot_im <= sat16(gy_r);
        end
    end

    // The CORDIC result for the sample entering at t is in x_p/y_p[ITERATIONS]
    // at t + ITERATIONS + 1 and in rot_re/rot_im at t + ITERATIONS + 2; the
    // delay line's last stage holds its sideband at t + LATENCY. One more
    // register on the rotated path aligns the two.
    reg signed [15:0] rot_re_d;
    reg signed [15:0] rot_im_d;
    always @(posedge clk) begin
        rot_re_d <= rot_re;
        rot_im_d <= rot_im;
    end

    wire use_rot = rot_p[LATENCY - 1];
    assign out_re = use_rot ? rot_re_d : raw_re_p[LATENCY - 1];
    assign out_im = use_rot ? rot_im_d : raw_im_p[LATENCY - 1];
    assign out_valid = valid_p[LATENCY - 1];
    assign out_resync_valid = rv_p[LATENCY - 1];
    assign out_resync_skip = rs_p[LATENCY - 1];
    assign out_stream_reset = sr_p[LATENCY - 1];

endmodule
