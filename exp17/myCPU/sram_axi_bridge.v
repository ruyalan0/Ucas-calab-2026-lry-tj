`timescale 1ns/1ps
`default_nettype none
// 类SRAM 2x1 AXI桥；单个在途事务，数据端优先。
module sram_axi_bridge(
    // 【实践15新增】桥与AXI接口共用时钟和低有效复位。
    input wire aclk,
    input wire aresetn,
    // AR通道发送取指或数据读的地址、宽度与事务属性。
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
    // R通道接收读数据，完成前由桥保存返回结果。
    input wire [3:0] rid,
    input wire [31:0] rdata,
    input wire [1:0] rresp,
    input wire rlast,
    input wire rvalid,
    output wire rready,
    // AW通道发送store地址，与W通道独立握手。
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
    // W通道发送store数据、字节写选通和最后一拍标志。
    output wire [3:0] wid,
    output wire [31:0] wdata,
    output wire [3:0] wstrb,
    output wire wlast,
    output wire wvalid,
    input wire wready,
    // B通道接收写响应，确认store事务结束。
    input wire [3:0] bid,
    input wire [1:0] bresp,
    input wire bvalid,
    output wire bready,
    // 取指类SRAM从端，分别返回地址接受和数据完成通知。
    input wire inst_sram_req,
    input wire inst_sram_wr,
    input wire [1:0] inst_sram_size,
    input wire [3:0] inst_sram_wstrb,
    input wire [31:0] inst_sram_addr,
    input wire [31:0] inst_sram_wdata,
    output wire inst_sram_addr_ok,
    output wire inst_sram_data_ok,
    output wire [31:0] inst_sram_rdata,
    // 访存类SRAM从端，接收load/store及访问宽度、字节写选通。
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
// 【实践15新增】串行状态机依次处理地址、数据、响应和完成，每次只保留一个事务。
localparam IDLE=3'd0, RD_ADDR=3'd1, RD_DATA=3'd2,
           WR_SEND=3'd3, WR_RESP=3'd4, COMPLETE=3'd5;
reg [2:0] state;
// 【实践15新增】记录事务来自取指端还是数据端，用于选择响应ID和完成通知。
reg owner_data;
// 【实践15新增】锁存请求地址、写数据、访问宽度、写选通和读返回数据，承受AXI反压。
reg [31:0] saved_addr, saved_wdata, saved_rdata;
reg [1:0] saved_size;
reg [3:0] saved_strb;
// 【实践15新增】分别记录AW、W是否已经握手，避免重复发送已被接收的地址或数据。
reg aw_done, w_done;
// 【实践15新增】数据端请求优先，存在访存请求时暂不接收取指请求。
wire take_data = data_sram_req;
// 【实践16新增】用req与addr_ok生成实际请求握手，作为事务接收依据。
wire take_inst_req = inst_sram_req && inst_sram_addr_ok;
wire take_data_req = data_sram_req && data_sram_addr_ok;
// 【实践16新增】统一生成五个AXI通道的VALID/READY握手事件，供状态机使用。
wire ar_fire = arvalid && arready;  
wire r_fire  = rvalid && rready;
wire aw_fire = awvalid && awready;
wire w_fire  = wvalid && wready;
wire b_fire  = bvalid && bready;
// 【实践16新增】合并已完成记录与本拍握手，判断写地址和数据是否都已发出。
wire write_sent = (aw_done || aw_fire) && (w_done || w_fire);
// 【实践15新增】仅在空闲且复位释放后接收地址；数据端优先于取指端。
assign data_sram_addr_ok = aresetn && state==IDLE;
assign inst_sram_addr_ok = aresetn && state==IDLE && !take_data;
// 【实践15新增】COMPLETE状态只向事务所属端口发送一拍完成通知。
assign data_sram_data_ok = aresetn && state==COMPLETE && owner_data;
assign inst_sram_data_ok = aresetn && state==COMPLETE && !owner_data;
// 【实践15新增】两个端口共用已锁存的读数据，由各自data_ok指示是否有效。
assign data_sram_rdata = saved_rdata;
assign inst_sram_rdata = saved_rdata;
// 【实践15新增】读请求只发一拍，取指ID=0、数据ID=1，访问宽度来自锁存请求。
assign arid = owner_data ? 4'd1 : 4'd0;
assign araddr = saved_addr;
assign arlen = 8'd0;
assign arsize = {1'b0,saved_size};
assign arburst = 2'b01;
assign arlock = 2'b00;
assign arcache = 4'b0;
assign arprot = 3'b0;
// 【实践15新增】读地址VALID由状态产生，不依赖READY，反压时保持地址不变。
assign arvalid = aresetn && state==RD_ADDR;
// 【实践15新增】读地址发送完成后，才允许接收R通道响应。
assign rready = aresetn && state==RD_DATA;
// 【实践15新增】写地址固定使用ID=1，单拍发送，地址与宽度来自锁存请求。
assign awid = 4'd1;
assign awaddr = saved_addr;
assign awlen = 8'd0;
assign awsize = {1'b0,saved_size};
assign awburst = 2'b01;
assign awlock = 2'b00;
assign awcache = 4'b0;
assign awprot = 3'b0;
// 【实践15新增】AW握手前持续保持VALID，完成后关闭该通道。
assign awvalid = aresetn && state==WR_SEND && !aw_done;
// 【实践15新增】写数据固定使用ID=1，锁存数据和字节选通，单拍置WLAST。
assign wid = 4'd1;
assign wdata = saved_wdata;
assign wstrb = saved_strb;
assign wlast = 1'b1;
// 【实践15新增】W握手前持续保持VALID，独立于AW通道的完成顺序。
assign wvalid = aresetn && state==WR_SEND && !w_done;
// 【实践15新增】写地址和数据均已发送后，才允许接收B通道响应。
assign bready = aresetn && state==WR_RESP;
// 【实践15新增】在时钟沿锁存事务并推进状态，已接收的事务不随CPU冲刷撤销。
always @(posedge aclk) begin
    // 【实践15新增】复位清空状态、事务归属、请求缓存和AW/W完成记录。
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
        // 【实践15新增】空闲时选择一个CPU请求，保存后串行处理至R/B响应完成。
        IDLE: begin
            // 【实践16修改】仅在req与addr_ok实际握手后接收事务，并据此记录归属。
            if (take_data_req || take_inst_req) begin
                owner_data <= take_data_req;
                // 【实践15新增】锁存获选端口的请求字段，并清除上一笔写握手记录。
                saved_addr <= take_data ? data_sram_addr : inst_sram_addr;
                saved_size <= take_data ? data_sram_size : inst_sram_size;
                saved_wdata <= data_sram_wdata;
                saved_strb <= data_sram_wstrb;
                aw_done <= 1'b0;
                w_done <= 1'b0;
                // 【实践16修改】按实际接收的数据写请求进入写流程，其余请求进入读流程。
                state <= take_data_req && data_sram_wr ? WR_SEND : RD_ADDR;
            end
        end
        // 【实践16修改】改用统一的ar_fire事件，读地址被接收后进入读响应阶段。
        RD_ADDR: if (ar_fire) state <= RD_DATA;
        // 【实践16修改】读响应增加RID匹配检查，只在对应事务的最后一拍完成。
        RD_DATA: if (r_fire && rlast && rid == (owner_data ? 4'd1 : 4'd0)) begin
            // 【实践15新增】先锁存读数据，再进入COMPLETE向CPU通知完成。
            saved_rdata <= rdata;
            state <= COMPLETE;
        end
        // 【实践15新增】写发送阶段分别等待AW与W完成，支持任意先后顺序。
        WR_SEND: begin
            // 【实践16修改】改用aw_fire/w_fire更新完成位，由write_sent统一判断能否等待B响应。
            if (aw_fire) aw_done <= 1'b1;
            if (w_fire) w_done <= 1'b1;
            if (write_sent) state <= WR_RESP;
        end
        // 【实践16修改】写响应增加BID=1检查，匹配的B通道握手后才完成store。
        WR_RESP: if (b_fire && bid == 4'd1) state <= COMPLETE;
        // 【实践15新增】完成通知维持一拍后回到空闲，非法状态也回到空闲。
        COMPLETE: state <= IDLE;
        default: state <= IDLE;
        endcase
    end
end
// 【实践15新增】桥未实现总线错误异常处理，rresp/bresp按成功响应使用。
endmodule
`default_nettype wire
