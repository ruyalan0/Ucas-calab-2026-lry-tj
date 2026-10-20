
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
    // 【实践13修改】八路高有效外部硬中断，映射到ESTAT.IS[9:2]。
    input  wire [ 7:0] hw_int_in,
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
reg [63:0] stable_counter;
always @(posedge clk) reset <= ~resetn;

// 【实践13修改】稳定计数器只受CPU复位影响，不受流水暂停、异常或ertn影响。
always @(posedge clk) begin
    if (reset)
        stable_counter <= 64'b0;
    else
        stable_counter <= stable_counter + 64'd1;
end

//==========================================================
// 流水线有效位与级间传递控制
//==========================================================
// 每一级独立的valid替代原全局valid，表示本级是否有有效指令。
// 无效槽的数据允许残留，但不能触发分支、写内存或写寄存器。
reg fs_valid, ds_valid, es_valid, ms_valid, ws_valid;
wire fs_ready_go, ds_ready_go, es_ready_go, ms_ready_go, ws_ready_go;
wire fs_allowin, ds_allowin, es_allowin, ms_allowin, ws_allowin;
wire fs_to_ds_valid, ds_to_es_valid, es_to_ms_valid, ms_to_ws_valid;
// 【实践12修改】系统调用异常和ertn在WB统一提交，并对全流水线执行精确冲刷。
wire wb_ex, ertn_flush, pipeline_flush;
wire [31:0] redirect_target;
// ID级暂停、分支生效及错误顺序指令取消信号。
wire ds_raw_stall;//ID 级因为 RAW 数据相关而需要暂停
wire ds_br_cond, br_taken_cancel;
//ds_br_cond：当前 ID 指令在语义上是否要求跳转。
//br_taken_cancel：跳转正式生效时，取消已经取到的顺序下一条指令。


reg es_res_from_mem, es_res_from_csr, es_gr_we, es_mem_we;
reg es_csr_we, es_syscall, es_ertn;
reg [4:0] es_dest;
reg [13:0] es_csr_num;
reg [31:0] es_csr_wmask, es_csr_wvalue;
reg ms_res_from_mem, ms_res_from_csr, ms_gr_we;
reg ms_csr_we, ms_syscall, ms_ertn;
reg [4:0] ms_dest;
reg [13:0] ms_csr_num;
reg [31:0] ms_csr_wmask, ms_csr_wvalue;
reg ws_res_from_csr, ws_gr_we, ws_csr_we, ws_syscall, ws_ertn;
reg [4:0] ws_dest;
reg [13:0] ws_csr_num;
reg [31:0] ws_csr_wmask, ws_csr_wvalue;
// 【实践13时序优化】CSR状态写者在ID预译码为1位标志，随流水线传递。
reg es_csr_state_writer_flag;
reg ms_csr_state_writer_flag;
reg ws_csr_state_writer_flag;

// 【实践11新增】访存宽度和无符号标志随指令传递，MEM保存本条load的地址低位。
localparam [1:0] MEM_BYTE = 2'b00, MEM_HALF = 2'b01, MEM_WORD = 2'b10;
wire [1:0] ds_mem_size;
wire ds_load_unsigned;
reg [1:0] es_mem_size, ms_mem_size, ms_addr_low;
reg es_load_unsigned, ms_load_unsigned;
wire [3:0] es_store_mask;
wire [7:0] ms_load_byte;
wire [15:0] ms_load_half;
wire [31:0] ms_load_result;

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
reg  [31:0] ms_alu_result; // MEM寄存后的ALU/乘法/除法结果，也供分支前递。
reg  [31:0] ws_final_result;
wire [31:0] ws_writeback_result;
wire [31:0] csr_rvalue, ex_entry, ertn_entry;
wire csr_commit_we, has_int;
wire older_redirect_in_ms, older_redirect_in_ws;
wire es_mem_access_allowed;

// 【实践13修改】异常标志独立传递；INT的Ecode为0，不能用Ecode非零代替有效位。
localparam integer EXC_INT  = 0;
localparam integer EXC_ADEF = 1;
localparam integer EXC_SYS  = 2;
localparam integer EXC_BRK  = 3;
localparam integer EXC_INE  = 4;
localparam integer EXC_ALE  = 5;
reg  [5:0] es_excp, ms_excp, ws_excp;
wire [5:0] ds_excp, es_excp_with_ale;
wire ds_excp_any, es_excp_any, es_excp_any_with_ale;
wire ms_excp_any, ws_excp_any;
wire es_ale;
reg  [31:0] ms_vaddr, ws_vaddr;
wire [5:0] wb_ecode;
wire [8:0] wb_esubcode;
wire [31:0] wb_vaddr;

// 【实践13修改】ID在状态相关屏障排空后才依据最新CSR状态标记中断。
wire ds_csr_state_stall;
wire ds_csr_state_writer;
wire es_csr_state_writer, ms_csr_state_writer, ws_csr_state_writer;
wire ds_inst_known, ds_ine;

// 【实践13修改】rdcntvl/vh读取独立、持续运行的64位稳定计数器。
reg es_rdcntvl, es_rdcntvh;
wire [31:0] es_counter_result;


assign fs_ready_go = 1'b1;
assign ds_ready_go = !ds_csr_state_stall && (ds_excp_any || !ds_raw_stall);
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
assign es_fire = es_to_ms_valid && ms_allowin && !pipeline_flush;

//==========================================================
// Pre-IF：提前生成同步指令RAM的请求地址
//==========================================================
reg  [31:0] fs_pc;
wire [31:0] seq_pc, nextpc;
wire [31:0] ds_br_target;
wire        to_fs_valid;
wire        fetch_accept, fetch_adef, jirl_redirect;
reg         fs_adef, ds_adef;


assign seq_pc = fs_pc + 32'd4;
assign nextpc = br_taken_cancel ? ds_br_target : seq_pc;
assign to_fs_valid = resetn && !reset;

// 原inst_sram_addr=pc改为nextpc，提前向同步RAM发请求。
// 片选与IF有效位、PC更新使用同一条件，保证PC与RAM返回值一一对应。
// 同时检查resetn和reset，外部复位刚拉低、内部reset尚未更新时也禁止请求。

// 【实践13时序优化】只有jirl能产生新的非对齐目标；顺序取指沿用当前ADEF状态。
// 避免把所有条件分支比较结果再送入nextpc低位的ADEF检测逻辑。
assign fetch_accept    = to_fs_valid && fs_allowin && !pipeline_flush;
assign fetch_adef      = jirl_redirect ? (|ds_br_target[1:0]) : fs_adef;
assign inst_sram_en    = fetch_accept && !fetch_adef;
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
        fs_adef  <= 1'b0;
    end
    // 【实践12修改】同步取指采用一拍保守重启，保存目标减4以复用原seq_pc逻辑。
    else if (pipeline_flush) begin
        fs_valid <= 1'b0;
        fs_pc    <= redirect_target - 32'd4;
        // EENTRY通常对齐；软件可写ERA仍需保留非对齐返回地址的ADEF检测。
        fs_adef  <= |redirect_target[1:0];
    end
    else if (fs_allowin) begin
        fs_valid <= fetch_accept;
        if (fetch_accept) begin
            fs_pc <= nextpc;
            fs_adef <= fetch_adef;
        end
    end
    // 预留IF不允许接收时的分支取消逻辑；当前跳转生效时fs_allowin为1。
    else if (br_taken_cancel) begin
        // 若后续修改取指握手使此分支可达，则取消旧IF槽。
        fs_valid <= 1'b0;
        fs_adef  <= 1'b0;
    end
end

// 下一上升沿将RAM返回指令和对应fs_pc一起送入ID。
// 非阻塞赋值在沿上读取旧值，不会把下一条返回指令配给当前PC。
// 各级统一规则：复位清valid；允许接收时更新valid；
// 前级有效且本级允许接收时更新数据。无效数据无需复位清零。
always @(posedge clk) begin
    if (reset) begin
        ds_valid <= 1'b0;
        ds_adef  <= 1'b0;
    end
    else if (pipeline_flush) begin
        ds_valid <= 1'b0;
        ds_adef  <= 1'b0;
    end
    // 跳转生效时清除已经取到的错误顺序指令。
    else if (br_taken_cancel) begin
        ds_valid <= 1'b0; 
        ds_adef  <= 1'b0;
    end
    else if (ds_allowin)
        ds_valid <= fs_to_ds_valid;

    if (fs_to_ds_valid && ds_allowin) begin
        ds_pc   <= fs_pc;
        ds_inst <= fs_adef ? 32'b0 : inst_sram_rdata;
        ds_adef <= fs_adef;
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
wire        res_from_csr;
wire        csr_we;
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

// 【实践12修改】新增3条CSR指令、ertn和syscall。
wire inst_csr, inst_csrrd, inst_csrwr, inst_csrxchg;
wire inst_ertn, inst_syscall;
// 【实践13修改】新增break与三条计时器读取指令。
wire inst_break, inst_rdcntvl, inst_rdcntvh, inst_rdcntid;
wire [13:0] ds_csr_num;
wire [31:0] ds_csr_wmask, ds_csr_wvalue;

// 【实践11新增】新增4条条件分支及6条窄访存指令。
wire inst_blt, inst_bge, inst_bltu, inst_bgeu;
wire inst_ld_b, inst_ld_h, inst_ld_bu, inst_ld_hu, inst_st_b, inst_st_h;
wire ds_is_load, ds_is_store, ds_is_cond_branch;
wire ds_br_lt_signed, ds_br_lt_unsigned;

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
wire ds_branch_ms_load_stall;
// 【实践10修改】新增ID依赖未完成EX除法结果时的暂停信号。
wire ds_div_use_stall;
wire ds_csr_use_stall;

wire ds_rj_fwd_es,  ds_rj_fwd_ms,  ds_rj_fwd_ws;
wire ds_rkd_fwd_es, ds_rkd_fwd_ms, ds_rkd_fwd_ws;
wire es_pending_write, ms_pending_write, ws_pending_write;//对应流水级是否存在一条尚未完成寄存器写回的有效指令
wire ds_rj_raw_es, ds_rj_raw_ms, ds_rj_raw_ws;//rj与后三级存在RAW相关
wire ds_rkd_raw_es, ds_rkd_raw_ms, ds_rkd_raw_ws;//rkd与后三级存在RAW相关
wire ms_result_available;

wire rj_eq_rd;
// 【实践10修改】新增分支专用操作数，独立于包含EX乘除法结果的通用前递通路。
wire [31:0] ds_br_rj_value, ds_br_rkd_value;
wire ds_br_rj_fwd_ms, ds_br_rkd_fwd_ms;
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
// 【实践11新增】分支仅译码高6位；窄访存保留12位有符号地址偏移。
assign inst_blt    = op_31_26_d[6'h18];
assign inst_bge    = op_31_26_d[6'h19];
assign inst_bltu   = op_31_26_d[6'h1a];
assign inst_bgeu   = op_31_26_d[6'h1b];
assign inst_ld_b   = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
assign inst_ld_h   = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
assign inst_ld_bu  = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
assign inst_ld_hu  = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
assign inst_st_b   = op_31_26_d[6'h0a] & op_25_22_d[4'h4];
assign inst_st_h   = op_31_26_d[6'h0a] & op_25_22_d[4'h5];
assign ds_is_load = inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
assign ds_is_store = inst_st_w | inst_st_b | inst_st_h;
assign ds_is_cond_branch = inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu;
assign ds_mem_size = (inst_ld_b | inst_ld_bu | inst_st_b) ? MEM_BYTE :
                     (inst_ld_h | inst_ld_hu | inst_st_h) ? MEM_HALF : MEM_WORD;
assign ds_load_unsigned = inst_ld_bu | inst_ld_hu;
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

// 【实践12修改】CSR按高8位译码；syscall保留低15位code，不制造GPR源依赖。
assign inst_csr     = ds_inst[31:24] == 8'h04;
assign inst_csrrd   = inst_csr && (rj == 5'd0);
assign inst_csrwr   = inst_csr && (rj == 5'd1);
assign inst_csrxchg = inst_csr && (rj != 5'd0) && (rj != 5'd1);
assign inst_ertn    = ds_inst == 32'h06483800;
assign inst_syscall = (ds_inst & 32'hffff8000) == 32'h002b0000;
// 【实践13修改】严格约束编码，避免宽松译码吞掉INE。
assign inst_break   = (ds_inst & 32'hffff8000) == 32'h002a0000;
assign inst_rdcntvl = (ds_inst & 32'hffffffe0) == 32'h00006000;
assign inst_rdcntvh = (ds_inst & 32'hffffffe0) == 32'h00006400;
assign inst_rdcntid = ((ds_inst & 32'hfffffc1f) == 32'h00006000)
                     && (rj != 5'd0);
assign ds_csr_num   = inst_rdcntid ? 14'h0040 : ds_inst[23:10];

// 【实践13修改】白名单覆盖原51条和4条新增指令；零指令必须按INE处理。
assign ds_inst_known = inst_add_w | inst_sub_w | inst_slt | inst_sltu
                    | inst_nor | inst_and | inst_or | inst_xor
                    | inst_slli_w | inst_srli_w | inst_srai_w | inst_addi_w
                    | inst_ld_w | inst_st_w | inst_jirl | inst_b | inst_bl
                    | inst_beq | inst_bne | inst_lu12i_w
                    | inst_slti | inst_sltui | inst_andi | inst_ori | inst_xori
                    | inst_sll_w | inst_srl_w | inst_sra_w | inst_pcaddu12i
                    | inst_mul_w | inst_mulh_w | inst_mulh_wu
                    | inst_div_w | inst_mod_w | inst_div_wu | inst_mod_wu
                    | inst_blt | inst_bge | inst_bltu | inst_bgeu
                    | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu
                    | inst_st_b | inst_st_h
                    | inst_csr | inst_ertn | inst_syscall
                    | inst_break | inst_rdcntvl | inst_rdcntvh | inst_rdcntid;
assign ds_ine = ds_valid && !ds_adef && !ds_inst_known;
assign ds_excp = {1'b0, ds_ine, inst_break, inst_syscall,
                  ds_adef, has_int};
assign ds_excp_any = ds_valid && (|ds_excp);

// 【实践10修改】将7条乘除法指令编码为独热md_op；[2:0]控制乘法，[6:3]控制除法/取余。
assign md_op = {inst_mod_wu, inst_div_wu, inst_mod_w, inst_div_w,
                inst_mulh_wu, inst_mulh_w, inst_mul_w};

// ALU控制依次为加、减、有符号/无符号比较、与、或非、或、异或、
// 逻辑左移、逻辑右移、算术右移和高位立即数装载。
// load/store用加法算有效地址；jirl/bl用加法算链接地址PC+4。
// 【实践10修改】扩展ALU选择条件：pcaddu12i复用加法，新增立即数和寄存器移位指令复用原运算。
// 【实践11修改】全部访存复用加法和立即数，源寄存器及写回控制使用统一分类。
assign alu_op[ 0] = inst_add_w | inst_addi_w | ds_is_load | ds_is_store
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
// 【实践11修改】窄访存沿用12位有符号偏移，新增条件分支沿用16位分支偏移。
assign need_si12  =  inst_addi_w | ds_is_load | ds_is_store | inst_slti | inst_sltui;
assign need_si16  =  inst_jirl | ds_is_cond_branch;
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

// 【实践11修改】全部条件分支读取rd用于比较，全部store读取rd作为写数据。
assign src_reg_is_rd = ds_is_cond_branch | ds_is_store | inst_csrwr | inst_csrxchg;

// 【实践10修改】源1的PC选择加入pcaddu12i；源2立即数选择加入5条立即数指令及pcaddu12i。
assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;

// 【实践11修改】立即数源选择覆盖全部load/store指令。
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
                       ds_is_load  |
                       ds_is_store |
                       inst_lu12i_w|
                       inst_jirl   |
                       inst_bl     ;

// 【实践11修改】访存写回及写使能控制由单条字指令扩展为统一的load/store分类。
assign res_from_mem  = ds_is_load;
assign res_from_csr  = inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid;
assign csr_we        = inst_csrwr | inst_csrxchg;
assign ds_csr_wvalue = rkd_value;
assign ds_csr_wmask  = inst_csrwr ? 32'hffffffff : rj_value;
assign dst_is_r1     = inst_bl;

// 沿用实践6修正：bl需要写r1；store及非链接分支不写寄存器。
// gr_we仅表示译码写回意图，真实写使能在WB结合valid及复位生成。
assign gr_we         = (((|alu_op) && !ds_is_store) || (|md_op) || res_from_csr
                     || inst_rdcntvl || inst_rdcntvh);
assign mem_we        = ds_is_store;
assign dest          = inst_rdcntid ? rj : (dst_is_r1 ? 5'd1 : rd);

assign rf_raddr1 = rj;
assign rf_raddr2 = src_reg_is_rd ? rd :rk;

// 按指令语义标记真实源：jirl读rj，store还读rd；立即数字段不算源。
// 【实践10修改】真实源检测覆盖新增指令：立即数运算读rj，寄存器移位和乘除法读rj/rk；pcaddu12i不读寄存器。
// 【实践11修改】真实源检测扩展到全部load/store及新增条件分支。
assign ds_use_rj = inst_add_w || inst_sub_w || inst_slt || inst_sltu
                || inst_nor || inst_and || inst_or || inst_xor
                || inst_slli_w || inst_srli_w || inst_srai_w
                || inst_addi_w || ds_is_load || ds_is_store
                || inst_slti || inst_sltui || inst_andi || inst_ori || inst_xori
                || inst_sll_w || inst_srl_w || inst_sra_w || (|md_op)
                || inst_jirl || ds_is_cond_branch || inst_csrxchg;
assign ds_use_rkd = inst_add_w || inst_sub_w || inst_slt || inst_sltu
                 || inst_nor || inst_and || inst_or || inst_xor
                 || inst_sll_w || inst_srl_w || inst_sra_w || (|md_op)
                 || ds_is_store || ds_is_cond_branch || inst_csrwr || inst_csrxchg;

// 标记EXE/MEM/WB中的在途写回；无效槽、非写回指令及r0不产生依赖。
// MEM/WB的gr_we已在级间寄存器入口固化异常资格，避免异常信号扩散到前递网络。
// WB仍算在途写回，因为寄存器堆要到当前上升沿才完成写入。
assign es_pending_write = es_valid && es_gr_we && !es_excp_any_with_ale
                       && (es_dest != 5'd0);
assign ms_pending_write = ms_valid && ms_gr_we
                       && (ms_dest != 5'd0);
assign ws_pending_write = ws_valid && ws_gr_we
                       && (ws_dest != 5'd0);

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

// 【实践11修改】新增分支同样等待EX写者，保持分支专用MEM/WB前递通路。
assign ds_is_reg_branch = ds_is_cond_branch | inst_jirl;

// EX只前递已完成的非load结果，寄存器型转移仍等待MEM。
// 最新EX写者未就绪时屏蔽MEM/WB中的同名旧值，并由RAW暂停阻止接收。
// 【实践10修改】EX前递由非load扩展为非load且除法已完成；MEM排除EX同名写者，WB排除EX/MEM同名写者，避免前递旧值。
assign es_result_available = !es_excp_any_with_ale
                           && !es_res_from_mem && !es_res_from_csr
                           && (!es_is_div || div_done);
assign ms_result_available = !ms_res_from_csr;
assign ds_rj_fwd_es  = ds_rj_raw_es && es_result_available && !ds_is_reg_branch;
assign ds_rj_fwd_ms  = ds_rj_raw_ms && ms_result_available && !ds_rj_raw_es;
assign ds_rj_fwd_ws  = ds_rj_raw_ws && !ds_rj_raw_es && !ds_rj_raw_ms;
assign ds_rkd_fwd_es = ds_rkd_raw_es && es_result_available && !ds_is_reg_branch;
assign ds_rkd_fwd_ms = ds_rkd_raw_ms && ms_result_available && !ds_rkd_raw_es;
assign ds_rkd_fwd_ws = ds_rkd_raw_ws && !ds_rkd_raw_es && !ds_rkd_raw_ms;

assign ds_load_use_stall = es_res_from_mem && (ds_rj_raw_es || ds_rkd_raw_es);
// 分支等待EX写者；MEM非load仍前递，MEM load相关分支额外等待到WB。
assign ds_branch_ex_stall = ds_is_reg_branch &&
                            (ds_rj_raw_es || ds_rkd_raw_es);
// 【实践13时序优化】仅最新MEM load写者阻塞相关分支，避免数据RAM直通分支/取指。
assign ds_branch_ms_load_stall = ds_is_reg_branch && ms_res_from_mem
                               && ((ds_rj_raw_ms && !ds_rj_raw_es)
                                || (ds_rkd_raw_ms && !ds_rkd_raw_es));
// 【实践10修改】在原load-use和分支依赖暂停外，新增依赖未完成除法的暂停，并汇总到ds_raw_stall。
assign ds_div_use_stall = es_is_div && !div_done && (ds_rj_raw_es || ds_rkd_raw_es);
// 【实践12修改】CSR返回值到WB才可用；逐源检查最新写者，防止退用旧MEM/WB值。
assign ds_csr_use_stall = (es_res_from_csr && (ds_rj_raw_es || ds_rkd_raw_es))
                       || (ms_res_from_csr
                           && ((ds_rj_raw_ms && !ds_rj_raw_es)
                            || (ds_rkd_raw_ms && !ds_rkd_raw_es)));
// 非相关ID指令也受es_allowin约束，不能在除法等待期间提前跳转。
assign ds_raw_stall = ds_load_use_stall || ds_branch_ex_stall
                   || ds_branch_ms_load_stall || ds_div_use_stall || ds_csr_use_stall;

// 【实践13时序优化】影响中断判定的CSR在ID只译码一次，后三级仅传递1位标志，
// 避免EX/MEM/WB各自重复14位CSR号比较造成面积和布线压力。
assign ds_csr_state_writer = inst_ertn ||
    (csr_we && ((ds_csr_num == 14'h0000) || (ds_csr_num == 14'h0004) ||
                (ds_csr_num == 14'h0005) || (ds_csr_num == 14'h0041) ||
                (ds_csr_num == 14'h0044)));
assign es_csr_state_writer = es_valid && es_csr_state_writer_flag;
assign ms_csr_state_writer = ms_valid && ms_csr_state_writer_flag;
assign ws_csr_state_writer = ws_valid && ws_csr_state_writer_flag;
assign ds_csr_state_stall = es_csr_state_writer || ms_csr_state_writer
                         || ws_csr_state_writer;


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
                  ds_rj_fwd_ws ? ws_writeback_result :
                                 rf_rdata1;

// 【实践10修改】rk/rd的EX前递源同样改为统一执行结果，供后续运算及store数据使用。
assign rkd_value = ds_rkd_fwd_es ? es_exec_result :
                   ds_rkd_fwd_ms ? ms_final_result :
                   ds_rkd_fwd_ws ? ws_writeback_result :
                                   rf_rdata2;

// 操作数就绪且分支能离开ID时才重定向，并取消旧IF对应的ID槽。
// 分支仍进入EX，bl/jirl正常写回链接值；不清除后三级或目标IF。
// 【实践10修改】分支比较改用独立MEM/WB/寄存器堆选择器，切断EX乘法器/ALU经分支通向取指的组合路径。
// 【实践13时序优化】分支MEM前递直接取寄存后的执行结果，不经过含RAM数据的最终结果选择器。
// load在MEM不参与分支前递，到WB后使用已锁存的ws_writeback_result。
assign ds_br_rj_fwd_ms = ds_rj_fwd_ms && !ms_res_from_mem;
assign ds_br_rkd_fwd_ms = ds_rkd_fwd_ms && !ms_res_from_mem;
assign ds_br_rj_value = ds_br_rj_fwd_ms ? ms_alu_result :
                        ds_rj_fwd_ws ? ws_writeback_result : rf_rdata1;
assign ds_br_rkd_value = ds_br_rkd_fwd_ms ? ms_alu_result :
                         ds_rkd_fwd_ws ? ws_writeback_result : rf_rdata2;
assign rj_eq_rd = (ds_br_rj_value == ds_br_rkd_value);
// 【实践11新增】显式区分有符号和无符号比较，避免相减溢出影响分支。
assign ds_br_lt_signed = ($signed(ds_br_rj_value) < $signed(ds_br_rkd_value));
assign ds_br_lt_unsigned = (ds_br_rj_value < ds_br_rkd_value);
// 【实践11修改】分支成立条件加入blt、bge、bltu和bgeu。
assign ds_br_cond = (inst_beq && rj_eq_rd)
                || (inst_bne && !rj_eq_rd)
                || (inst_blt && ds_br_lt_signed)
                || (inst_bge && !ds_br_lt_signed)
                || (inst_bltu && ds_br_lt_unsigned)
                || (inst_bgeu && !ds_br_lt_unsigned)
                || inst_jirl || inst_bl || inst_b;
assign br_taken_cancel = resetn && !reset && !pipeline_flush
                       && ds_to_es_valid && es_allowin && ds_br_cond;
assign jirl_redirect = resetn && !reset && !pipeline_flush
                     && ds_to_es_valid && es_allowin && inst_jirl;


// PC相对目标必须基于ds_pc；jirl目标为rj+偏移，不能混用IF级PC。
// 【实践10修改】jirl目标基址由通用rj_value改为分支专用ds_br_rj_value，PC相对分支保持不变。
// 【实践11修改】新增条件分支与beq/bne共用PC相对目标计算。
assign ds_br_target = (ds_is_cond_branch || inst_bl || inst_b) ? (ds_pc + br_offs) :
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
    else if (pipeline_flush)
        es_md_op <= 7'b0;
    else if (ds_to_es_valid && es_allowin)
        es_md_op <= md_op;
end

always @(posedge clk) begin
    if (reset)
        es_valid <= 1'b0;
    else if (pipeline_flush)
        es_valid <= 1'b0;
    else if (es_allowin)
        es_valid <= ds_to_es_valid;

    if (ds_to_es_valid && es_allowin) begin
        es_pc           <= ds_pc;
        es_alu_op       <= alu_op;
        es_alu_src1     <= ds_alu_src1;
        es_alu_src2     <= ds_alu_src2;
        es_res_from_mem <= res_from_mem;
        es_res_from_csr <= res_from_csr;
        // 【实践11新增】元数据与本条指令一同锁存，EX暂停时保持。
        es_mem_size     <= ds_mem_size;
        es_load_unsigned <= ds_load_unsigned;
        es_gr_we        <= gr_we;
        es_mem_we       <= mem_we;
        es_dest         <= dest;
        es_rkd_value    <= rkd_value;
        // 【实践12修改】CSR/异常元数据只随有效指令前进，暂停时保持。
        es_csr_we       <= csr_we;
        es_csr_num      <= ds_csr_num;
        es_csr_wmask    <= ds_csr_wmask;
        es_csr_wvalue   <= ds_csr_wvalue;
        es_syscall      <= inst_syscall;
        es_ertn         <= inst_ertn;
        es_csr_state_writer_flag <= ds_csr_state_writer;
        // 【实践13修改】中断决定与静态异常只在ID实际发射沿锁存。
        es_excp         <= ds_excp;
        es_rdcntvl      <= inst_rdcntvl;
        es_rdcntvh      <= inst_rdcntvh;
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
assign es_excp_any = es_valid && (|es_excp);
// 【实践13修改】异常令牌上的乘除法不启动、不等待。
assign es_is_mul = es_valid && !es_excp_any && (|es_md_op[2:0]);
assign es_is_div = es_valid && !es_excp_any && (|es_md_op[6:3]);
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
    // 【实践12修改】异常冲刷复用局部复位，清除年轻在途除法及IP返回。
    .reset       (reset || pipeline_flush),
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
assign es_counter_result = es_rdcntvh ? stable_counter[63:32]
                                      : stable_counter[31:0];
assign es_exec_result = (es_rdcntvl || es_rdcntvh) ? es_counter_result :
                        es_is_mul ? es_mul_result :
                        es_is_div ? es_div_result : es_alu_result;

// 【实践13修改】ALE在EX使用完整有效地址检测，早期异常优先且当拍取消访存。
assign es_ale = es_valid && !es_excp_any
             && (es_res_from_mem || es_mem_we)
             && (((es_mem_size == MEM_WORD) && (es_alu_result[1:0] != 2'b00))
              || ((es_mem_size == MEM_HALF) && es_alu_result[0]));
assign es_excp_with_ale = {es_ale, es_excp[EXC_INE:EXC_INT]};
assign es_excp_any_with_ale = es_valid && (|es_excp_with_ale);

// EXE驱动访存地址和store数据，RAM在进入MEM的沿上接收。
// 【实践11修改】仅有效load/store拉高片选，store按宽度选择字节通道。
// 即使es_mem_we残留为1，无效槽或复位期间也不会产生写请求。
// 【实践10修改】RAM片选和写使能由es_valid改为es_fire限定，仅在EX实际向MEM传递时发出访存请求。
// 【实践12修改】较老syscall/ertn进入MEM后即禁止年轻访存，避免WB冲刷前产生副作用。
assign older_redirect_in_ms = ms_valid && (ms_excp_any || ms_ertn);
assign older_redirect_in_ws = ws_valid && (ws_excp_any || ws_ertn);
assign es_mem_access_allowed = resetn && !reset && !pipeline_flush && es_fire
                            && !es_excp_any_with_ale && !es_ertn
                            && !older_redirect_in_ms && !older_redirect_in_ws
                            && (es_res_from_mem || es_mem_we);
assign data_sram_en    = es_mem_access_allowed;
// 【实践11新增】依据store宽度和地址低位生成字节写掩码。
assign es_store_mask  = (es_mem_size == MEM_BYTE) ? (4'b0001 << es_alu_result[1:0]) :
                        (es_mem_size == MEM_HALF) ?
                            (es_alu_result[1] ? 4'b1100 : 4'b0011) : 4'b1111;
// 【实践11修改】数据RAM写使能由固定全字写改为按字节掩码写入。
assign data_sram_we    = {4{es_mem_access_allowed && es_mem_we}} & es_store_mask;
assign data_sram_addr  = es_alu_result;
// 【实践11修改】复制低字节/半字，由mask决定写入位置；地址保持完整字节地址。
assign data_sram_wdata = (es_mem_size == MEM_BYTE) ? {4{es_rkd_value[7:0]}} :
                         (es_mem_size == MEM_HALF) ? {2{es_rkd_value[15:0]}} : es_rkd_value;

//==========================================================
// EXE -> MEM：传递统一执行结果及其配套写回信息
//==========================================================
// load标志与PC、目的寄存器同步传递；store请求已完成，无需再传写数据。
// 【实践10修改】沿用ms_alu_result寄存器名，内容扩展为ALU/乘法/除法的统一执行结果。
reg [31:0] ms_pc;

always @(posedge clk) begin
    if (reset)
        ms_valid <= 1'b0;
    else if (pipeline_flush)
        ms_valid <= 1'b0;
    else if (ms_allowin)
        ms_valid <= es_to_ms_valid;

    if (es_to_ms_valid && ms_allowin) begin
        ms_pc           <= es_pc;
        // 【实践10修改】MEM结果寄存器输入由es_alu_result改为es_exec_result，后续MEM/WB沿用原写回通路。
        ms_alu_result   <= es_exec_result;
        ms_res_from_mem <= es_res_from_mem;
        ms_res_from_csr <= es_res_from_csr;
        // 【实践11新增】仅使用本条load的类型与地址低位进行MEM选通。
        ms_mem_size     <= es_mem_size;
        ms_load_unsigned <= es_load_unsigned;
        ms_addr_low     <= es_alu_result[1:0];
        // 【实践13时序优化】在EX/MEM边界固化异常资格，异常令牌进入MEM时已不可写GPR。
        ms_gr_we        <= es_gr_we && !es_excp_any_with_ale;
        ms_dest         <= es_dest;
        ms_csr_we       <= es_csr_we;
        ms_csr_num      <= es_csr_num;
        ms_csr_wmask    <= es_csr_wmask;
        ms_csr_wvalue   <= es_csr_wvalue;
        ms_syscall      <= es_syscall;
        ms_ertn         <= es_ertn;
        ms_csr_state_writer_flag <= es_csr_state_writer_flag;
        // 【实践13修改】ALE在进入MEM的沿并入异常令牌，同时保存完整错误地址。
        ms_excp         <= es_excp_with_ale;
        ms_vaddr        <= es_alu_result;
    end
end

//==========================================================
// MEM：接收同步RAM返回并选择最终结果
//==========================================================
// 原单周期final_result选择逻辑移至MEM。
// RAM返回值与ms_res_from_mem对应同一条load，不可在EXE提前使用，
// 也无需再额外延迟一拍；非load使用传入的ms_alu_result。

// 【实践11新增】小端选通及扩展在MEM完成，普通前递和分支前递均取得完整32位值。
assign ms_load_byte = (ms_addr_low == 2'b00) ? data_sram_rdata[7:0] :
                      (ms_addr_low == 2'b01) ? data_sram_rdata[15:8] :
                      (ms_addr_low == 2'b10) ? data_sram_rdata[23:16] : data_sram_rdata[31:24];
assign ms_load_half = ms_addr_low[1] ? data_sram_rdata[31:16] : data_sram_rdata[15:0];
assign ms_load_result = (ms_mem_size == MEM_BYTE) ?
                         (ms_load_unsigned ? {24'b0, ms_load_byte} : {{24{ms_load_byte[7]}}, ms_load_byte}) :
                        (ms_mem_size == MEM_HALF) ?
                         (ms_load_unsigned ? {16'b0, ms_load_half} : {{16{ms_load_half[15]}}, ms_load_half}) :
                         data_sram_rdata;
// 【实践11修改】load写回数据由原始RAM字扩展为按访存宽度处理后的结果。
assign ms_excp_any = ms_valid && (|ms_excp);
assign ms_final_result = ms_res_from_mem ? ms_load_result : ms_alu_result;

//==========================================================
// MEM -> WB：锁存最终结果、目的寄存器、写回控制和PC
//==========================================================
// PC、控制和数据必须跨过相同数量的级间寄存器，确保写回信息对应。

reg [31:0] ws_pc;

always @(posedge clk) begin
    if (reset)
        ws_valid <= 1'b0;
    else if (pipeline_flush)
        ws_valid <= 1'b0;
    else if (ws_allowin)
        ws_valid <= ms_to_ws_valid;

    if (ms_to_ws_valid && ws_allowin) begin
        ws_pc           <= ms_pc;
        ws_res_from_csr <= ms_res_from_csr;
        // 【实践13时序优化】继续在MEM/WB边界固化资格，使WB前递只依赖寄存后的写使能。
        ws_gr_we        <= ms_gr_we && !ms_excp_any;
        ws_dest         <= ms_dest;
        ws_final_result <= ms_final_result;
        ws_csr_we       <= ms_csr_we;
        ws_csr_num      <= ms_csr_num;
        ws_csr_wmask    <= ms_csr_wmask;
        ws_csr_wvalue   <= ms_csr_wvalue;
        ws_syscall      <= ms_syscall;
        ws_ertn         <= ms_ertn;
        ws_csr_state_writer_flag <= ms_csr_state_writer_flag;
        ws_excp         <= ms_excp;
        ws_vaddr        <= ms_vaddr;
    end
end

//==========================================================
// WB：寄存器写回与debug输出
//==========================================================
// 【实践13修改】WB统一提交六类异常；INT有效位独立于其零值Ecode。
assign ws_excp_any = ws_valid && (|ws_excp);
assign wb_ex          = resetn && !reset && ws_excp_any;
assign ertn_flush     = resetn && !reset && ws_valid && !ws_excp_any && ws_ertn;
assign pipeline_flush = wb_ex || ertn_flush;
assign redirect_target = wb_ex ? ex_entry : ertn_entry;

// 同条异常优先级：INT > ADEF > SYS > BRK > INE > ALE。
assign wb_ecode = ws_excp[EXC_INT]  ? 6'h00 :
                  ws_excp[EXC_ADEF] ? 6'h08 :
                  ws_excp[EXC_SYS]  ? 6'h0b :
                  ws_excp[EXC_BRK]  ? 6'h0c :
                  ws_excp[EXC_INE]  ? 6'h0d :
                  ws_excp[EXC_ALE]  ? 6'h09 : 6'h00;
assign wb_esubcode = 9'b0;
assign wb_vaddr = ws_excp[EXC_ADEF] ? ws_pc : ws_vaddr;

// CSR组合读取得写入前的旧值；软件写、异常保存和返回均在本周期末提交。
assign csr_commit_we = resetn && !reset && ws_valid && ws_csr_we
                     && !ws_excp_any && !ws_ertn;
csr u_csr(
    .clk          (clk),
    .reset        (reset),
    .csr_num      (ws_csr_num),
    .csr_we       (csr_commit_we),
    .csr_wmask    (ws_csr_wmask),
    .csr_wvalue   (ws_csr_wvalue),
    .csr_rvalue   (csr_rvalue),
    .wb_ex        (wb_ex),
    .wb_ecode     (wb_ecode),
    .wb_esubcode  (wb_esubcode),
    .wb_pc        (ws_pc),
    .wb_vaddr     (wb_vaddr),
    .ertn_flush   (ertn_flush),
    .hw_int_in    (hw_int_in),
    .has_int      (has_int),
    .ex_entry     (ex_entry),
    .ertn_entry   (ertn_entry)
);

assign ws_writeback_result = ws_res_from_csr ? csr_rvalue : ws_final_result;

// 原gr_we && valid改为WB级有效位约束，写端口只使用ws_*信息。
// 复位期间禁止写寄存器，防止流水寄存器残留控制信号造成副作用。
assign rf_we    = resetn && !reset && ws_valid && ws_gr_we && !pipeline_flush;
assign rf_waddr = ws_dest;
assign rf_wdata = ws_writeback_result;

// debug输出统一来自同一条WB指令，不再输出取指PC。
// 四位debug写使能复制真实rf_we；目的寄存器为r0时沿用原接口约定，
// regfile读r0恒为0，测试平台在trace比对时忽略写r0的记录。
assign debug_wb_pc       = ws_pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = ws_dest;
assign debug_wb_rf_wdata = ws_writeback_result;

endmodule
