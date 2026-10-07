`timescale 1ns/1ps
// Simulation-only header: compile explicitly with xvlog; do not add as synthesis RTL.
`include "counts.vh"
module directed_tb;
reg clk = 0, resetn = 0;
always #5 clk = ~clk;
wire ie, de;
wire [3:0] iw, dw, we;
wire [31:0] ia, idata, da, dd, pc, value;
wire [4:0] rd;
reg [31:0] ir = 0, dr = 0;
reg [31:0] imem [0:`WORDS-1];
reg [31:0] dmem [0:1023];
reg [71:0] expected [0:`COMMITS-1];
integer i, lane, commits = 0, stores = 0, cycles = 0;
mycpu_top dut(.clk(clk), .resetn(resetn),
 .inst_sram_en(ie), .inst_sram_we(iw), .inst_sram_addr(ia),
 .inst_sram_wdata(idata), .inst_sram_rdata(ir),
 .data_sram_en(de), .data_sram_we(dw), .data_sram_addr(da),
 .data_sram_wdata(dd), .data_sram_rdata(dr),
 .debug_wb_pc(pc), .debug_wb_rf_we(we), .debug_wb_rf_wnum(rd), .debug_wb_rf_wdata(value));
initial begin
 $readmemh("program.hex", imem);
 $readmemh("expected.hex", expected);
 for(i=0;i<1024;i=i+1) dmem[i]=0;
 repeat(8) @(negedge clk);
 resetn=1;
end
always @(posedge clk) begin
 cycles = cycles + 1;
 if(cycles > 20000) $fatal(1,"FAIL timeout");
 if(!resetn && (ie || de || |dw || |we)) $fatal(1,"FAIL reset side effect");
 if(ie) ir <= imem[(ia-32'h1c000000)>>2];
 if(de) begin
   dr <= dmem[da[11:2]];
   for(lane=0;lane<4;lane=lane+1)
     if(dw[lane]) dmem[da[11:2]][lane*8+:8] <= dd[lane*8+:8];
   if(|dw) stores = stores + 1;
 end
 if(|dw && !de) $fatal(1,"FAIL write without enable");
 if(resetn && |we && rd != 0) begin
   if(commits >= `COMMITS) $fatal(1,"FAIL extra commit");
   if({pc,3'b0,rd,value} !== expected[commits])
     $fatal(1,"FAIL commit %0d actual=%h expected=%h", commits, {pc,3'b0,rd,value},expected[commits]);
   commits = commits + 1;
   if(commits == `COMMITS) begin
     if(stores != `STORES) $fatal(1,"FAIL stores %0d expected %0d",stores,`STORES);
     $display("PASS directed: %0d commits, %0d stores, %0d cycles",commits,stores,cycles);
     $finish;
   end
 end
end
endmodule
