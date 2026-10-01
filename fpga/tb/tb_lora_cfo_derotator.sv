// lora_cfo_derotator: bit-exact pass-through when off, a correct rotation when on,
// and every sideband signal kept in step with its sample.
`timescale 1ns/1ps

module tb_lora_cfo_derotator;
    localparam real PI = 3.14159265358979323846;
    localparam integer ITER = 16;
    localparam integer LAT = ITER + 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;

    reg signed [15:0] in_re = 0, in_im = 0;
    reg in_valid = 0, in_rv = 0, in_sr = 0;
    reg [31:0] in_rs = 0;
    reg load = 0, clear = 0;
    reg signed [31:0] cfo_q12 = 0;
    wire signed [15:0] out_re, out_im;
    wire out_valid, out_rv, out_sr, rotating;
    wire [31:0] out_rs;

    lora_cfo_derotator #(.ITERATIONS(ITER)) dut (
        .clk(clk), .resetn(resetn),
        .in_re(in_re), .in_im(in_im), .in_valid(in_valid),
        .in_resync_valid(in_rv), .in_resync_skip(in_rs), .in_stream_reset(in_sr),
        .load(load), .cfo_q12(cfo_q12), .clear(clear),
        .out_re(out_re), .out_im(out_im), .out_valid(out_valid),
        .out_resync_valid(out_rv), .out_resync_skip(out_rs), .out_stream_reset(out_sr),
        .rotating(rotating)
    );

    integer errors = 0;
    integer max_err = 0;

    // Expected outputs, queued at the input and compared LAT clocks later.
    reg signed [15:0] exp_re [0:4095];
    reg signed [15:0] exp_im [0:4095];
    reg exp_valid [0:4095];
    reg exp_rv [0:4095];
    reg [31:0] exp_rs [0:4095];
    reg exp_exact [0:4095];
    integer t_in = 0;
    integer t_out = 0;
    reg checking = 0;

    always @(posedge clk) begin
        #1;
        if (checking) begin
            if (t_in - t_out == LAT) begin
                if (out_valid !== exp_valid[t_out] || out_rv !== exp_rv[t_out] || out_rs !== exp_rs[t_out]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL sideband at %0d: valid %0d/%0d rv %0d/%0d", t_out, out_valid, exp_valid[t_out], out_rv, exp_rv[t_out]);
                end
                if (exp_valid[t_out]) begin
                    if (exp_exact[t_out]) begin
                        if (out_re !== exp_re[t_out] || out_im !== exp_im[t_out]) begin
                            errors = errors + 1;
                            if (errors < 10) $display("FAIL bypass not exact at %0d: %0d,%0d vs %0d,%0d", t_out, out_re, out_im, exp_re[t_out], exp_im[t_out]);
                        end
                    end else begin
                        if ((out_re - exp_re[t_out]) > max_err) max_err = out_re - exp_re[t_out];
                        if ((exp_re[t_out] - out_re) > max_err) max_err = exp_re[t_out] - out_re;
                        if ((out_im - exp_im[t_out]) > max_err) max_err = out_im - exp_im[t_out];
                        if ((exp_im[t_out] - out_im) > max_err) max_err = exp_im[t_out] - out_im;
                    end
                end
                t_out = t_out + 1;
            end
        end
    end

    // Model of the phase the DUT applies to the next valid sample.
    reg [31:0] m_acc = 0;
    reg [31:0] m_inc = 0;
    reg m_on = 0;

    task automatic drive(input real amp, input real ph, input bit valid, input bit rv, input [31:0] rs);
        real a, xr, xi, rr, ri;
        begin
            @(negedge clk);
            xr = amp * $cos(ph); xi = amp * $sin(ph);
            in_re = $rtoi(xr); in_im = $rtoi(xi);
            in_valid = valid; in_rv = rv; in_rs = rs;
            exp_valid[t_in] = valid; exp_rv[t_in] = rv; exp_rs[t_in] = rs;
            if (m_on) begin
                a = 2.0 * PI * $itor(m_acc) / 4294967296.0;
                rr = in_re * $cos(a) - in_im * $sin(a);
                ri = in_re * $sin(a) + in_im * $cos(a);
                exp_re[t_in] = $rtoi(rr >= 0 ? rr + 0.5 : rr - 0.5);
                exp_im[t_in] = $rtoi(ri >= 0 ? ri + 0.5 : ri - 0.5);
                exp_exact[t_in] = 0;
                if (valid) m_acc = m_acc + m_inc;
            end else begin
                exp_re[t_in] = in_re; exp_im[t_in] = in_im; exp_exact[t_in] = 1;
            end
            t_in = t_in + 1;
        end
    endtask

    task automatic do_load(input signed [31:0] c);
        begin
            @(negedge clk);
            cfo_q12 = c; load = 1;
            in_valid = 0; in_rv = 0;
            exp_valid[t_in] = 0; exp_rv[t_in] = 0; exp_rs[t_in] = in_rs; exp_exact[t_in] = 1;
            exp_re[t_in] = in_re; exp_im[t_in] = in_im;
            t_in = t_in + 1;
            @(negedge clk);
            load = 0;
            m_on = 1; m_acc = 0; m_inc = c <<< 7;
            exp_valid[t_in] = 0; exp_rv[t_in] = 0; exp_rs[t_in] = in_rs; exp_exact[t_in] = 1;
            exp_re[t_in] = in_re; exp_im[t_in] = in_im;
            t_in = t_in + 1;
        end
    endtask

    integer i;
    initial begin
        repeat (4) @(posedge clk);
        resetn = 1;
        @(negedge clk);
        // prime the queue for the idle clocks before the first sample
        for (i = 0; i < LAT; i = i + 1) begin
            exp_valid[i] = 0; exp_rv[i] = 0; exp_rs[i] = 0; exp_exact[i] = 1; exp_re[i] = 0; exp_im[i] = 0;
        end
        t_in = 0; t_out = 0;
        checking = 1;

        // 1. off: bit-exact pass-through, sidebands in step, arbitrary valid gaps
        for (i = 0; i < 200; i = i + 1)
            drive(20000.0, 0.37 * i, (i % 3) != 1, (i == 50), (i == 50) ? 32'd23 : 32'd0);

        // 2. on, the board's CFO (-3.4 samples displacement)
        do_load(-32'sd13926);
        for (i = 0; i < 400; i = i + 1)
            drive(15000.0, 0.11 * i, 1'b1, (i == 100), (i == 100) ? 32'd17 : 32'd0);
        // 3. a large positive CFO so the angle sweeps every quadrant quickly
        do_load(32'sd1048576);
        for (i = 0; i < 400; i = i + 1)
            drive(25000.0, -0.05 * i, (i % 5) != 0, 1'b0, 32'd0);
        // 4. a large negative CFO
        do_load(-32'sd917504);
        for (i = 0; i < 400; i = i + 1)
            drive(30000.0, 0.2 * i, 1'b1, 1'b0, 32'd0);

        // 5. clear: back to exact pass-through
        @(negedge clk);
        clear = 1; in_valid = 0; in_rv = 0;
        exp_valid[t_in] = 0; exp_rv[t_in] = 0; exp_rs[t_in] = 0; exp_exact[t_in] = 1; exp_re[t_in] = in_re; exp_im[t_in] = in_im;
        t_in = t_in + 1;
        @(negedge clk);
        clear = 0; m_on = 0;
        exp_valid[t_in] = 0; exp_rv[t_in] = 0; exp_rs[t_in] = 0; exp_exact[t_in] = 1; exp_re[t_in] = in_re; exp_im[t_in] = in_im;
        t_in = t_in + 1;
        for (i = 0; i < 100; i = i + 1)
            drive(12000.0, 0.9 * i, 1'b1, 1'b0, 32'd0);
        // drain
        for (i = 0; i < LAT + 2; i = i + 1)
            drive(0.0, 0.0, 1'b0, 1'b0, 32'd0);

        if (max_err > 3) begin
            errors = errors + 1;
            $display("FAIL rotation error %0d LSB", max_err);
        end
        if (errors == 0)
            $display("PASS tb_lora_cfo_derotator max_rotation_error_lsb=%0d", max_err);
        else begin
            $display("FAIL tb_lora_cfo_derotator errors=%0d max_err=%0d", errors, max_err);
            $fatal(1);
        end
        $finish;
    end
endmodule
