`timescale 1ns/1ps
module tb_lora_search_stride;
 reg clk=0; always #5 clk=~clk;
 reg resetn=0,reset=0,start=0,miss=0;
 reg [63:0] center=100, wanted=101;
 wire [1:0] req,busy,valid,boundary,readmiss;
 wire [63:0] count[0:1],response[0:1],peak[0:1];
 wire [31:0] before_p[0:1],power_p[0:1],after_p[0:1];
 reg [1:0] response_valid=0;
 reg signed [15:0] iq[0:1];
 reg [63:0] returned[0:1];
 integer k,delta,timeout;
 reg [1:0] seen=0,bad=0;
 reg [63:0] saved_peak[0:1];
 reg [31:0] saved_b[0:1],saved_p[0:1],saved_a[0:1];
 genvar g;
 generate for(g=0;g<2;g=g+1) begin:scan
  lora_matched_filter_search #(.REF_SAMPLES(1),.SEARCH_RADIUS(8),.POWER_SHIFT(0),
   .REQUEST_ON_RESPONSE(1),.COARSE_STRIDE(g+1)) dut(
   .clk(clk),.resetn(resetn),.stream_reset(reset),.start(start),.coarse_start_count(center),
   .iq_read_req(req[g]),.iq_read_sample_count(count[g]),.iq_read_re(iq[g]),.iq_read_im(16'sd0),
   .iq_read_sample_count_out(returned[g]),.iq_read_valid(response_valid[g]),.iq_read_miss(miss),
   .reference_re(16'sd1),.reference_im(16'sd0),.busy(busy[g]),
   .magnitude_before(before_p[g]),.magnitude_peak(power_p[g]),.magnitude_after(after_p[g]),
   .peak_sample_count(peak[g]),.triplet_valid(valid[g]),.peak_boundary_error(boundary[g]),
   .mac_read_miss_error(readmiss[g]));
 end endgenerate
 always @(posedge clk) begin
  for(k=0;k<2;k=k+1) begin
   response_valid[k]<=req[k]; returned[k]<=count[k];
   delta=$signed(count[k]-wanted); if(delta<0) delta=-delta;
   iq[k]<=delta<10 ? 10-delta : 0;
  end
  #1;
  for(k=0;k<2;k=k+1) begin
   if(valid[k]) begin seen[k]=1; saved_peak[k]=peak[k];
    saved_b[k]=before_p[k];saved_p[k]=power_p[k];saved_a[k]=after_p[k]; end
   if(boundary[k] || readmiss[k]) bad[k]=1;
  end
 end
 task launch;
  begin seen=0;bad=0;@(negedge clk);start=1;@(negedge clk);start=0; end
 endtask
 task check_peak(input [63:0] location);
  begin wanted=location;launch();timeout=0;
   while(seen!=3 && timeout<1000) begin @(negedge clk);timeout=timeout+1; end
   if(seen!=3 || bad!=0) $fatal(1,"missing smooth peak %0d",location);
   for(integer j=0;j<2;j=j+1)
    if(saved_peak[j]!=wanted || saved_b[j]!=81 || saved_p[j]!=100 || saved_a[j]!=81)
     $fatal(1,"scan %0d did not return the unit-lag triplet",j);
   repeat(3) @(negedge clk);
  end
 endtask
 initial begin
  repeat(3) @(negedge clk);resetn=1;
  check_peak(101);check_peak(100);check_peak(95);check_peak(105);
  wanted=92;launch();repeat(300) @(negedge clk);
  if(bad!=3 || seen!=0 || busy!=0) $fatal(1,"boundary was not rejected");
  wanted=101;miss=1;launch();repeat(30) @(negedge clk);
  if(bad!=3 || seen!=0 || busy!=0) $fatal(1,"read miss was not aborted");
  miss=0;check_peak(101);
  launch();repeat(3) @(negedge clk);reset=1;@(negedge clk);reset=0;
  repeat(3) @(negedge clk);if(busy!=0 || valid!=0) $fatal(1,"reset failed");
  check_peak(99);
  $display("PASS tb_lora_search_stride full/sparse exact unit-lag triplets");$finish;
 end
 initial begin #100000;$fatal(1,"stride timeout");end
endmodule
