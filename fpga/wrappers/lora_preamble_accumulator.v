`timescale 1ns/1ps

// Preamble detection by accumulating the correlator's per-bin power (#36).
//
// The generated detector needs eight consecutive preamble decisions within
// +-1 bin of each other: every window has to be right on its own, and at low
// SNR one wrong window in eight loses the packet. On the PER bench the board's
// missed detections matched exactly that bound (0.105-0.14 at -8.5 dB SF7),
// which is what kept CR 4/7 and 4/8 1.1-1.6 dB from ideal.
//
// Here the |X|^2 of every bin is summed over the last K windows. Across the
// preamble the bin is the same in every window, so its power adds up while the
// noise bins average out. Noise only, each accumulated bin is Gamma(K); a
// preamble is declared when the largest accumulated bin exceeds T times the
// mean of the others:
//
//     (N-1) * peak * T_DEN > T_NUM * (total - peak)
//
// T = 4.41 for K = 8 gives a false alarm of about 1e-6 per window (one in
// ~17 minutes at 977 windows/s). Float model (tools/lora_detection_model.py):
// with the live grid shift below, missed detections 0.12 / 0.04 at -10 / -9 dB
// against 0.41 / 0.17 for the eight-equal-decisions rule.
//
// On a trigger the module requests a grid shift that puts the windows on the
// preamble's symbol boundaries: for an accumulated peak at bin k and a
// sub-chip offset f the advance is mod(-(k+f), N) chips, in samples
// mod(M - round(L*(k+f)), M). f comes from a parabola through the powers of
// the peak and its neighbours (the amplitude parabola needs square roots and
// is only marginally better in the model: 0.10 vs 0.12 missed at -10 dB), as
// round(L*f) in -L/2..L/2 found by comparison, without a divider.
// After the shift the preamble reads bin 0 or +-1 and the sync word is read
// on whole symbols; lora_detector_timestamp_path checks it while `aligned`
// is high, for ALIGNED_WINDOWS windows after the trigger.
//
// One trigger per arming. The module re-arms itself after ALIGNED_WINDOWS
// windows without a detection (clearing the accumulation), stays disarmed
// after a detection until stream_reset (the capture path's re-arm), and never
// triggers while `enable` is low.
module lora_preamble_accumulator #(
    parameter integer SPREADING_FACTOR = 7,
    parameter integer SAMPLES_PER_CHIP = 8,
    parameter integer K_WINDOWS = 8,
    parameter integer POWER_WIDTH = 40,      // ufix40_En19 from the M11 core
    parameter integer POWER_DROP = 8,        // keep ufix32_En11
    parameter integer T_NUM = 441,           // T = T_NUM / T_DEN
    parameter integer T_DEN = 100,
    parameter integer ALIGNED_WINDOWS = 18
) (
    input  wire                    clk,
    input  wire                    resetn,
    input  wire                    stream_reset,
    input  wire                    enable,
    // Accepted input sample: the correlator latches a grid request on one.
    input  wire                    sample_valid,
    input  wire                    packet_detected,

    input  wire [POWER_WIDTH-1:0]  bin_power,
    input  wire [31:0]             bin_index,
    input  wire                    bin_valid,
    // One pulse per decided window (the correlator's symbol_valid).
    input  wire                    window_done,

    output reg                     resync_request,
    output reg  [31:0]             resync_skip,
    output reg                     aligned,
    output reg  [15:0]             trigger_bin,
    output reg  [3:0]              trigger_fraction,  // round(L*f), two's complement
    output reg                     triggered          // one-cycle pulse
);

    localparam integer N = 1 << SPREADING_FACTOR;
    localparam integer M = N * SAMPLES_PER_CHIP;
    localparam integer PW = 32;
    localparam integer SW = PW + 3;                          // sum of 8
    localparam integer TW = SW + SPREADING_FACTOR;           // sum of 128 bins

    // Ring of the last K windows' powers per bin, and running sums.
    reg [PW-1:0] ring [0:K_WINDOWS*N-1];
    reg [SW-1:0] sums [0:N-1];
    reg [TW-1:0] total;
    reg [2:0]    slot;
    reg [3:0]    filled;
    reg [SW-1:0] best_value;
    reg [SPREADING_FACTOR-1:0] best_bin;

    integer i;
    initial begin
        for (i = 0; i < K_WINDOWS * N; i = i + 1) ring[i] = {PW{1'b0}};
        for (i = 0; i < N; i = i + 1) sums[i] = {SW{1'b0}};
    end

    wire [POWER_WIDTH-1:0] shifted = bin_power >> POWER_DROP;
    wire [PW-1:0] power_in = (|shifted[POWER_WIDTH-1:PW]) ? {PW{1'b1}} : shifted[PW-1:0];
    wire [SPREADING_FACTOR-1:0] b = bin_index[SPREADING_FACTOR-1:0];
    wire [SPREADING_FACTOR+2:0] ring_addr = {slot, b};
    // The ring is not cleared on a re-arm (a distributed RAM cannot be zeroed in
    // one cycle); for the first K windows after it every slot is being written
    // for the first time, so what it holds is stale and counts as zero.
    wire [PW-1:0] oldest = (filled < K_WINDOWS) ? {PW{1'b0}} : ring[ring_addr];
    wire [SW-1:0] sum_new = sums[b] + power_in - oldest;

    // Arming state.
    localparam [1:0] S_ACC = 2'd0, S_ALIGNED = 2'd1, S_DONE = 2'd2;
    reg [1:0] state;
    reg [4:0] aligned_count;

    // Decision pipeline after the last bin of a window.
    reg        decide;
    reg [2:0]  post;
    reg [SW-1:0] p_minus, p_zero, p_plus;

    wire clear_acc = stream_reset || (state == S_ALIGNED && window_done &&
                                      aligned_count == ALIGNED_WINDOWS - 1);

    always @(posedge clk) begin
        if (!resetn || clear_acc) begin
            total <= {TW{1'b0}};
            slot <= 3'd0;
            filled <= 4'd0;
            best_value <= {SW{1'b0}};
            best_bin <= {SPREADING_FACTOR{1'b0}};
            decide <= 1'b0;
            for (i = 0; i < N; i = i + 1) sums[i] <= {SW{1'b0}};
        end else begin
            decide <= 1'b0;
            if (bin_valid) begin
                ring[ring_addr] <= power_in;
                sums[b] <= sum_new;
                total <= total + power_in - oldest;
                if (b == 0 || sum_new > best_value) begin
                    best_value <= sum_new;
                    best_bin <= b;
                end
                if (b == N - 1) begin
                    slot <= (slot == K_WINDOWS - 1) ? 3'd0 : slot + 3'd1;
                    if (filled < K_WINDOWS) filled <= filled + 4'd1;
                    decide <= 1'b1;
                end
            end
        end
    end

    // Threshold test one cycle after the window's last bin (total and the
    // best bin are then final): (N-1)*peak*T_DEN > T_NUM*(total-peak).
    wire [TW+15:0] lhs = best_value * (N - 1) * T_DEN;
    wire [TW+15:0] rhs = (total - best_value) * T_NUM;
    wire over = (filled == K_WINDOWS) && (lhs > rhs);

    // Parabola on powers: f = 0.5*(Pm - Pp)/(Pm - 2*P0 + Pp); den < 0 at a
    // peak. round(L*f) = q in -L/2..L/2 with |L*num - q*den2| smallest, where
    // num = Pm - Pp and den2 = 2*(2*P0 - Pm - Pp) > 0.
    reg signed [SW+2:0] num;
    reg signed [SW+3:0] den2;
    reg signed [3:0] q;
    integer j;
    reg signed [SW+8:0] target;
    always @* begin
        num = $signed({3'b000, p_minus}) - $signed({3'b000, p_plus});
        den2 = ($signed({4'b0000, p_zero}) <<< 2) - ($signed({4'b0000, p_minus}) <<< 1)
             - ($signed({4'b0000, p_plus}) <<< 1);
        target = num * SAMPLES_PER_CHIP;
        q = 4'sd0;
        if (den2 > 0) begin
            // step q while target is past the midpoint to the next value
            for (j = 1; j <= SAMPLES_PER_CHIP / 2; j = j + 1) begin
                if (target * 2 > den2 * (2 * j - 1)) q = j;
                if (target * 2 < -den2 * (2 * j - 1)) q = -j;
            end
        end
    end

    wire [15:0] k_bin = {{(16 - SPREADING_FACTOR){1'b0}}, best_bin};
    // advance = mod(M - (L*k + q), M)
    wire signed [31:0] lk_q = $signed({16'd0, k_bin}) * SAMPLES_PER_CHIP + q;
    wire [31:0] advance = (M - lk_q) & (M - 1);

    always @(posedge clk) begin
        if (!resetn || stream_reset) begin
            state <= S_ACC;
            aligned <= 1'b0;
            aligned_count <= 5'd0;
            resync_request <= 1'b0;
            resync_skip <= 32'd0;
            trigger_bin <= 16'd0;
            trigger_fraction <= 4'd0;
            triggered <= 1'b0;
            post <= 3'd0;
            p_minus <= {SW{1'b0}};
            p_zero <= {SW{1'b0}};
            p_plus <= {SW{1'b0}};
        end else begin
            triggered <= 1'b0;
            if (packet_detected) begin
                state <= S_DONE;
                aligned <= 1'b0;
            end
            case (state)
            S_ACC: begin
                if (post == 3'd0 && decide && over && enable) begin
                    // read the neighbours from the (now final) sums
                    p_zero <= sums[best_bin];
                    p_minus <= sums[best_bin - 1'b1];
                    p_plus <= sums[best_bin + 1'b1];
                    post <= 3'd1;
                end else if (post == 3'd1) begin
                    post <= 3'd0;
                    resync_request <= 1'b1;
                    resync_skip <= advance;
                    trigger_bin <= k_bin;
                    trigger_fraction <= q;
                    triggered <= 1'b1;
                    aligned <= 1'b1;
                    aligned_count <= 5'd0;
                    state <= S_ALIGNED;
                end
            end
            S_ALIGNED: begin
                if (window_done) begin
                    if (aligned_count == ALIGNED_WINDOWS - 1) begin
                        aligned <= 1'b0;
                        state <= S_ACC;
                    end
                    aligned_count <= aligned_count + 5'd1;
                end
            end
            default: ;
            endcase
            // Held across exactly one accepted sample, as lora_symbol_grid_resync
            // does: the correlator latches it there, and a request still high
            // when that skip has run out would be taken a second time.
            if (resync_request && sample_valid && !(post == 3'd1))
                resync_request <= 1'b0;
        end
    end

endmodule
