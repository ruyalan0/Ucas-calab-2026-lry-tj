// 【实践16新增】独立AXI从设备：强制AW先到/W先到/同拍、长响应、连续写读和双端口仲裁。
`timescale 1ns/1ps
module bridge_tb;
reg  aclk = 0;
reg  aresetn = 0;
wire [3:0] arid;
wire [31:0] araddr;
wire [7:0] arlen;
wire [2:0] arsize;
wire [1:0] arburst;
wire [1:0] arlock;
wire [3:0] arcache;
wire [2:0] arprot;
wire  arvalid;
reg  arready = 0;
reg [3:0] rid = 0;
reg [31:0] rdata = 0;
reg [1:0] rresp = 0;
reg  rlast = 0;
reg  rvalid = 0;
wire  rready;
wire [3:0] awid;
wire [31:0] awaddr;
wire [7:0] awlen;
wire [2:0] awsize;
wire [1:0] awburst;
wire [1:0] awlock;
wire [3:0] awcache;
wire [2:0] awprot;
wire  awvalid;
reg  awready = 0;
wire [3:0] wid;
wire [31:0] wdata;
wire [3:0] wstrb;
wire  wlast;
wire  wvalid;
reg  wready = 0;
reg [3:0] bid = 0;
reg [1:0] bresp = 0;
reg  bvalid = 0;
wire  bready;
reg  inst_sram_req = 0;
reg  inst_sram_wr = 0;
reg [1:0] inst_sram_size = 0;
reg [3:0] inst_sram_wstrb = 0;
reg [31:0] inst_sram_addr = 0;
reg [31:0] inst_sram_wdata = 0;
wire  inst_sram_addr_ok;
wire  inst_sram_data_ok;
wire [31:0] inst_sram_rdata;
reg  data_sram_req = 0;
reg  data_sram_wr = 0;
reg [1:0] data_sram_size = 0;
reg [3:0] data_sram_wstrb = 0;
reg [31:0] data_sram_addr = 0;
reg [31:0] data_sram_wdata = 0;
wire  data_sram_addr_ok;
wire  data_sram_data_ok;
wire [31:0] data_sram_rdata;
sram_axi_bridge dut(.aclk(aclk),.aresetn(aresetn),.arid(arid),.araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arlock(arlock),.arcache(arcache),.arprot(arprot),.arvalid(arvalid),.arready(arready),.rid(rid),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),.awid(awid),.awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awlock(awlock),.awcache(awcache),.awprot(awprot),.awvalid(awvalid),.awready(awready),.wid(wid),.wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),.inst_sram_req(inst_sram_req),.inst_sram_wr(inst_sram_wr),.inst_sram_size(inst_sram_size),.inst_sram_wstrb(inst_sram_wstrb),.inst_sram_addr(inst_sram_addr),.inst_sram_wdata(inst_sram_wdata),.inst_sram_addr_ok(inst_sram_addr_ok),.inst_sram_data_ok(inst_sram_data_ok),.inst_sram_rdata(inst_sram_rdata),.data_sram_req(data_sram_req),.data_sram_wr(data_sram_wr),.data_sram_size(data_sram_size),.data_sram_wstrb(data_sram_wstrb),.data_sram_addr(data_sram_addr),.data_sram_wdata(data_sram_wdata),.data_sram_addr_ok(data_sram_addr_ok),.data_sram_data_ok(data_sram_data_ok),.data_sram_rdata(data_sram_rdata));

always #5 aclk = ~aclk;
`define CPU dut
`define CHECK_CLK aclk
`define CHECK_RESETN aresetn
`include "axi_checks.svh"
reg [31:0] memory [0:255];
reg [31:0] reference_mem [0:255];
reg [31:0] rng = 32'h12345678;
reg ar_pending = 0, aw_pending = 0, w_pending = 0;
reg [31:0] read_addr, write_addr, write_data;
reg [3:0] read_id, write_strb;
integer read_delay = 0, write_delay = 0, mode = 0;
integer i, j, n, idx;
reg [31:0] value;
reg [3:0] mask;
reg [1:0] size;
reg [31:0] address;
always @(negedge aclk) begin
    rng = {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    arready = aresetn && !ar_pending && !rvalid && rng[0];
    case (mode)
    0: begin awready = aresetn && !aw_pending; wready = aresetn && aw_pending && !w_pending; end
    1: begin wready = aresetn && !w_pending; awready = aresetn && w_pending && !aw_pending; end
    2: begin awready = aresetn && !aw_pending; wready = aresetn && !w_pending; end
    default: begin
        awready = aresetn && !aw_pending && rng[3];
        wready = aresetn && !w_pending && rng[7];
    end
    endcase
end
always @(posedge aclk) begin
    if (!aresetn) begin
        ar_pending <= 0; aw_pending <= 0; w_pending <= 0;
        rvalid <= 0; bvalid <= 0;
        read_delay <= 0; write_delay <= 0;
    end else begin
        if (arvalid && arready) begin
            ar_pending <= 1; read_addr <= araddr; read_id <= arid;
            read_delay <= 1 + rng[5:1];
        end
        if (ar_pending && !rvalid) begin
            if (read_delay == 0) begin
                rvalid <= 1; rlast <= 1; rid <= read_id;
                rdata <= memory[read_addr[9:2]];
            end else read_delay <= read_delay - 1;
        end
        if (rvalid && rready) begin rvalid <= 0; ar_pending <= 0; end
        if (awvalid && awready) begin aw_pending <= 1; write_addr <= awaddr; end
        if (wvalid && wready) begin
            w_pending <= 1; write_data <= wdata; write_strb <= wstrb;
            write_delay <= 40 + rng[5:0];
        end
        if (aw_pending && w_pending && !bvalid) begin
            if (write_delay == 0) begin
                for (j=0;j<4;j=j+1)
                    if (write_strb[j]) memory[write_addr[9:2]][j*8+:8] <= write_data[j*8+:8];
                bvalid <= 1; bid <= 1;
            end else write_delay <= write_delay - 1;
        end
        if (bvalid && bready) begin bvalid <= 0; aw_pending <= 0; w_pending <= 0; end
    end
end
// 改变CPU端尚未保持的载荷，确认已接受事务完全由桥内锁存器驱动。
task automatic transaction(input bit data_port, input bit wr,
    input [31:0] addr, input [1:0] sz, input [3:0] strb, input [31:0] data);
integer k;
begin
    @(negedge aclk);
    if (data_port) begin
        data_sram_req=1; data_sram_wr=wr; data_sram_addr=addr;
        data_sram_size=sz; data_sram_wstrb=strb; data_sram_wdata=data;
        do @(posedge aclk); while (!data_sram_addr_ok);
        @(negedge aclk);
        data_sram_req=0; data_sram_addr=~addr; data_sram_wdata=~data;
        data_sram_size=~sz; data_sram_wstrb=~strb; data_sram_wr=~wr;
        while (!data_sram_data_ok) @(negedge aclk);
        if (!wr && data_sram_rdata !== reference_mem[addr[9:2]])
            $fatal(1,"data read mismatch: %h",addr);
        if (wr) for(k=0;k<4;k=k+1)
            if(strb[k]) reference_mem[addr[9:2]][k*8+:8]=data[k*8+:8];
    end else begin
        inst_sram_req=1; inst_sram_addr=addr; inst_sram_size=sz;
        do @(posedge aclk); while (!inst_sram_addr_ok);
        @(negedge aclk); inst_sram_req=0; inst_sram_addr=~addr;
        while (!inst_sram_data_ok) @(negedge aclk);
        if (inst_sram_rdata !== reference_mem[addr[9:2]]) $fatal(1,"inst read mismatch");
    end
    @(negedge aclk);
end
endtask
initial begin
    for(i=0;i<256;i=i+1) begin memory[i]=32'h12340000+i; reference_mem[i]=memory[i]; end
    repeat(6) @(negedge aclk);
    aresetn=1;
    for(n=0;n<120;n=n+1) begin
        mode = n<3 ? n : 3;
        size=n%3;
        address=32'h1c000000+((n%128)*4)+(size==0 ? n%4 : (size==1 ? (n%2)*2 : 0));
        value=32'h89abcdef ^ (n*32'h01010101);
        mask=(size==0 ? (4'b1 << address[1:0]) : size==1 ? (4'b11 << address[1:0]) : 4'b1111);
        transaction(1,1,address,size,mask,value);
        transaction(1,0,address,size,0,0);
        transaction(0,0,{address[31:2],2'b00},2,0,0);
    end
    // 同时请求时数据端优先；取指请求保持到桥真正接收，响应仍按原端口返回。
    @(negedge aclk);
    inst_sram_req=1; inst_sram_addr=32'h1c000000; inst_sram_size=2;
    data_sram_req=1; data_sram_wr=0; data_sram_addr=32'h1c000004; data_sram_size=2;
    @(posedge aclk);
    if (!data_sram_addr_ok || inst_sram_addr_ok) $fatal(1,"data arbitration priority");
    @(negedge aclk); data_sram_req=0;
    while (!data_sram_data_ok) @(negedge aclk);
    if (data_sram_rdata !== reference_mem[1]) $fatal(1,"arbitrated data");
    do @(posedge aclk); while(!inst_sram_addr_ok);
    @(negedge aclk); inst_sram_req=0;
    while(!inst_sram_data_ok) @(negedge aclk);
    if (inst_sram_rdata !== reference_mem[0]) $fatal(1,"arbitrated inst");
    repeat(3) @(negedge aclk);
    if(check_active || check_transactions != 362 || check_reads != 242 || check_writes != 120 ||
       check_aw_first==0 || check_w_first==0 || check_same==0 ||
       check_ar_stalls==0 || check_aw_stalls==0 || check_w_stalls==0) $fatal(1,"coverage incomplete");
    $display("BRIDGE_PASS 362 transactions, byte/half/word, AW/W orders, delayed B, priority");
    $finish;
end
initial begin #1000000; $fatal(1,"bridge timeout"); end
endmodule
