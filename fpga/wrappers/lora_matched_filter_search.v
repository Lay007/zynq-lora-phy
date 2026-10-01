`timescale 1ns/1ps

// Sequence a short packet-rate matched-filter search around one coarse ToA.
//
// The controller reuses lora_matched_filter_mac for every integer candidate
// lag and feeds the resulting correlation-power stream directly into
// lora_peak_triplet_capture. This keeps the long complex matched filter
// packet-rate instead of building a continuous REF_SAMPLES-tap FIR.
//
// For SEARCH_RADIUS=8 the candidate window is
//
//   coarse_start_count-8 ... coarse_start_count ... coarse_start_count+8
//
// and therefore contains 17 integer lags. The peak-capture output is already
// expressed in the same absolute accepted-sample-count epoch as the IQ history
// buffer, so peak_sample_count is the integer-refined ToA for the later
// fractional interpolator.
//
// The reference coefficient interface is passed through from the reused MAC.
// A future SF7/L=8 reference ROM can therefore be attached without changing
// the search controller.
module lora_matched_filter_search #(
    parameter integer REF_SAMPLES   = 1024,
    parameter integer SEARCH_RADIUS = 8,
    parameter integer ACC_WIDTH     = 48,
    parameter integer POWER_SHIFT   = 30,
    parameter integer REQUEST_ON_RESPONSE = 0,
    parameter integer COARSE_STRIDE = 1
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         stream_reset,

    input  wire                         start,
    input  wire [63:0]                  coarse_start_count,

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
    output wire [63:0]                  search_first_count,

    output wire [31:0]                  correlation_magnitude,
    output wire                         correlation_magnitude_valid,
    output wire [63:0]                  correlation_sample_count,

    output wire [31:0]                  magnitude_before,
    output wire [31:0]                  magnitude_peak,
    output wire [31:0]                  magnitude_after,
    output wire [15:0]                  peak_index,
    output wire [63:0]                  peak_sample_count,
    output wire                         triplet_valid,

    output reg                          underflow_error,
    output reg                          search_restart_error,
    output reg                          mac_window_mismatch_error,
    output wire                         mac_read_miss_error,
    output wire                         mac_response_mismatch_error,
    output wire                         mac_restart_error,
    output wire                         peak_boundary_error,
    output wire                         peak_restart_error
);

    localparam integer SEARCH_LAGS = 2*SEARCH_RADIUS/COARSE_STRIDE + 1;
    localparam integer REFINE_LAGS = 2*COARSE_STRIDE + 1;
    localparam [63:0] SEARCH_RADIUS_U64 = SEARCH_RADIUS;

    localparam [2:0] STATE_IDLE      = 3'd0;
    localparam [2:0] STATE_ARM_PEAK  = 3'd1;
    localparam [2:0] STATE_LAUNCH    = 3'd2;
    localparam [2:0] STATE_WAIT_MAC  = 3'd3;
    localparam [2:0] STATE_WAIT_PEAK = 3'd4;

    reg [2:0] state;
    reg [63:0] first_count_reg;
    reg [15:0] lag_index;
    reg refining;
    reg [63:0] refine_first_count;
    reg [15:0] refine_first_index;

    wire mac_start = (state == STATE_LAUNCH);
    wire [63:0] mac_window_start_count = refining ?
        refine_first_count + lag_index : first_count_reg + lag_index*COARSE_STRIDE;
    wire mac_busy;
    wire mac_result_valid;
    wire [63:0] mac_result_sample_count;
    wire signed [ACC_WIDTH-1:0] mac_correlation_re_unused;
    wire signed [ACC_WIDTH-1:0] mac_correlation_im_unused;
    wire [31:0] mac_correlation_power;

    wire peak_search_start = (state == STATE_ARM_PEAK);
    wire peak_busy_unused;
    wire [31:0] coarse_before, coarse_peak, coarse_after;
    wire [15:0] coarse_index;
    wire [63:0] coarse_count_unused;
    wire coarse_triplet, coarse_boundary, coarse_restart;
    wire [31:0] fine_before, fine_peak, fine_after;
    wire [15:0] fine_index;
    wire [63:0] fine_count;
    wire fine_triplet, fine_boundary, fine_restart;
    wire [63:0] coarse_peak_count = first_count_reg + coarse_index*COARSE_STRIDE;

    wire mac_window_mismatch_now =
        (state == STATE_WAIT_MAC) && mac_result_valid &&
        (mac_result_sample_count != mac_window_start_count);

    // A failed MAC means the already-armed peak collector has only a partial
    // magnitude window. Reset it immediately so the next search cannot inherit
    // stale samples or report a false restart collision.
    wire peak_abort = mac_read_miss_error || mac_response_mismatch_error ||
                      mac_restart_error || mac_window_mismatch_now;
    wire peak_resetn = resetn && !stream_reset && !peak_abort;

    assign search_first_count = first_count_reg;
    assign correlation_magnitude = mac_correlation_power;
    assign correlation_magnitude_valid = mac_result_valid;
    assign correlation_sample_count = mac_result_sample_count;
    assign magnitude_before = COARSE_STRIDE == 1 ? coarse_before : fine_before;
    assign magnitude_peak = COARSE_STRIDE == 1 ? coarse_peak : fine_peak;
    assign magnitude_after = COARSE_STRIDE == 1 ? coarse_after : fine_after;
    assign peak_index = COARSE_STRIDE == 1 ? coarse_index : refine_first_index + fine_index;
    assign peak_sample_count = COARSE_STRIDE == 1 ? coarse_peak_count : fine_count;
    assign triplet_valid = COARSE_STRIDE == 1 ? coarse_triplet : fine_triplet;
    assign peak_boundary_error = coarse_boundary || fine_boundary;
    assign peak_restart_error = coarse_restart || fine_restart;

    initial begin
        if ((COARSE_STRIDE != 1 && COARSE_STRIDE != 2) || SEARCH_RADIUS % COARSE_STRIDE != 0)
            $error("coarse stride must be 1 or 2 and divide SEARCH_RADIUS");
        if (SEARCH_RADIUS < 1 || SEARCH_RADIUS > 32767)
            $error("lora_matched_filter_search SEARCH_RADIUS must be 1..32767");
        if (SEARCH_LAGS > 65535)
            $error("lora_matched_filter_search search window exceeds 16-bit peak index");
    end

    lora_matched_filter_mac #(
        .REF_SAMPLES(REF_SAMPLES),
        .ACC_WIDTH(ACC_WIDTH),
        .POWER_SHIFT(POWER_SHIFT),
        .REQUEST_ON_RESPONSE(REQUEST_ON_RESPONSE)
    ) u_mac (
        .clk(clk),
        .resetn(resetn),
        .stream_reset(stream_reset),
        .start(mac_start),
        .window_start_count(mac_window_start_count),
        .iq_read_req(iq_read_req),
        .iq_read_sample_count(iq_read_sample_count),
        .iq_read_re(iq_read_re),
        .iq_read_im(iq_read_im),
        .iq_read_sample_count_out(iq_read_sample_count_out),
        .iq_read_valid(iq_read_valid),
        .iq_read_miss(iq_read_miss),
        .reference_index(reference_index),
        .reference_re(reference_re),
        .reference_im(reference_im),
        .busy(mac_busy),
        .result_valid(mac_result_valid),
        .result_sample_count(mac_result_sample_count),
        .correlation_re(mac_correlation_re_unused),
        .correlation_im(mac_correlation_im_unused),
        .correlation_power(mac_correlation_power),
        .read_miss_error(mac_read_miss_error),
        .response_mismatch_error(mac_response_mismatch_error),
        .restart_error(mac_restart_error)
    );

    lora_peak_triplet_capture #(
        .SEARCH_SAMPLES(SEARCH_LAGS)
    ) u_peak_capture (
        .clk(clk),
        .resetn(peak_resetn),
        .search_start(peak_search_start && !refining),
        .search_base_count(first_count_reg),
        .magnitude(mac_correlation_power),
        .magnitude_valid(mac_result_valid && !refining),
        .magnitude_before(coarse_before),
        .magnitude_peak(coarse_peak),
        .magnitude_after(coarse_after),
        .peak_index(coarse_index),
        .peak_sample_count(coarse_count_unused),
        .triplet_valid(coarse_triplet),
        .busy(peak_busy_unused),
        .boundary_error(coarse_boundary),
        .restart_error(coarse_restart)
    );

    generate if (COARSE_STRIDE > 1) begin : g_refine
        // Sparse powers are only a coarse locator. The interpolator receives
        // a fresh unit-sample triplet from a five-lag local search, never the
        // two-sample neighbours of the coarse scan. LoRa SF7/L8's main lobe
        // spans multiple samples; stride 2 must not be used for isolated peaks.
        lora_peak_triplet_capture #(.SEARCH_SAMPLES(REFINE_LAGS)) u_fine_peak (
            .clk(clk), .resetn(peak_resetn), .search_start(peak_search_start && refining),
            .search_base_count(refine_first_count), .magnitude(mac_correlation_power),
            .magnitude_valid(mac_result_valid && refining),
            .magnitude_before(fine_before), .magnitude_peak(fine_peak), .magnitude_after(fine_after),
            .peak_index(fine_index), .peak_sample_count(fine_count), .triplet_valid(fine_triplet),
            .busy(), .boundary_error(fine_boundary), .restart_error(fine_restart));
    end else begin : g_no_refine
        assign fine_before = 0; assign fine_peak = 0; assign fine_after = 0;
        assign fine_index = 0; assign fine_count = 0; assign fine_triplet = 0;
        assign fine_boundary = 0; assign fine_restart = 0;
    end endgenerate

    always @(posedge clk) begin
        if (!resetn || stream_reset) begin
            state                     <= STATE_IDLE;
            first_count_reg           <= 64'd0;
            lag_index                 <= 16'd0;
            refining                  <= 1'b0;
            refine_first_count        <= 64'd0;
            refine_first_index        <= 16'd0;
            busy                      <= 1'b0;
            underflow_error           <= 1'b0;
            search_restart_error      <= 1'b0;
            mac_window_mismatch_error <= 1'b0;
        end else begin
            underflow_error           <= 1'b0;
            search_restart_error      <= 1'b0;
            mac_window_mismatch_error <= 1'b0;

            if (start && busy)
                search_restart_error <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        if (coarse_start_count < SEARCH_RADIUS_U64) begin
                            underflow_error <= 1'b1;
                        end else begin
                            first_count_reg <= coarse_start_count - SEARCH_RADIUS_U64;
                            lag_index       <= 16'd0;
                            refining        <= 1'b0;
                            busy            <= 1'b1;
                            state           <= STATE_ARM_PEAK;
                        end
                    end
                end

                STATE_ARM_PEAK: begin
                    // Give the peak-capture block one cycle to arm before the
                    // first long MAC result can arrive.
                    state <= STATE_LAUNCH;
                end

                STATE_LAUNCH: begin
                    // mac_start is combinationally asserted for this state.
                    state <= STATE_WAIT_MAC;
                end

                STATE_WAIT_MAC: begin
                    if (mac_read_miss_error || mac_response_mismatch_error ||
                        mac_restart_error) begin
                        busy  <= 1'b0;
                        state <= STATE_IDLE;
                    end else if (mac_result_valid) begin
                        if (mac_window_mismatch_now) begin
                            mac_window_mismatch_error <= 1'b1;
                            busy                      <= 1'b0;
                            state                     <= STATE_IDLE;
                        end else if (lag_index == (refining ? REFINE_LAGS-1 : SEARCH_LAGS-1)) begin
                            state <= STATE_WAIT_PEAK;
                        end else begin
                            lag_index <= lag_index + 16'd1;
                            state     <= STATE_LAUNCH;
                        end
                    end
                end

                STATE_WAIT_PEAK: begin
                    if (!refining && COARSE_STRIDE > 1 && coarse_triplet) begin
                        refining <= 1'b1;
                        refine_first_count <= coarse_peak_count - COARSE_STRIDE;
                        refine_first_index <= coarse_index*COARSE_STRIDE - COARSE_STRIDE;
                        lag_index <= 16'd0;
                        state <= STATE_ARM_PEAK;
                    end else if (triplet_valid || peak_boundary_error || peak_restart_error) begin
                        busy  <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    busy  <= 1'b0;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
