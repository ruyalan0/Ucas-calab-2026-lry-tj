// 【实践16新增】可用于完整SoC和转接桥定向仿真的协议/事务计分板。
reg check_active = 0, check_write, check_owner;
reg check_ar_seen = 0, check_aw_seen = 0, check_w_seen = 0, check_response = 0;
reg [31:0] check_addr, check_wdata;
reg [1:0] check_size;
reg [3:0] check_strb;
reg check_ar_hold = 0, check_aw_hold = 0, check_w_hold = 0;
reg [57:0] check_ar_payload, check_aw_payload;
reg [40:0] check_w_payload;
integer check_transactions = 0, check_reads = 0, check_writes = 0;
integer check_aw_first = 0, check_w_first = 0, check_same = 0;
integer check_ar_stalls = 0, check_aw_stalls = 0, check_w_stalls = 0;
wire [57:0] check_ar_now = {`CPU.arid,`CPU.araddr,`CPU.arlen,`CPU.arsize,
    `CPU.arburst,`CPU.arlock,`CPU.arcache,`CPU.arprot};
wire [57:0] check_aw_now = {`CPU.awid,`CPU.awaddr,`CPU.awlen,`CPU.awsize,
    `CPU.awburst,`CPU.awlock,`CPU.awcache,`CPU.awprot};
wire [40:0] check_w_now = {`CPU.wid,`CPU.wdata,`CPU.wstrb,`CPU.wlast};
wire check_inst_take = `CPU.inst_sram_req && `CPU.inst_sram_addr_ok;
wire check_data_take = `CPU.data_sram_req && `CPU.data_sram_addr_ok;
always @(posedge `CHECK_CLK) begin
    if (!`CHECK_RESETN) begin
        if ({`CPU.arvalid,`CPU.awvalid,`CPU.wvalid} !== 3'b0 ||
            ^{`CPU.rready,`CPU.bready} === 1'bx) $fatal(1,"AXI reset outputs");
        check_active <= 0; check_response <= 0;
        check_ar_seen <= 0; check_aw_seen <= 0; check_w_seen <= 0;
        check_ar_hold <= 0; check_aw_hold <= 0; check_w_hold <= 0;
    end else begin
        if (check_ar_hold && (!`CPU.arvalid || check_ar_now !== check_ar_payload))
            $fatal(1,"AR changed under backpressure");
        if (check_aw_hold && (!`CPU.awvalid || check_aw_now !== check_aw_payload))
            $fatal(1,"AW changed under backpressure");
        if (check_w_hold && (!`CPU.wvalid || check_w_now !== check_w_payload))
            $fatal(1,"W changed under backpressure");
        check_ar_hold <= `CPU.arvalid && !`CPU.arready;
        check_aw_hold <= `CPU.awvalid && !`CPU.awready;
        check_w_hold <= `CPU.wvalid && !`CPU.wready;
        check_ar_payload <= check_ar_now;
        check_aw_payload <= check_aw_now;
        check_w_payload <= check_w_now;
        if (`CPU.arvalid && !`CPU.arready) check_ar_stalls <= check_ar_stalls + 1;
        if (`CPU.awvalid && !`CPU.awready) check_aw_stalls <= check_aw_stalls + 1;
        if (`CPU.wvalid && !`CPU.wready) check_w_stalls <= check_w_stalls + 1;
        if (check_inst_take || check_data_take) begin
            if (check_active || (check_inst_take && check_data_take))
                $fatal(1,"overlapping SRAM ownership");
            check_active <= 1; check_owner <= check_data_take;
            check_write <= check_data_take && `CPU.data_sram_wr;
            check_addr <= check_data_take ? `CPU.data_sram_addr : `CPU.inst_sram_addr;
            check_size <= check_data_take ? `CPU.data_sram_size : `CPU.inst_sram_size;
            check_strb <= `CPU.data_sram_wstrb;
            check_wdata <= `CPU.data_sram_wdata;
            check_ar_seen <= 0; check_aw_seen <= 0; check_w_seen <= 0;
            check_response <= 0;
            check_transactions <= check_transactions + 1;
        end
        if (`CPU.arvalid && `CPU.arready) begin
            if (!check_active || check_write || check_ar_seen ||
                `CPU.araddr !== check_addr || `CPU.arsize !== {1'b0,check_size} ||
                `CPU.arid !== (check_owner ? 4'd1 : 4'd0) || `CPU.arlen !== 0)
                $fatal(1,"unexpected/duplicate/wrong AR");
            check_ar_seen <= 1; check_reads <= check_reads + 1;
        end
        if (`CPU.awvalid && `CPU.awready) begin
            if (!check_active || !check_write || check_aw_seen ||
                `CPU.awaddr !== check_addr || `CPU.awsize !== {1'b0,check_size} ||
                `CPU.awid !== 4'd1 || `CPU.awlen !== 0)
                $fatal(1,"unexpected/duplicate/wrong AW");
            check_aw_seen <= 1;
            if (!check_w_seen && !(`CPU.wvalid && `CPU.wready)) check_aw_first <= check_aw_first+1;
            if (!check_w_seen && (`CPU.wvalid && `CPU.wready)) check_same <= check_same+1;
        end
        if (`CPU.wvalid && `CPU.wready) begin
            if (!check_active || !check_write || check_w_seen ||
                `CPU.wdata !== check_wdata || `CPU.wstrb !== check_strb ||
                `CPU.wid !== 4'd1 || `CPU.wlast !== 1'b1)
                $fatal(1,"unexpected/duplicate/wrong W");
            check_w_seen <= 1;
            if (!check_aw_seen && !(`CPU.awvalid && `CPU.awready)) check_w_first <= check_w_first+1;
        end
        if (`CPU.rvalid && `CPU.rready) begin
            if (!check_active || check_write || !check_ar_seen || check_response ||
                `CPU.rid !== (check_owner ? 4'd1 : 4'd0) || !`CPU.rlast)
                $fatal(1,"unexpected/duplicate R");
            check_response <= 1;
        end
        if (`CPU.bvalid && `CPU.bready) begin
            if (!check_active || !check_write || !check_aw_seen || !check_w_seen ||
                check_response || `CPU.bid !== 4'd1) $fatal(1,"early/duplicate B");
            check_response <= 1; check_writes <= check_writes + 1;
        end
        if (`CPU.inst_sram_data_ok || `CPU.data_sram_data_ok) begin
            if (!check_active || !check_response ||
                `CPU.data_sram_data_ok !== check_owner ||
                `CPU.inst_sram_data_ok !== !check_owner) $fatal(1,"wrong/early/duplicate data_ok");
            check_active <= 0;
        end
    end
end
final $display("AXI_CHECK transactions=%0d reads=%0d writes=%0d AW_first=%0d W_first=%0d same=%0d stalls=%0d/%0d/%0d",
 check_transactions,check_reads,check_writes,check_aw_first,check_w_first,check_same,
 check_ar_stalls,check_aw_stalls,check_w_stalls);
