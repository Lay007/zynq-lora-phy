`timescale 1ns/1ps

// Packet-rate complex matched-filter MAC for ToA refinement.
//
// This engine evaluates one correlation lag at a time by reusing a single
// complex multiply-accumulate datapath. IQ samples are requested from
// lora_iq_history_buffer by absolute accepted-sample count. Reference
// coefficients are supplied by an external ROM/table through reference_index;
// the coefficient inputs must be combinational or otherwise stable throughout
// each asserted iq_read_req cycle and are latched with the IQ read request.
//
// Correlation convention matches the MATLAB ToA reference:
//
//   C = sum_k x[start+k] * conj(reference[k])
//
// so
//   Re{C} += x_re*r_re + x_im*r_im
//   Im{C} += x_im*r_re - x_re*r_im
//
// correlation_power is |C|^2 shifted right by POWER_SHIFT and saturated to
// uint32. A constant power scale does not change the three-point log-domain
// fractional-ToA interpolation because the common log scale cancels.
//
// With REQUEST_ON_RESPONSE=1 the next request accompanies accumulation of the
// previous response. A one-cycle history port then costs N+3 clocks per lag,
// instead of 2*N+2. There is still only one outstanding read; variable response
// latency is allowed. Both modes reuse the same complex MAC datapath.
module lora_matched_filter_mac #(
    parameter integer REF_SAMPLES = 1024,
    parameter integer ACC_WIDTH = 48,
    parameter integer POWER_SHIFT = 30,
    parameter integer REQUEST_ON_RESPONSE = 0
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         stream_reset,

    input  wire                         start,
    input  wire [63:0]                  window_start_count,

    output wire                         iq_read_req,
    output wire [63:0]                  iq_read_sample_count,
    input  wire signed [15:0]           iq_read_re,
    input  wire signed [15:0]           iq_read_im,
    input  wire [63:0]                  iq_read_sample_count_out,
    input  wire                         iq_read_valid,
    input  wire                         iq_read_miss,

    output wire [15:0]                  reference_index,
    input  wire signed [15:0]           reference_re,
    input  wire signed [15:0]           reference_im,

    output reg                          busy,
    output reg                          result_valid,
    output reg  [63:0]                  result_sample_count,
    output reg  signed [ACC_WIDTH-1:0]  correlation_re,
    output reg  signed [ACC_WIDTH-1:0]  correlation_im,
    output reg  [31:0]                  correlation_power,
    output reg                          read_miss_error,
    output reg                          response_mismatch_error,
    output reg                          restart_error
);

    localparam [2:0] STATE_IDLE   = 3'd0;
    localparam [2:0] STATE_ISSUE  = 3'd1;
    localparam [2:0] STATE_WAIT   = 3'd2;
    localparam [2:0] STATE_SQUARE = 3'd3;
    localparam [2:0] STATE_SCALE  = 3'd4;

    reg [2:0] state;
    reg [63:0] base_count_reg;
    reg [15:0] sample_index;
    reg [63:0] pending_sample_count;
    reg signed [15:0] pending_ref_re;
    reg signed [15:0] pending_ref_im;

    reg signed [ACC_WIDTH-1:0] acc_re;
    reg signed [ACC_WIDTH-1:0] acc_im;
    reg [2*ACC_WIDTH-1:0] power_full;

    wire signed [31:0] product_rr = iq_read_re * pending_ref_re;
    wire signed [31:0] product_ii = iq_read_im * pending_ref_im;
    wire signed [31:0] product_ir = iq_read_im * pending_ref_re;
    wire signed [31:0] product_ri = iq_read_re * pending_ref_im;

    wire signed [32:0] product_re_33 =
        {product_rr[31], product_rr} + {product_ii[31], product_ii};
    wire signed [32:0] product_im_33 =
        {product_ir[31], product_ir} - {product_ri[31], product_ri};

    wire signed [ACC_WIDTH-1:0] product_re_ext =
        {{(ACC_WIDTH-33){product_re_33[32]}}, product_re_33};
    wire signed [ACC_WIDTH-1:0] product_im_ext =
        {{(ACC_WIDTH-33){product_im_33[32]}}, product_im_33};

    wire signed [ACC_WIDTH-1:0] next_acc_re = acc_re + product_re_ext;
    wire signed [ACC_WIDTH-1:0] next_acc_im = acc_im + product_im_ext;

    // Explicitly widen before squaring. This avoids relying on Verilog
    // expression-size rules for W x W multiplication and guarantees that the
    // default 48-bit accumulator keeps the full 96-bit square.
    wire signed [2*ACC_WIDTH-1:0] correlation_re_wide =
        {{ACC_WIDTH{correlation_re[ACC_WIDTH-1]}}, correlation_re};
    wire signed [2*ACC_WIDTH-1:0] correlation_im_wide =
        {{ACC_WIDTH{correlation_im[ACC_WIDTH-1]}}, correlation_im};
    wire [2*ACC_WIDTH-1:0] correlation_re_square =
        correlation_re_wide * correlation_re_wide;
    wire [2*ACC_WIDTH-1:0] correlation_im_square =
        correlation_im_wide * correlation_im_wide;
    wire [2*ACC_WIDTH-1:0] correlation_power_full =
        correlation_re_square + correlation_im_square;

    wire [2*ACC_WIDTH-1:0] shifted_power = power_full >> POWER_SHIFT;

    wire request_next = REQUEST_ON_RESPONSE && (state == STATE_WAIT) &&
        iq_read_valid && !iq_read_miss &&
        (iq_read_sample_count_out == pending_sample_count) &&
        (sample_index < REF_SAMPLES-1);
    // Prepare the next address/reference throughout WAIT, independently of
    // response validation. This keeps the 64-bit response comparator off the
    // address arithmetic path; only the request enable depends on it.
    wire [15:0] request_index = (REQUEST_ON_RESPONSE && state == STATE_WAIT) ?
        sample_index + 16'd1 : sample_index;
    assign iq_read_req = resetn && !stream_reset &&
        ((state == STATE_ISSUE) || request_next);
    assign iq_read_sample_count = base_count_reg + request_index;
    assign reference_index = request_index;

    initial begin
        if (REF_SAMPLES < 1 || REF_SAMPLES > 65535)
            $error("lora_matched_filter_mac REF_SAMPLES must be 1..65535");
        if (ACC_WIDTH < 33)
            $error("lora_matched_filter_mac ACC_WIDTH must be >= 33");
        if (POWER_SHIFT < 0 || POWER_SHIFT >= (2*ACC_WIDTH))
            $error("lora_matched_filter_mac POWER_SHIFT outside power width");
    end

    always @(posedge clk) begin
        if (!resetn || stream_reset) begin
            state                   <= STATE_IDLE;
            base_count_reg          <= 64'd0;
            sample_index            <= 16'd0;
            pending_sample_count    <= 64'd0;
            pending_ref_re          <= 16'sd0;
            pending_ref_im          <= 16'sd0;
            acc_re                  <= {ACC_WIDTH{1'b0}};
            acc_im                  <= {ACC_WIDTH{1'b0}};
            power_full              <= {(2*ACC_WIDTH){1'b0}};
            busy                    <= 1'b0;
            result_valid            <= 1'b0;
            result_sample_count     <= 64'd0;
            correlation_re          <= {ACC_WIDTH{1'b0}};
            correlation_im          <= {ACC_WIDTH{1'b0}};
            correlation_power       <= 32'd0;
            read_miss_error         <= 1'b0;
            response_mismatch_error <= 1'b0;
            restart_error           <= 1'b0;
        end else begin
            result_valid            <= 1'b0;
            read_miss_error         <= 1'b0;
            response_mismatch_error <= 1'b0;
            restart_error           <= 1'b0;

            if (start && busy)
                restart_error <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        base_count_reg <= window_start_count;
                        sample_index   <= 16'd0;
                        acc_re         <= {ACC_WIDTH{1'b0}};
                        acc_im         <= {ACC_WIDTH{1'b0}};
                        busy           <= 1'b1;
                        state          <= STATE_ISSUE;
                    end
                end

                STATE_ISSUE: begin
                    // The history buffer sees iq_read_req at this edge. Latch
                    // the matching reference coefficient and expected address
                    // so they remain aligned with its registered response.
                    pending_sample_count <= iq_read_sample_count;
                    pending_ref_re       <= reference_re;
                    pending_ref_im       <= reference_im;
                    state                <= STATE_WAIT;
                end

                STATE_WAIT: begin
                    if (iq_read_miss) begin
                        read_miss_error <= 1'b1;
                        busy            <= 1'b0;
                        state           <= STATE_IDLE;
                    end else if (iq_read_valid) begin
                        if (iq_read_sample_count_out != pending_sample_count) begin
                            response_mismatch_error <= 1'b1;
                            busy                    <= 1'b0;
                            state                   <= STATE_IDLE;
                        end else if (sample_index == REF_SAMPLES-1) begin
                            // Include the final product before freezing the
                            // complex correlation result.
                            correlation_re      <= next_acc_re;
                            correlation_im      <= next_acc_im;
                            result_sample_count <= base_count_reg;
                            state               <= STATE_SQUARE;
                        end else begin
                            acc_re       <= next_acc_re;
                            acc_im       <= next_acc_im;
                            sample_index <= sample_index + 16'd1;
                            if (REQUEST_ON_RESPONSE) begin
                                pending_sample_count <= iq_read_sample_count;
                                pending_ref_re       <= reference_re;
                                pending_ref_im       <= reference_im;
                                state                <= STATE_WAIT;
                            end else begin
                                state <= STATE_ISSUE;
                            end
                        end
                    end
                end

                STATE_SQUARE: begin
                    power_full <= correlation_power_full;
                    state <= STATE_SCALE;
                end

                STATE_SCALE: begin
                    if (|(shifted_power[2*ACC_WIDTH-1:32]))
                        correlation_power <= 32'hffff_ffff;
                    else
                        correlation_power <= shifted_power[31:0];
                    result_valid <= 1'b1;
                    busy         <= 1'b0;
                    state        <= STATE_IDLE;
                end

                default: begin
                    busy  <= 1'b0;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
