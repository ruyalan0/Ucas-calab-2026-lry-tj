`timescale 1ns/1ps
`default_nettype none
// 【实践15新增】类SRAM 2x1 AXI桥；单个在途事务，数据端优先。
module sram_axi_bridge(
    input wire aclk,
    input wire aresetn,
    output wire [3:0] arid,
    output wire [31:0] araddr,
    output wire [7:0] arlen,
    output wire [2:0] arsize,
    output wire [1:0] arburst,
    output wire [1:0] arlock,
    output wire [3:0] arcache,
    output wire [2:0] arprot,
    output wire arvalid,
    input wire arready,
    input wire [3:0] rid,
    input wire [31:0] rdata,
    input wire [1:0] rresp,
    input wire rlast,
    input wire rvalid,
    output wire rready,
    output wire [3:0] awid,
    output wire [31:0] awaddr,
    output wire [7:0] awlen,
    output wire [2:0] awsize,
    output wire [1:0] awburst,
    output wire [1:0] awlock,
    output wire [3:0] awcache,
    output wire [2:0] awprot,
    output wire awvalid,
    input wire awready,
    output wire [3:0] wid,
    output wire [31:0] wdata,
    output wire [3:0] wstrb,
    output wire wlast,
    output wire wvalid,
    input wire wready,
    input wire [3:0] bid,
    input wire [1:0] bresp,
    input wire bvalid,
    output wire bready,
    input wire inst_sram_req,
    input wire inst_sram_wr,
    input wire [1:0] inst_sram_size,
    input wire [3:0] inst_sram_wstrb,
    input wire [31:0] inst_sram_addr,
    input wire [31:0] inst_sram_wdata,
    output wire inst_sram_addr_ok,
    output wire inst_sram_data_ok,
    output wire [31:0] inst_sram_rdata,
    input wire data_sram_req,
    input wire data_sram_wr,
    input wire [1:0] data_sram_size,
    input wire [3:0] data_sram_wstrb,
    input wire [31:0] data_sram_addr,
    input wire [31:0] data_sram_wdata,
    output wire data_sram_addr_ok,
    output wire data_sram_data_ok,
    output wire [31:0] data_sram_rdata
);
// 【实践15新增】地址本地接收后锁存；AXI反压期间不再依赖CPU请求。
// 全局串行化直到R/B响应，保证写后读顺序，禁止写到读前递。
localparam IDLE=3'd0, RD_ADDR=3'd1, RD_DATA=3'd2,
           WR_SEND=3'd3, WR_RESP=3'd4, COMPLETE=3'd5;
reg [2:0] state;
reg owner_data;
reg [31:0] saved_addr, saved_wdata, saved_rdata;
reg [1:0] saved_size;
reg [3:0] saved_strb;
reg aw_done, w_done;
wire take_data = data_sram_req;
assign data_sram_addr_ok = aresetn && state==IDLE;
assign inst_sram_addr_ok = aresetn && state==IDLE && !take_data;
assign data_sram_data_ok = aresetn && state==COMPLETE && owner_data;
assign inst_sram_data_ok = aresetn && state==COMPLETE && !owner_data;
assign data_sram_rdata = saved_rdata;
assign inst_sram_rdata = saved_rdata;
// 【实践15新增】单拍AXI3事务：取指ID=0，数据读写ID=1，宽度沿用CPU字节/半字/字请求。
assign arid = owner_data ? 4'd1 : 4'd0;
assign araddr = saved_addr;
assign arlen = 8'd0;
assign arsize = {1'b0,saved_size};
assign arburst = 2'b01;
assign arlock = 2'b00;
assign arcache = 4'b0;
assign arprot = 3'b0;
assign arvalid = aresetn && state==RD_ADDR;
assign rready = aresetn && state==RD_DATA;
assign awid = 4'd1;
assign awaddr = saved_addr;
assign awlen = 8'd0;
assign awsize = {1'b0,saved_size};
assign awburst = 2'b01;
assign awlock = 2'b00;
assign awcache = 4'b0;
assign awprot = 3'b0;
assign awvalid = aresetn && state==WR_SEND && !aw_done;
assign wid = 4'd1;
assign wdata = saved_wdata;
assign wstrb = saved_strb;
assign wlast = 1'b1;
assign wvalid = aresetn && state==WR_SEND && !w_done;
assign bready = aresetn && state==WR_RESP;
// 【实践15新增】AW与W分别记录握手，任意先后顺序均只发送一次；B响应后才通知store完成。
// R数据先锁存再产生类SRAM完成脉冲；CPU冲刷不会撤销已经接受的AXI事务。
always @(posedge aclk) begin
    if (!aresetn) begin
        state <= IDLE;
        owner_data <= 1'b0;
        saved_addr <= 32'b0;
        saved_wdata <= 32'b0;
        saved_rdata <= 32'b0;
        saved_size <= 2'b0;
        saved_strb <= 4'b0;
        aw_done <= 1'b0;
        w_done <= 1'b0;
    end else begin
        case (state)
        IDLE: begin
            if (data_sram_req || inst_sram_req) begin
                owner_data <= take_data;
                saved_addr <= take_data ? data_sram_addr : inst_sram_addr;
                saved_size <= take_data ? data_sram_size : inst_sram_size;
                saved_wdata <= data_sram_wdata;
                saved_strb <= data_sram_wstrb;
                aw_done <= 1'b0;
                w_done <= 1'b0;
                state <= take_data && data_sram_wr ? WR_SEND : RD_ADDR;
            end
        end
        RD_ADDR: if (arvalid && arready) state <= RD_DATA;
        RD_DATA: if (rvalid && rready && rlast) begin
            saved_rdata <= rdata;
            state <= COMPLETE;
        end
        WR_SEND: begin
            if (awvalid && awready) aw_done <= 1'b1;
            if (wvalid && wready) w_done <= 1'b1;
            if ((aw_done || (awvalid && awready)) &&
                (w_done || (wvalid && wready))) state <= WR_RESP;
        end
        WR_RESP: if (bvalid && bready) state <= COMPLETE;
        COMPLETE: state <= IDLE;
        default: state <= IDLE;
        endcase
    end
end
// 【实践15新增】本实验无总线错误异常；rid/rresp/bid/bresp由SoC保证为对应单拍成功响应。
endmodule
`default_nettype wire
