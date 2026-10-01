`timescale 1ns/1ps

module tb_lora_detector_timestamp_path;
    reg         clk = 1'b0;
    reg         resetn = 1'b0;
    reg         clk_enable = 1'b1;
    reg         reset_in = 1'b0;
    reg  [31:0] symbol_index = 32'd0;
    reg         symbol_valid = 1'b0;
    reg  [63:0] symbol_sample_count = 64'd0;
    reg         timestamp_valid = 1'b0;
    reg  [7:0]  sync_word = 8'h12;
    // Correlator peak of the decision being driven; zero means silence.
    reg  [15:0] symbol_peak = 16'd100;

    wire        detected;
    wire        straddle_detected;
    wire        split_detected;
    wire        early_sync_detected;
    wire        preamble_detected;
    wire        sync_valid;
    wire [15:0] preamble_bin;
    wire [15:0] chips_to_boundary;
    wire [7:0]  bins_seen;
    wire [63:0] preamble_start_count;
    wire        preamble_start_valid;
    wire [63:0] packet_start_count;
    wire        packet_start_valid;
    wire        alignment_error;
    wire        symbol_index_width_error;

    integer errors = 0;
    integer i;
    reg edge_preamble;
    reg edge_detected;
    reg edge_straddle;
    reg edge_split;
    reg edge_early;
    reg [15:0] edge_bin;
    reg [15:0] edge_chips;
    reg edge_sync_valid;

    always #5 clk = ~clk;

    lora_detector_timestamp_path dut (
        .clk(clk),
        .resetn(resetn),
        .clk_enable(clk_enable),
        .reset_in(reset_in),
        .symbol_index(symbol_index),
        .symbol_valid(symbol_valid),
        .symbol_sample_count(symbol_sample_count),
        .timestamp_valid(timestamp_valid),
        .sync_word(sync_word),
        .symbol_peak(symbol_peak),
        .detected(detected),
        .straddle_detected(straddle_detected),
        .split_detected(split_detected),
        .early_sync_detected(early_sync_detected),
        .preamble_detected(preamble_detected),
        .sync_valid(sync_valid),
        .preamble_bin(preamble_bin),
        .chips_to_boundary(chips_to_boundary),
        .bins_seen(bins_seen),
        .preamble_start_count(preamble_start_count),
        .preamble_start_valid(preamble_start_valid),
        .packet_start_count(packet_start_count),
        .packet_start_valid(packet_start_valid),
        .alignment_error(alignment_error),
        .symbol_index_width_error(symbol_index_width_error)
    );

    task automatic expect_bit;
        input [8*64-1:0] name;
        input got;
        input expected;
        begin
            if (got !== expected) begin
                $display("FAIL %-56s got=%0d expected=%0d", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("PASS %-56s value=%0d", name, got);
            end
        end
    endtask

    task automatic expect_u16;
        input [8*64-1:0] name;
        input [15:0] got;
        input [15:0] expected;
        begin
            if (got !== expected) begin
                $display("FAIL %-56s got=0x%04x expected=0x%04x", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("PASS %-56s value=0x%04x", name, got);
            end
        end
    endtask

    task automatic expect_u64;
        input [8*64-1:0] name;
        input [63:0] got;
        input [63:0] expected;
        begin
            if (got !== expected) begin
                $display("FAIL %-56s got=0x%016x expected=0x%016x", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("PASS %-56s value=0x%016x", name, got);
            end
        end
    endtask

    // Drive one correlator decision. The generated detector outputs are
    // combinational from the current symbol and its registered history, so
    // capture those pulses in the active region at the sampling edge. The
    // timestamp aligner registers the corresponding timestamp on that edge.
    task automatic send_symbol;
        input [31:0] index_value;
        input [63:0] timestamp_value;
        input timestamp_is_valid;
        begin
            @(negedge clk);
            symbol_index = index_value;
            symbol_sample_count = timestamp_value;
            symbol_valid = 1'b1;
            timestamp_valid = timestamp_is_valid;

            @(posedge clk);
            edge_preamble = preamble_detected;
            edge_detected = detected;
            edge_straddle = straddle_detected;
            edge_split = split_detected;
            edge_early = early_sync_detected;
            edge_bin = preamble_bin;
            edge_chips = chips_to_boundary;
            edge_sync_valid = sync_valid;
            #1;
            symbol_valid = 1'b0;
            timestamp_valid = 1'b0;
        end
    endtask

    // Drive `count` identical decisions with timestamps first_timestamp,
    // +100, +200, ...
    task automatic send_run;
        input [31:0] index_value;
        input integer count;
        input [63:0] first_timestamp;
        integer run_i;
        begin
            for (run_i = 0; run_i < count; run_i = run_i + 1)
                send_symbol(index_value, first_timestamp + run_i*64'd100, 1'b1);
        end
    endtask

    task automatic pulse_stream_reset;
        begin
            @(negedge clk);
            reset_in = 1'b1;
            symbol_valid = 1'b0;
            timestamp_valid = 1'b0;
            @(posedge clk);
            #1;
            reset_in = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1;
        expect_bit("preamble timestamp valid reset", preamble_start_valid, 1'b0);
        expect_bit("packet timestamp valid reset", packet_start_valid, 1'b0);
        expect_bit("alignment error reset", alignment_error, 1'b0);
        resetn = 1'b1;

        // Standard private-network sync word 0x12. With preamble bin zero the
        // two expected sync bins are 8 and 16 for the generated SF7 detector.
        for (i = 0; i < 7; i = i + 1) begin
            send_symbol(32'd0, 64'd100 + i*64'd100, 1'b1);
            expect_bit("no early preamble timestamp", preamble_start_valid, 1'b0);
        end

        send_symbol(32'd0, 64'd800, 1'b1);
        expect_bit("generated detector sees 8-symbol preamble", edge_preamble, 1'b1);
        expect_bit("aligned preamble timestamp valid", preamble_start_valid, 1'b1);
        expect_u64("aligned preamble timestamp selects first symbol", preamble_start_count, 64'd100);
        expect_u16("generated detector preamble bin", preamble_bin, 16'd0);
        expect_u16("generated detector chips to boundary", chips_to_boundary, 16'd0);

        send_symbol(32'd8, 64'd900, 1'b1);
        expect_bit("no packet decision after first sync symbol", edge_detected, 1'b0);
        expect_bit("no packet timestamp after first sync symbol", packet_start_valid, 1'b0);

        send_symbol(32'd16, 64'd1000, 1'b1);
        expect_bit("generated detector confirms preamble plus sync", edge_detected, 1'b1);
        expect_bit("generated detector sync validation", edge_sync_valid, 1'b1);
        expect_bit("aligned packet timestamp valid", packet_start_valid, 1'b1);
        expect_u64("aligned packet timestamp selects first preamble symbol", packet_start_count, 64'd100);

        // reset_in is the generated streaming reset. The wrapper deliberately
        // clears timestamp history on the same edge, preventing stale metadata
        // from crossing a receiver resynchronization.
        pulse_stream_reset();
        expect_bit("stream reset clears preamble timestamp valid", preamble_start_valid, 1'b0);
        expect_bit("stream reset clears packet timestamp valid", packet_start_valid, 1'b0);
        expect_bit("stream reset clears alignment error", alignment_error, 1'b0);

        for (i = 0; i < 7; i = i + 1) begin
            send_symbol(32'd0, 64'd2000 + i*64'd100, 1'b1);
            expect_bit("no stale preamble after stream reset", preamble_start_valid, 1'b0);
        end
        send_symbol(32'd0, 64'd2700, 1'b1);
        expect_bit("fresh preamble detected after stream reset", edge_preamble, 1'b1);
        expect_bit("fresh preamble timestamp valid after reset", preamble_start_valid, 1'b1);
        expect_u64("fresh preamble uses post-reset history only", preamble_start_count, 64'd2000);

        // M7: straddle-tolerant sync acceptance. Where the preamble meets the
        // first sync symbol the free-running window can return the preamble
        // half of two comparable peaks, so the first sync symbol shows up as
        // one extra preamble bin while the second is read correctly. Symbol
        // decisions below are the real RTL replay pattern (bins 64/64x13/80
        // for a board capture the generated detector never accepted).
        //
        // Normal pattern first, as the reference for where the packet
        // timestamp must land: 12 preamble bins, +8, +16.
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd72, 64'd1300, 1'b1);
        expect_bit("normal sync: no decision after first sync symbol", edge_detected, 1'b0);
        send_symbol(32'd80, 64'd1400, 1'b1);
        expect_bit("normal sync at bin 64 detected", edge_detected, 1'b1);
        expect_bit("normal sync is the generated detector's decision", edge_sync_valid, 1'b1);
        expect_bit("normal sync is not flagged as straddle", edge_straddle, 1'b0);
        expect_u64("normal sync packet timestamp", packet_start_count, 64'd500);

        // The straddle pattern: the same twelve preamble bins, the first sync
        // slot reads as the preamble bin, the second sync slot is correct.
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd64, 64'd1300, 1'b1);
        expect_bit("straddle: no decision on the extra preamble bin", edge_detected, 1'b0);
        send_symbol(32'd80, 64'd1400, 1'b1);
        expect_bit("straddle sync at bin 64 detected", edge_detected, 1'b1);
        expect_bit("straddle sync is not the generated detector's decision", edge_sync_valid, 1'b0);
        expect_bit("straddle sync is flagged for the joint controller", edge_straddle, 1'b1);
        expect_bit("straddle sync yields a packet timestamp", packet_start_valid, 1'b1);
        expect_u64("straddle sync timestamp equals the normal one", packet_start_count, 64'd500);
        expect_bit("straddle sync raises no alignment error", alignment_error, 1'b0);

        // Wrap-around. The reference bin has to lie in N/4..3N/4, so with the
        // standard sync word (+16) the second sync bin never wraps; sync word
        // 0x34 (+32) does at the top of the band: (96+32) mod 128 = 0.
        sync_word = 8'h34;
        pulse_stream_reset();
        send_run(32'd96, 12, 64'd100);
        send_symbol(32'd96, 64'd1300, 1'b1);
        send_symbol(32'd0, 64'd1400, 1'b1);
        expect_bit("straddle sync detected across the bin wrap", edge_detected, 1'b1);
        sync_word = 8'h12;

        // Same +/-1 bin tolerance as the generated rule.
        pulse_stream_reset();
        send_symbol(32'd64, 64'd100, 1'b1);
        send_symbol(32'd65, 64'd200, 1'b1);
        send_symbol(32'd63, 64'd300, 1'b1);
        send_symbol(32'd64, 64'd400, 1'b1);
        send_symbol(32'd64, 64'd500, 1'b1);
        send_symbol(32'd65, 64'd600, 1'b1);
        send_symbol(32'd64, 64'd700, 1'b1);
        send_symbol(32'd63, 64'd800, 1'b1);
        send_symbol(32'd64, 64'd900, 1'b1);
        send_symbol(32'd64, 64'd1000, 1'b1);
        send_symbol(32'd65, 64'd1100, 1'b1);
        send_symbol(32'd64, 64'd1200, 1'b1);
        send_symbol(32'd63, 64'd1300, 1'b1);
        send_symbol(32'd81, 64'd1400, 1'b1);
        expect_bit("straddle sync tolerates +/-1 bin jitter", edge_detected, 1'b1);

        // A different configured sync word moves both sync slots.
        sync_word = 8'h34;
        pulse_stream_reset();
        send_run(32'd40, 12, 64'd100);
        send_symbol(32'd40, 64'd1300, 1'b1);
        send_symbol(32'd72, 64'd1400, 1'b1);
        expect_bit("straddle sync follows the configured sync word (0x34)", edge_detected, 1'b1);
        pulse_stream_reset();
        send_run(32'd40, 12, 64'd100);
        send_symbol(32'd40, 64'd1300, 1'b1);
        send_symbol(32'd56, 64'd1400, 1'b1);
        expect_bit("0x34: a 0x12-shaped second slot is rejected", edge_detected, 1'b0);
        sync_word = 8'h12;

        // Silence. With no signal the correlator's spectrum is exactly zero and
        // its argmax is bin 0, so a run of zeros is free. The first, partial
        // window of the next packet then only has to land on 16 +/- 1 for the
        // straddle rule to fire: on the board this false detection hit 5 of
        // the first 12 rescued packets, armed the trace inside the preamble
        // and garbled the joint estimate.
        pulse_stream_reset();
        symbol_peak = 16'd0;
        send_run(32'd0, 9, 64'd100);
        symbol_peak = 16'd1;
        send_symbol(32'd16, 64'd1000, 1'b1);
        expect_bit("silence then an onset decision of 16 is not a detection", edge_detected, 1'b0);
        expect_bit("silence then an onset decision of 16 is not a straddle", edge_straddle, 1'b0);
        symbol_peak = 16'd100;
        // Same with the onset decision landing exactly one bin off.
        pulse_stream_reset();
        symbol_peak = 16'd0;
        send_run(32'd0, 9, 64'd100);
        symbol_peak = 16'd1;
        send_symbol(32'd17, 64'd1000, 1'b1);
        expect_bit("silence then 17 is not a detection", edge_detected, 1'b0);
        symbol_peak = 16'd100;

        // A run of zeros WITH a signal (bin 0 is far from half a symbol) is
        // outside the straddle band as well.
        pulse_stream_reset();
        send_run(32'd0, 9, 64'd100);
        send_symbol(32'd16, 64'd1000, 1'b1);
        expect_bit("a bin-0 run with signal then 16 is outside the band", edge_straddle, 1'b0);

        // One silent decision anywhere in the ten-symbol window is enough to
        // refuse a straddle acceptance, even at a bin inside the band.
        pulse_stream_reset();
        send_run(32'd64, 5, 64'd100);
        symbol_peak = 16'd0;
        send_symbol(32'd64, 64'd600, 1'b1);
        symbol_peak = 16'd100;
        send_run(32'd64, 6, 64'd700);
        send_symbol(32'd64, 64'd1300, 1'b1);
        send_symbol(32'd80, 64'd1400, 1'b1);
        expect_bit("a silent decision inside the window blocks the straddle path", edge_detected, 1'b0);

        // The band edges: N/4 = 32 and 3N/4 = 96 inclusive.
        pulse_stream_reset();
        send_run(32'd31, 12, 64'd100);
        send_symbol(32'd31, 64'd1300, 1'b1);
        send_symbol(32'd47, 64'd1400, 1'b1);
        expect_bit("straddle at reference bin 31 is below the band", edge_detected, 1'b0);
        pulse_stream_reset();
        send_run(32'd32, 12, 64'd100);
        send_symbol(32'd32, 64'd1300, 1'b1);
        send_symbol(32'd48, 64'd1400, 1'b1);
        expect_bit("straddle at reference bin 32 is inside the band", edge_detected, 1'b1);
        pulse_stream_reset();
        send_run(32'd96, 12, 64'd100);
        send_symbol(32'd96, 64'd1300, 1'b1);
        send_symbol(32'd112, 64'd1400, 1'b1);
        expect_bit("straddle at reference bin 96 is inside the band", edge_detected, 1'b1);
        pulse_stream_reset();
        send_run(32'd97, 12, 64'd100);
        send_symbol(32'd97, 64'd1300, 1'b1);
        send_symbol(32'd113, 64'd1400, 1'b1);
        expect_bit("straddle at reference bin 97 is above the band", edge_detected, 1'b0);

        // M9: the split preamble. The decisions below are the board's own,
        // read from the decision-history ring over three of the seven misses
        // of 2026-09-24 (the RTL replayed at the board's phase gives the same
        // sixteen). The preamble peak split into lobes one bin either side of
        // the truth, so decisions jump by 2 and the +/-1 rules never fire.
        // 163349Z: [52, 51 x8, 53, 53, 53, 52, 60, 69] -- the ordinary form.
        pulse_stream_reset();
        send_symbol(32'd52, 64'd100, 1'b1);
        send_run(32'd51, 8, 64'd200);
        send_symbol(32'd53, 64'd1000, 1'b1);
        send_symbol(32'd53, 64'd1100, 1'b1);
        send_symbol(32'd53, 64'd1200, 1'b1);
        send_symbol(32'd52, 64'd1300, 1'b1);
        send_symbol(32'd60, 64'd1400, 1'b1);
        expect_bit("split miss 163349Z: no detection yet at sync1", edge_detected, 1'b0);
        send_symbol(32'd69, 64'd1500, 1'b1);
        expect_bit("split miss 163349Z is detected", edge_detected, 1'b1);
        expect_bit("split miss 163349Z: split path", edge_split, 1'b1);
        expect_bit("split miss 163349Z: not the straddle form", edge_straddle, 1'b0);
        expect_u16("split miss 163349Z: preamble bin is the lobe centre", edge_bin, 16'd52);
        expect_u16("split miss 163349Z: chips_to_boundary = N - bin", edge_chips, 16'd76);
        // 180856Z: [56, 55 x8, 57, 57, 55, 56, 72, 73] -- split AND the first
        // sync symbol read as one more preamble bin (straddle form).
        pulse_stream_reset();
        send_symbol(32'd56, 64'd100, 1'b1);
        send_run(32'd55, 8, 64'd200);
        send_symbol(32'd57, 64'd1000, 1'b1);
        send_symbol(32'd57, 64'd1100, 1'b1);
        send_symbol(32'd55, 64'd1200, 1'b1);
        send_symbol(32'd56, 64'd1300, 1'b1);
        send_symbol(32'd72, 64'd1400, 1'b1);
        expect_bit("split miss 180856Z (straddle form) is detected", edge_detected, 1'b1);
        expect_bit("split miss 180856Z: split path", edge_split, 1'b1);
        expect_bit("split miss 180856Z: raises the straddle flag", edge_straddle, 1'b1);
        expect_u16("split miss 180856Z: preamble bin is the lobe centre", edge_bin, 16'd56);
        send_symbol(32'd73, 64'd1500, 1'b1);
        expect_bit("split miss 180856Z: fires once, not again next symbol", edge_detected, 1'b0);
        // 164405Z: [62, 61 x4, 63 x7, 62, 78, 79] -- straddle form again.
        pulse_stream_reset();
        send_symbol(32'd62, 64'd100, 1'b1);
        send_run(32'd61, 4, 64'd200);
        send_run(32'd63, 7, 64'd600);
        send_symbol(32'd62, 64'd1300, 1'b1);
        send_symbol(32'd78, 64'd1400, 1'b1);
        expect_bit("split miss 164405Z (straddle form) is detected", edge_detected, 1'b1);
        expect_bit("split miss 164405Z: split path", edge_split, 1'b1);
        // A deviation of 3 is not a split: rejected.
        pulse_stream_reset();
        send_run(32'd51, 5, 64'd100);
        send_run(32'd54, 3, 64'd600);
        send_symbol(32'd51, 64'd900, 1'b1);
        send_symbol(32'd59, 64'd1000, 1'b1);
        send_symbol(32'd67, 64'd1100, 1'b1);
        expect_bit("a preamble spread of 3 bins is not accepted", edge_detected, 1'b0);
        // Silence gives the split path nothing: zeros, then an onset at 8
        // and 16. (That exact pair is the generated rule's own pattern with
        // reference 0, and the generated rule does fire on it -- two
        // coincidences after silence, its long-known weakness; only the split
        // path's refusal is asserted here.)
        pulse_stream_reset();
        symbol_peak = 16'd0;
        send_run(32'd0, 8, 64'd100);
        symbol_peak = 16'd1;
        send_symbol(32'd8, 64'd900, 1'b1);
        send_symbol(32'd16, 64'd1000, 1'b1);
        expect_bit("silence then 8, 16 is not a split detection", edge_split, 1'b0);
        // Nor zeros then a split-looking run inside the band: the silent
        // decisions in the window refuse it.
        pulse_stream_reset();
        symbol_peak = 16'd0;
        send_run(32'd0, 4, 64'd100);
        symbol_peak = 16'd100;
        send_run(32'd51, 4, 64'd500);
        send_symbol(32'd51, 64'd900, 1'b1);
        send_symbol(32'd59, 64'd1000, 1'b1);
        send_symbol(32'd67, 64'd1100, 1'b1);
        expect_bit("silent decisions in the window refuse the split path", edge_split, 1'b0);
        symbol_peak = 16'd100;
        // Outside the reference band (N/4..3N/4) the split path stays shut.
        pulse_stream_reset();
        send_run(32'd30, 4, 64'd100);
        send_run(32'd28, 4, 64'd500);
        send_symbol(32'd38, 64'd900, 1'b1);
        send_symbol(32'd46, 64'd1000, 1'b1);
        expect_bit("a split pattern at reference bin 30 is below the band", edge_detected, 1'b0);
        // An ordinary packet is still for the generated rule, not this path.
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd72, 64'd1300, 1'b1);
        send_symbol(32'd80, 64'd1400, 1'b1);
        expect_bit("an ordinary packet is detected", edge_detected, 1'b1);
        expect_bit("an ordinary packet does not use the split path", edge_split, 1'b0);
        expect_bit("an ordinary packet does not use the early-sync path", edge_early, 1'b0);

        // Early sync: the packet half a symbol from the window, the tie
        // window (last preamble chirp + first sync chirp) read as sync. These
        // are the decisions of tb_lora_joint_grid_completion at grid_phase
        // 512 with CFO +0.000418 cycles/sample: [101, 101, 64 x7, 72, 72, 81]
        // (at CFO 0 the tie went to the preamble: 64 x8, 72, 80).
        pulse_stream_reset();
        send_run(32'd101, 2, 64'd100);
        send_run(32'd64, 7, 64'd300);
        send_symbol(32'd72, 64'd1000, 1'b1);
        send_symbol(32'd72, 64'd1100, 1'b1);
        expect_bit("early sync: no detection yet at the true first sync", edge_detected, 1'b0);
        send_symbol(32'd81, 64'd1200, 1'b1);
        expect_bit("early sync (tie window read as sync) is detected", edge_detected, 1'b1);
        expect_bit("early sync: early-sync path", edge_early, 1'b1);
        expect_bit("early sync: not the split path", edge_split, 1'b0);
        expect_bit("early sync: no straddle flag (generated rule's windows)", edge_straddle, 1'b0);
        expect_u16("early sync: preamble bin is the reference", edge_bin, 16'd64);
        expect_u16("early sync: chips_to_boundary = N - bin", edge_chips, 16'd64);
        send_symbol(32'd90, 64'd1300, 1'b1);
        expect_bit("early sync: fires once, not again next symbol", edge_detected, 1'b0);
        // Outside the reference band it stays shut.
        pulse_stream_reset();
        send_run(32'd101, 2, 64'd100);
        send_run(32'd20, 7, 64'd300);
        send_symbol(32'd28, 64'd1000, 1'b1);
        send_symbol(32'd28, 64'd1100, 1'b1);
        send_symbol(32'd36, 64'd1200, 1'b1);
        expect_bit("an early-sync pattern at reference bin 20 is below the band", edge_detected, 1'b0);
        // Silent decisions in the window refuse it.
        pulse_stream_reset();
        symbol_peak = 16'd0;
        send_run(32'd64, 2, 64'd100);
        symbol_peak = 16'd100;
        send_run(32'd64, 5, 64'd300);
        send_symbol(32'd72, 64'd1000, 1'b1);
        send_symbol(32'd72, 64'd1100, 1'b1);
        send_symbol(32'd80, 64'd1200, 1'b1);
        expect_bit("silent decisions in the window refuse the early-sync path", edge_early, 1'b0);

        // Things that must NOT be detected.
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd64, 64'd1300, 1'b1);
        send_symbol(32'd72, 64'd1400, 1'b1);
        expect_bit("extra preamble bin then +8 (not +16) is rejected", edge_detected, 1'b0);
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd64, 64'd1300, 1'b1);
        send_symbol(32'd64, 64'd1400, 1'b1);
        expect_bit("a longer preamble alone is not a packet", edge_detected, 1'b0);
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd72, 64'd1300, 1'b1);
        send_symbol(32'd72, 64'd1400, 1'b1);
        expect_bit("+8 then +8 is rejected", edge_detected, 1'b0);
        pulse_stream_reset();
        send_run(32'd64, 12, 64'd100);
        send_symbol(32'd96, 64'd1300, 1'b1);
        send_symbol(32'd80, 64'd1400, 1'b1);
        expect_bit("an unrelated first sync slot is rejected", edge_detected, 1'b0);

        // A stream reset must clear the straddle history too: eight symbols
        // before the reset plus a short run after it cannot make a window.
        pulse_stream_reset();
        send_run(32'd64, 8, 64'd100);
        pulse_stream_reset();
        send_run(32'd64, 3, 64'd2000);
        send_symbol(32'd64, 64'd2300, 1'b1);
        send_symbol(32'd80, 64'd2400, 1'b1);
        expect_bit("stream reset clears the straddle history", edge_detected, 1'b0);

        // Missing timestamp sideband on a real detector event must be visible as
        // an integration error and must not emit a stale timestamp.
        pulse_stream_reset();
        for (i = 0; i < 7; i = i + 1)
            send_symbol(32'd0, 64'd3000 + i*64'd100, 1'b1);
        send_symbol(32'd0, 64'd3700, 1'b0);
        expect_bit("generated detector still sees preamble without timestamp", edge_preamble, 1'b1);
        expect_bit("missing timestamp raises alignment error", alignment_error, 1'b1);
        expect_bit("missing timestamp emits no preamble timestamp", preamble_start_valid, 1'b0);

        @(negedge clk);
        symbol_index = 32'h0001_0000;
        symbol_valid = 1'b1;
        #1;
        expect_bit("upper symbol-index bits are not silently truncated", symbol_index_width_error, 1'b1);
        symbol_valid = 1'b0;
        #1;
        expect_bit("symbol-index width error follows valid input", symbol_index_width_error, 1'b0);

        if (errors == 0)
            $display("PASS tb_lora_detector_timestamp_path");
        else begin
            $display("FAIL tb_lora_detector_timestamp_path errors=%0d", errors);
            $fatal(1);
        end

        $finish;
    end
endmodule
