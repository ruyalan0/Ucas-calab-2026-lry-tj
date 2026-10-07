
`timescale 1ns / 1ps
`default_nettype none

//==========================================================
// 【实践10修改】在实践9五级流水线及前递机制上扩展16条指令。
// 1. 9条算术逻辑指令复用12位ALU控制，乘除法使用独立7位md_op。
// 2. 组合乘法和阻塞式多周期除法使用Xilinx IP，统一EX结果及前递。
// 3. 除法等待时保持EX/ID/IF，MEM/WB正常排空；结果消费后才可重发。
// 4. 未就绪的EX生产者屏蔽旧MEM/WB值；寄存器型分支仍从MEM取值。
//==========================================================

module mycpu_top(
    input  wire        clk,
    input  wire        resetn,
    // 指令RAM：增加1位高有效片选，写使能由1位扩为4位。
    // we[i]对应wdata的第i个字节；本CPU只读指令，四位写使能恒为0。
    output wire        inst_sram_en,
    output wire [ 3:0] inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,
    // 数据RAM：增加1位高有效片选，改用4位字节写使能。
    // ld.w：en=1、we=0000；st.w：en=1、we=1111；非访存指令en=0。
    output wire        data_sram_en,
    output wire [ 3:0] data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    // 调试端口定义不变，内部驱动改为同一条WB指令的PC和写回信息。
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);
//==========================================================
// Reset：沿用实践6的同步复位方式
//==========================================================
// 外部resetn低有效，经寄存一拍生成内部高有效reset。
// 流水寄存器在上升沿响应reset；对外使能还额外检查resetn。
reg reset;
always @(posedge clk) reset <= ~resetn;

//==========================================================
// 流水线有效位与级间传递控制
//==========================================================
// 每一级独立的valid替代原全局valid，表示本级是否有有效指令。
// 无效槽的数据允许残留，但不能触发分支、写内存或写寄存器。
reg fs_valid, ds_valid, es_valid, ms_valid, ws_valid;
wire fs_ready_go, ds_ready_go, es_ready_go, ms_ready_go, ws_ready_go;
wire fs_allowin, ds_allowin, es_allowin, ms_allowin, ws_allowin;
wire fs_to_ds_valid, ds_to_es_valid, es_to_ms_valid, ms_to_ws_valid;
// ID级暂停、分支生效及错误顺序指令取消信号。
wire ds_raw_stall;//ID 级因为 RAW 数据相关而需要暂停
wire ds_br_cond, br_taken_cancel;
//ds_br_cond：当前 ID 指令在语义上是否要求跳转。
//br_taken_cancel：跳转正式生效时，取消已经取到的顺序下一条指令。


reg es_res_from_mem, es_gr_we, es_mem_we;
reg [4:0] es_dest;
reg ms_res_from_mem, ms_gr_we;
reg [4:0] ms_dest;
reg ws_gr_we;
reg [4:0] ws_dest;

wire [31:0] es_alu_result;
// 【实践10修改】新增统一执行结果、7位乘除法控制及完成握手信号，供EX执行和ID前递使用。
wire [31:0] es_exec_result;
reg  [ 6:0] es_md_op;
wire es_is_mul, es_is_div, es_div_signed, es_div_remainder;
wire es_fire, es_result_available;
wire [63:0] mul_product;
wire [31:0] es_mul_result, es_div_result;
wire div_done;
wire [31:0] div_quotient, div_remainder;
wire [31:0] ms_final_result;
reg  [31:0] ws_final_result;


assign fs_ready_go = 1'b1;
assign ds_ready_go = !ds_raw_stall;
// 【实践10修改】EX由固定就绪改为除法完成后才就绪
assign es_ready_go = !es_is_div || div_done;
assign ms_ready_go = 1'b1;
assign ws_ready_go = 1'b1;

// allowin：本级为空，或本级完成且下一级允许接收。
assign ws_allowin = !ws_valid || ws_ready_go;
assign ms_allowin = !ms_valid || (ms_ready_go && ws_allowin);
assign es_allowin = !es_valid || (es_ready_go && ms_allowin);
assign ds_allowin = !ds_valid || (ds_ready_go && es_allowin);
assign fs_allowin = !fs_valid || (fs_ready_go && ds_allowin);

// to_next_valid表示向下一级提供有效指令，与下一级allowin共同决定传递。（当前指令有效，且处理完成，可以交给下一级）
assign fs_to_ds_valid = fs_valid && fs_ready_go;
assign ds_to_es_valid = ds_valid && ds_ready_go;
assign es_to_ms_valid = es_valid && es_ready_go;
assign ms_to_ws_valid = ms_valid && ms_ready_go;
// 【实践10修改】新增EX向MEM实际传递握手，用于消费除法结果及限定访存请求。
assign es_fire = es_to_ms_valid && ms_allowin;

//==========================================================
// Pre-IF：提前生成同步指令RAM的请求地址
//==========================================================
reg  [31:0] fs_pc;
wire [31:0] seq_pc, nextpc;
wire [31:0] ds_br_target;
wire        to_fs_valid;


assign seq_pc = fs_pc + 32'd4;
assign nextpc = br_taken_cancel ? ds_br_target : seq_pc;
assign to_fs_valid = resetn && !reset;

// 原inst_sram_addr=pc改为nextpc，提前向同步RAM发请求。
// 片选与IF有效位、PC更新使用同一条件，保证PC与RAM返回值一一对应。
// 同时检查resetn和reset，外部复位刚拉低、内部reset尚未更新时也禁止请求。

assign inst_sram_en    = to_fs_valid && fs_allowin;
assign inst_sram_we    = 4'b0000;
assign inst_sram_addr  = nextpc;
assign inst_sram_wdata = 32'b0;

//==========================================================
// IF取指级及IF -> ID流水寄存器
//==========================================================
reg [31:0] ds_pc, ds_inst;

// 接收取指请求的上升沿同时保存nextpc，沿后RAM返回属于该fs_pc。
// fs_pc复位为入口地址减4，保证第一次有效取指地址为0x1c000000。

always @(posedge clk) begin
    if (reset) begin
        fs_valid <= 1'b0;
        fs_pc    <= 32'h1bfffffc;
    end
    else if (fs_allowin) begin
        fs_valid <= to_fs_valid;
        if (to_fs_valid)
            fs_pc <= nextpc;
    end
    // 预留IF不允许接收时的分支取消逻辑；当前跳转生效时fs_allowin为1。
    else if (br_taken_cancel) begin
        // 若后续修改取指握手使此分支可达，则取消旧IF槽。
        fs_valid <= 1'b0;
    end
end

// 下一上升沿将RAM返回指令和对应fs_pc一起送入ID。
// 非阻塞赋值在沿上读取旧值，不会把下一条返回指令配给当前PC。
// 各级统一规则：复位清valid；允许接收时更新valid；
// 前级有效且本级允许接收时更新数据。无效数据无需复位清零。
always @(posedge clk) begin
    if (reset)
        ds_valid <= 1'b0;
    // 跳转生效时清除已经取到的错误顺序指令。
    else if (br_taken_cancel)
        ds_valid <= 1'b0; 
    else if (ds_allowin)
        ds_valid <= fs_to_ds_valid;

    if (fs_to_ds_valid && ds_allowin) begin
        ds_pc   <= fs_pc;
        ds_inst <= inst_sram_rdata;
    end
end

//==========================================================
// ID：原单周期译码、读寄存器和分支逻辑迁移到此级
//==========================================================
// ID产生的控制信号用于选择操作数，并通过级间寄存器传到使用它的级。
wire [11:0] alu_op;
// 【实践10修改】新增独立7位乘除法操作码，原12位alu_op宽度保持不变。
wire [ 6:0] md_op;
wire        src1_is_pc;
wire        src2_is_imm;
wire        res_from_mem;
wire        dst_is_r1;
wire        gr_we;
wire        mem_we;
wire        src_reg_is_rd;
wire [4: 0] dest;
wire [31:0] rj_value;
wire [31:0] rkd_value;
wire [31:0] imm;
wire [31:0] br_offs;
wire [31:0] jirl_offs;

wire [ 5:0] op_31_26;
wire [ 3:0] op_25_22;
wire [ 1:0] op_21_20;
wire [ 4:0] op_19_15;
wire [ 4:0] rd;
wire [ 4:0] rj;
wire [ 4:0] rk;
wire [11:0] i12;
wire [19:0] i20;
wire [15:0] i16;
wire [25:0] i26;

wire [63:0] op_31_26_d;
wire [15:0] op_25_22_d;
wire [ 3:0] op_21_20_d;
wire [31:0] op_19_15_d;

wire        inst_add_w;
wire        inst_sub_w;
wire        inst_slt;
wire        inst_sltu;
wire        inst_nor;
wire        inst_and;
wire        inst_or;
wire        inst_xor;
wire        inst_slli_w;
wire        inst_srli_w;
wire        inst_srai_w;
wire        inst_addi_w;
wire        inst_ld_w;
wire        inst_st_w;
wire        inst_jirl;
wire        inst_b;
wire        inst_bl;
wire        inst_beq;
wire        inst_bne;
wire        inst_lu12i_w;
// 【实践10修改】新增16条指令标志：5条立即数、3条寄存器移位、pcaddu12i及7条乘除法指令。
wire        inst_slti, inst_sltui, inst_andi, inst_ori, inst_xori;
wire        inst_sll_w, inst_srl_w, inst_sra_w, inst_pcaddu12i;
wire        inst_mul_w, inst_mulh_w, inst_mulh_wu;
wire        inst_div_w, inst_mod_w, inst_div_wu, inst_mod_wu;

wire        need_ui5;
// 【实践10修改】新增12位无符号立即数选择信号，供andi/ori/xori零扩展使用。
wire        need_ui12;
wire        need_si12;
wire        need_si16;
wire        need_si20;
wire        need_si26;
wire        src2_is_4;

wire [ 4:0] rf_raddr1;
wire [31:0] rf_rdata1;
wire [ 4:0] rf_raddr2;
wire [31:0] rf_rdata2;
wire        rf_we   ;
wire [ 4:0] rf_waddr;
wire [31:0] rf_wdata;

// 真实源使用、在途写者及两读端口的RAW检测信号。
wire ds_use_rj, ds_use_rkd;
wire ds_is_reg_branch;
wire ds_load_use_stall;
wire ds_branch_ex_stall;
// 【实践10修改】新增ID依赖未完成EX除法结果时的暂停信号。
wire ds_div_use_stall;

wire ds_rj_fwd_es,  ds_rj_fwd_ms,  ds_rj_fwd_ws;
wire ds_rkd_fwd_es, ds_rkd_fwd_ms, ds_rkd_fwd_ws;
wire es_pending_write, ms_pending_write, ws_pending_write;//对应流水级是否存在一条尚未完成寄存器写回的有效指令
wire ds_rj_raw_es, ds_rj_raw_ms, ds_rj_raw_ws;//rj与后三级存在RAW相关
wire ds_rkd_raw_es, ds_rkd_raw_ms, ds_rkd_raw_ws;//rkd与后三级存在RAW相关

wire rj_eq_rd;
// 【实践10修改】新增分支专用操作数，独立于包含EX乘除法结果的通用前递通路。
wire [31:0] ds_br_rj_value, ds_br_rkd_value;
wire [31:0] ds_alu_src1, ds_alu_src2;

// 全部字段取自ds_inst，不再直接译码inst_sram_rdata。
// op_*为分段操作码，rd/rj/rk为寄存器编号，i*为不同格式立即数。
assign op_31_26  = ds_inst[31:26];
assign op_25_22  = ds_inst[25:22];
assign op_21_20  = ds_inst[21:20];
assign op_19_15  = ds_inst[19:15];

assign rd   = ds_inst[ 4: 0];
assign rj   = ds_inst[ 9: 5];
assign rk   = ds_inst[14:10];

assign i12  = ds_inst[21:10];
assign i20  = ds_inst[24: 5];
assign i16  = ds_inst[25:10];
assign i26  = {ds_inst[ 9: 0], ds_inst[25:10]};

// 沿用tools.v的独热译码器，下面20条指令的判定条件保持实践6语义。
decoder_6_64 u_dec0(.in(op_31_26 ), .out(op_31_26_d ));
decoder_4_16 u_dec1(.in(op_25_22 ), .out(op_25_22_d ));
decoder_2_4  u_dec2(.in(op_21_20 ), .out(op_21_20_d ));
decoder_5_32 u_dec3(.in(op_19_15 ), .out(op_19_15_d ));

assign inst_add_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
assign inst_sub_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
assign inst_slt    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
assign inst_sltu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
assign inst_nor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
assign inst_and    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
assign inst_or     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
assign inst_xor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
assign inst_slli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
assign inst_srli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
assign inst_srai_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
assign inst_addi_w = op_31_26_d[6'h00] & op_25_22_d[4'ha];
assign inst_ld_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
assign inst_st_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_jirl   = op_31_26_d[6'h13];
assign inst_b      = op_31_26_d[6'h14];
assign inst_bl     = op_31_26_d[6'h15];
assign inst_beq    = op_31_26_d[6'h16];
assign inst_bne    = op_31_26_d[6'h17];
assign inst_lu12i_w= op_31_26_d[6'h05] & ~ds_inst[25];

// 【实践10修改】新增16条指令译码；立即数指令仅检查操作码字段，寄存器移位和乘除法使用完整操作码。
assign inst_slti   = op_31_26_d[6'h00] & op_25_22_d[4'h8];
assign inst_sltui  = op_31_26_d[6'h00] & op_25_22_d[4'h9];
assign inst_andi   = op_31_26_d[6'h00] & op_25_22_d[4'hd];
assign inst_ori    = op_31_26_d[6'h00] & op_25_22_d[4'he];
assign inst_xori   = op_31_26_d[6'h00] & op_25_22_d[4'hf];
assign inst_sll_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
assign inst_srl_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
assign inst_sra_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
assign inst_pcaddu12i = op_31_26_d[6'h07] & ~ds_inst[25];
assign inst_mul_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
assign inst_mulh_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
assign inst_mulh_wu= op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
assign inst_div_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
assign inst_mod_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
assign inst_div_wu = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
assign inst_mod_wu = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];

// 【实践10修改】将7条乘除法指令编码为独热md_op；[2:0]控制乘法，[6:3]控制除法/取余。
assign md_op = {inst_mod_wu, inst_div_wu, inst_mod_w, inst_div_w,
                inst_mulh_wu, inst_mulh_w, inst_mul_w};

// ALU控制依次为加、减、有符号/无符号比较、与、或非、或、异或、
// 逻辑左移、逻辑右移、算术右移和高位立即数装载。
// load/store用加法算有效地址；jirl/bl用加法算链接地址PC+4。
// 【实践10修改】扩展ALU选择条件：pcaddu12i复用加法，新增立即数和寄存器移位指令复用原运算。
assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w
                    | inst_jirl | inst_bl | inst_pcaddu12i;
assign alu_op[ 1] = inst_sub_w;
assign alu_op[ 2] = inst_slt | inst_slti;
assign alu_op[ 3] = inst_sltu | inst_sltui;
assign alu_op[ 4] = inst_and | inst_andi;
assign alu_op[ 5] = inst_nor;
assign alu_op[ 6] = inst_or | inst_ori;
assign alu_op[ 7] = inst_xor | inst_xori;
assign alu_op[ 8] = inst_slli_w | inst_sll_w;
assign alu_op[ 9] = inst_srli_w | inst_srl_w;
assign alu_op[10] = inst_srai_w | inst_sra_w;
assign alu_op[11] = inst_lu12i_w;

// 【实践10修改】新增need_ui12；need_si12加入slti/sltui，need_si20加入pcaddu12i。
assign need_ui5   =  inst_slli_w | inst_srli_w | inst_srai_w;
assign need_ui12  =  inst_andi | inst_ori | inst_xori;
assign need_si12  =  inst_addi_w | inst_ld_w | inst_st_w | inst_slti | inst_sltui;
assign need_si16  =  inst_jirl | inst_beq | inst_bne;
assign need_si20  =  inst_lu12i_w | inst_pcaddu12i;
assign need_si26  =  inst_b | inst_bl;
assign src2_is_4  =  inst_jirl | inst_bl;

// slti/sltui都符号扩展i12；逻辑立即数零扩展，移位只取低5位。
// pcaddu12i使用当前指令PC加{i20,12'b0}，不改变分支控制。
// 【实践10修改】立即数选择新增ui12零扩展和ui5显式提取；slti/sltui仍符号扩展i12，pcaddu12i复用高20位立即数。
assign imm = src2_is_4 ? 32'h4                      :
             need_si20 ? {i20[19:0], 12'b0}         :
             need_ui12 ? {20'b0, i12}              :
             need_ui5  ? {27'b0, ds_inst[14:10]}    :
                         {{20{i12[11]}}, i12[11:0]} ;

// 分支偏移符号扩展并左移2位，将指令中的字偏移转换为字节偏移。
assign br_offs = need_si26 ? {{ 4{i26[25]}}, i26[25:0], 2'b0} :
                             {{14{i16[15]}}, i16[15:0], 2'b0} ;

assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

// beq/bne读取rd用于比较；st.w读取rd作为写内存数据；其他读取rk。
assign src_reg_is_rd = inst_beq | inst_bne | inst_st_w;

// 【实践10修改】源1的PC选择加入pcaddu12i；源2立即数选择加入5条立即数指令及pcaddu12i。
assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;

assign src2_is_imm   = inst_slli_w |
                       inst_srli_w |
                       inst_srai_w |
                       inst_addi_w |
                       inst_slti   |
                       inst_sltui  |
                       inst_andi   |
                       inst_ori    |
                       inst_xori   |
                       inst_pcaddu12i |
                       inst_ld_w   |
                       inst_st_w   |
                       inst_lu12i_w|
                       inst_jirl   |
                       inst_bl     ;

assign res_from_mem  = inst_ld_w;
assign dst_is_r1     = inst_bl;

// 沿用实践6修正：bl需要写r1；store及非链接分支不写寄存器。
// gr_we仅表示译码写回意图，真实写使能在WB结合valid及复位生成。
assign gr_we         = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b;
assign mem_we        = inst_st_w;
assign dest          = dst_is_r1 ? 5'd1 : rd;

assign rf_raddr1 = rj;
assign rf_raddr2 = src_reg_is_rd ? rd :rk;

// 按指令语义标记真实源：jirl读rj，store还读rd；立即数字段不算源。
// 【实践10修改】真实源检测覆盖新增指令：立即数运算读rj，寄存器移位和乘除法读rj/rk；pcaddu12i不读寄存器。
assign ds_use_rj = inst_add_w || inst_sub_w || inst_slt || inst_sltu
                || inst_nor || inst_and || inst_or || inst_xor
                || inst_slli_w || inst_srli_w || inst_srai_w
                || inst_addi_w || inst_ld_w || inst_st_w
                || inst_slti || inst_sltui || inst_andi || inst_ori || inst_xori
                || inst_sll_w || inst_srl_w || inst_sra_w || (|md_op)
                || inst_jirl || inst_beq || inst_bne;
assign ds_use_rkd = inst_add_w || inst_sub_w || inst_slt || inst_sltu
                 || inst_nor || inst_and || inst_or || inst_xor
                 || inst_sll_w || inst_srl_w || inst_sra_w || (|md_op)
                 || inst_st_w || inst_beq || inst_bne;

// 标记EXE/MEM/WB中的在途写回；无效槽、非写回指令及r0不产生依赖。
// WB仍算在途写回，因为寄存器堆要到当前上升沿才完成写入。
assign es_pending_write = es_valid && es_gr_we && (es_dest != 5'd0);
assign ms_pending_write = ms_valid && ms_gr_we && (ms_dest != 5'd0);
assign ws_pending_write = ws_valid && ws_gr_we && (ws_dest != 5'd0);

// 分别比较两个真实源与后三级目的寄存器，检测所有RAW相关。
assign ds_rj_raw_es = ds_valid && ds_use_rj && (rf_raddr1 != 5'd0)
                    && es_pending_write && (rf_raddr1 == es_dest);

assign ds_rj_raw_ms = ds_valid && ds_use_rj && (rf_raddr1 != 5'd0)
                    && ms_pending_write && (rf_raddr1 == ms_dest);

assign ds_rj_raw_ws = ds_valid && ds_use_rj && (rf_raddr1 != 5'd0)
                    && ws_pending_write && (rf_raddr1 == ws_dest);

assign ds_rkd_raw_es = ds_valid && ds_use_rkd && (rf_raddr2 != 5'd0)
                    && es_pending_write && (rf_raddr2 == es_dest);

assign ds_rkd_raw_ms = ds_valid && ds_use_rkd && (rf_raddr2 != 5'd0)
                    && ms_pending_write && (rf_raddr2 == ms_dest);

assign ds_rkd_raw_ws = ds_valid && ds_use_rkd && (rf_raddr2 != 5'd0)
                    && ws_pending_write && (rf_raddr2 == ws_dest);

assign ds_is_reg_branch = inst_beq | inst_bne | inst_jirl;

// EX只前递已完成的非load结果，寄存器型转移仍等待MEM。
// 最新EX写者未就绪时屏蔽MEM/WB中的同名旧值，并由RAW暂停阻止接收。
// 【实践10修改】EX前递由非load扩展为非load且除法已完成；MEM排除EX同名写者，WB排除EX/MEM同名写者，避免前递旧值。
assign es_result_available = !es_res_from_mem && (!es_is_div || div_done);
assign ds_rj_fwd_es  = ds_rj_raw_es && es_result_available && !ds_is_reg_branch;
assign ds_rj_fwd_ms  = ds_rj_raw_ms && !ds_rj_raw_es;
assign ds_rj_fwd_ws  = ds_rj_raw_ws && !ds_rj_raw_es && !ds_rj_raw_ms;
assign ds_rkd_fwd_es = ds_rkd_raw_es && es_result_available && !ds_is_reg_branch;
assign ds_rkd_fwd_ms = ds_rkd_raw_ms && !ds_rkd_raw_es;
assign ds_rkd_fwd_ws = ds_rkd_raw_ws && !ds_rkd_raw_es && !ds_rkd_raw_ms;

assign ds_load_use_stall = es_res_from_mem && (ds_rj_raw_es || ds_rkd_raw_es);
assign ds_branch_ex_stall = ds_is_reg_branch  && (ds_rj_raw_es || ds_rkd_raw_es);
// 【实践10修改】在原load-use和分支依赖暂停外，新增依赖未完成除法的暂停，并汇总到ds_raw_stall。
assign ds_div_use_stall = es_is_div && !div_done && (ds_rj_raw_es || ds_rkd_raw_es);
// 非相关ID指令也受es_allowin约束，不能在除法等待期间提前跳转。
assign ds_raw_stall = ds_load_use_stall || ds_branch_ex_stall || ds_div_use_stall;


// 读端口由ID驱动，写端口由WB驱动。
regfile u_regfile(
    .clk    (clk      ),
    .raddr1 (rf_raddr1),
    .rdata1 (rf_rdata1),
    .raddr2 (rf_raddr2),
    .rdata2 (rf_rdata2),
    .we     (rf_we    ),
    .waddr  (rf_waddr ),
    .wdata  (rf_wdata )
    );

// 【实践10修改】rj的EX前递源由es_alu_result改为es_exec_result，支持ALU、乘法及除法结果。
assign rj_value = ds_rj_fwd_es ? es_exec_result :
                  ds_rj_fwd_ms ? ms_final_result :
                  ds_rj_fwd_ws ? ws_final_result :
                                 rf_rdata1;

// 【实践10修改】rk/rd的EX前递源同样改为统一执行结果，供后续运算及store数据使用。
assign rkd_value = ds_rkd_fwd_es ? es_exec_result :
                   ds_rkd_fwd_ms ? ms_final_result :
                   ds_rkd_fwd_ws ? ws_final_result :
                                   rf_rdata2;

// 操作数就绪且分支能离开ID时才重定向，并取消旧IF对应的ID槽。
// 分支仍进入EX，bl/jirl正常写回链接值；不清除后三级或目标IF。
// 【实践10修改】分支比较改用独立MEM/WB/寄存器堆选择器，切断EX乘法器/ALU经分支通向取指的组合路径。
assign ds_br_rj_value = ds_rj_fwd_ms ? ms_final_result :
                        ds_rj_fwd_ws ? ws_final_result : rf_rdata1;
assign ds_br_rkd_value = ds_rkd_fwd_ms ? ms_final_result :
                         ds_rkd_fwd_ws ? ws_final_result : rf_rdata2;
assign rj_eq_rd = (ds_br_rj_value == ds_br_rkd_value);
assign ds_br_cond = (inst_beq && rj_eq_rd)
                || (inst_bne && !rj_eq_rd)
                || inst_jirl || inst_bl || inst_b;
assign br_taken_cancel = resetn && !reset && ds_to_es_valid && es_allowin && ds_br_cond;


// PC相对目标必须基于ds_pc；jirl目标为rj+偏移，不能混用IF级PC。
// 【实践10修改】jirl目标基址由通用rj_value改为分支专用ds_br_rj_value，PC相对分支保持不变。
assign ds_br_target = (inst_beq || inst_bne || inst_bl || inst_b) ? (ds_pc + br_offs) :
                                                    (ds_br_rj_value + jirl_offs);

// ID只选择操作数，真正的ALU运算移至EXE。
assign ds_alu_src1 = src1_is_pc  ? ds_pc[31:0] : rj_value;
assign ds_alu_src2 = src2_is_imm ? imm : rkd_value;

//==========================================================
// ID -> EXE：成组保存PC、控制信号及操作数
//==========================================================
// es_pc继续传至WB用于debug；es_rkd_value单独保存store的数据。
// 不把整条指令传至EXE重复译码，EXE只使用已保存的控制和操作数。
reg [31:0] es_pc;
reg [11:0] es_alu_op;
reg [31:0] es_alu_src1, es_alu_src2;
reg [31:0] es_rkd_value;

// 【实践10修改】新增ID到EX的md_op寄存器；复位清零，接收普通指令时写零，EX等待时保持。
// 普通指令也写入全零md_op；EX等待时控制位与操作数一起保持。
always @(posedge clk) begin
    if (reset)
        es_md_op <= 7'b0;
    else if (ds_to_es_valid && es_allowin)
        es_md_op <= md_op;
end

always @(posedge clk) begin
    if (reset)
        es_valid <= 1'b0;
    else if (es_allowin)
        es_valid <= ds_to_es_valid;

    if (ds_to_es_valid && es_allowin) begin
        es_pc           <= ds_pc;
        es_alu_op       <= alu_op;
        es_alu_src1     <= ds_alu_src1;
        es_alu_src2     <= ds_alu_src2;
        es_res_from_mem <= res_from_mem;
        es_gr_we        <= gr_we;
        es_mem_we       <= mem_we;
        es_dest         <= dest;
        es_rkd_value    <= rkd_value;
    end
end

//==========================================================
// EXE：ALU运算及数据RAM请求
//==========================================================
// 原ALU实例迁移到此处，输入全部来自同一条EXE指令。
alu u_alu(
    .alu_op     (es_alu_op),
    .alu_src1   (es_alu_src1),
    .alu_src2   (es_alu_src2),
    .alu_result (es_alu_result)
);

// 【实践10修改】EX按有效位和md_op识别乘除法，并选择有符号除法及商/余数结果。
assign es_is_mul = es_valid && (|es_md_op[2:0]);
assign es_is_div = es_valid && (|es_md_op[6:3]);
assign es_div_signed = es_md_op[3] | es_md_op[4];
assign es_div_remainder = es_md_op[4] | es_md_op[6];

// exp10_mul33必须配置为33x33有符号、66位输出、PipeStages=0。
// 【实践10修改】新增组合乘法单元，使用EX锁存的两个操作数，由md_op选择有符号/无符号模式。
mul_unit u_mul_unit(
    .src1        (es_alu_src1),
    .src2        (es_alu_src2),
    .signed_mode (es_md_op[0] | es_md_op[1]),
    .product     (mul_product)
);

// 【实践10修改】新增多周期除法单元；done解除EX等待，结果仅在es_fire时消费，避免重复提交。
div_unit u_div_unit(
    .clk         (clk),
    .reset       (reset),
    .resetn      (resetn),
    .enable      (es_is_div),
    .signed_mode (es_div_signed),
    .dividend    (es_alu_src1),
    .divisor     (es_alu_src2),
    .consume     (es_fire && es_is_div),
    .done        (div_done),
    .quotient    (div_quotient),
    .remainder   (div_remainder)
);

// 【实践10修改】mul.w取积低32位，mulh取高32位；div/mod选择商或余数，再与ALU结果统一选择。
assign es_mul_result = es_md_op[0] ? mul_product[31:0] : mul_product[63:32];
assign es_div_result = es_div_remainder ? div_remainder : div_quotient;
assign es_exec_result = es_is_mul ? es_mul_result :
                        es_is_div ? es_div_result : es_alu_result;

// EXE驱动访存地址和store数据，RAM在进入MEM的沿上接收。
// 仅有效load/store拉高片选，仅有效store使四个字节全部可写。
// 即使es_mem_we残留为1，无效槽或复位期间也不会产生写请求。
// 【实践10修改】RAM片选和写使能由es_valid改为es_fire限定，仅在EX实际向MEM传递时发出访存请求。
assign data_sram_en    = resetn && !reset && es_fire
                      && (es_res_from_mem || es_mem_we);
assign data_sram_we    = {4{resetn && !reset && es_fire && es_mem_we}};
assign data_sram_addr  = es_alu_result;
assign data_sram_wdata = es_rkd_value;

//==========================================================
// EXE -> MEM：传递统一执行结果及其配套写回信息
//==========================================================
// load标志与PC、目的寄存器同步传递；store请求已完成，无需再传写数据。
// 【实践10修改】沿用ms_alu_result寄存器名，内容扩展为ALU/乘法/除法的统一执行结果。
reg [31:0] ms_pc, ms_alu_result; // ms_alu_result也保存乘法或除法结果。

always @(posedge clk) begin
    if (reset)
        ms_valid <= 1'b0;
    else if (ms_allowin)
        ms_valid <= es_to_ms_valid;

    if (es_to_ms_valid && ms_allowin) begin
        ms_pc           <= es_pc;
        // 【实践10修改】MEM结果寄存器输入由es_alu_result改为es_exec_result，后续MEM/WB沿用原写回通路。
        ms_alu_result   <= es_exec_result;
        ms_res_from_mem <= es_res_from_mem;
        ms_gr_we        <= es_gr_we;
        ms_dest         <= es_dest;
    end
end

//==========================================================
// MEM：接收同步RAM返回并选择最终结果
//==========================================================
// 原单周期final_result选择逻辑移至MEM。
// RAM返回值与ms_res_from_mem对应同一条load，不可在EXE提前使用，
// 也无需再额外延迟一拍；非load使用传入的ms_alu_result。

assign ms_final_result = ms_res_from_mem ? data_sram_rdata : ms_alu_result;

//==========================================================
// MEM -> WB：锁存最终结果、目的寄存器、写回控制和PC
//==========================================================
// PC、控制和数据必须跨过相同数量的级间寄存器，确保写回信息对应。

reg [31:0] ws_pc;

always @(posedge clk) begin
    if (reset)
        ws_valid <= 1'b0;
    else if (ws_allowin)
        ws_valid <= ms_to_ws_valid;

    if (ms_to_ws_valid && ws_allowin) begin
        ws_pc           <= ms_pc;
        ws_gr_we        <= ms_gr_we;
        ws_dest         <= ms_dest;
        ws_final_result <= ms_final_result;
    end
end

//==========================================================
// WB：寄存器写回与debug输出
//==========================================================
// 原gr_we && valid改为WB级有效位约束，写端口只使用ws_*信息。
// 复位期间禁止写寄存器，防止流水寄存器残留控制信号造成副作用。
assign rf_we    = resetn && !reset && ws_valid && ws_gr_we;
assign rf_waddr = ws_dest;
assign rf_wdata = ws_final_result;

// debug输出统一来自同一条WB指令，不再输出取指PC。
// 四位debug写使能复制真实rf_we；目的寄存器为r0时沿用原接口约定，
// regfile读r0恒为0，测试平台在trace比对时忽略写r0的记录。
assign debug_wb_pc       = ws_pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = ws_dest;
assign debug_wb_rf_wdata = ws_final_result;

endmodule
