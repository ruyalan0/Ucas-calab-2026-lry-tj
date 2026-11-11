
`timescale 1ns / 1ps
`default_nettype none




// 【实践15修改】沿用exp14类SRAM流水线，重命名为内部核，由AXI顶层封装。
module mycpu_core(
    input  wire        clk,
    input  wire        resetn,
    
    input  tri0 [ 7:0] hw_int_in,
    
    // req与addr_ok同时为1才接受地址，data_ok表示该请求的指令返回。
    //新增size,wr,addr_ok,data_ok,wstrb(字节写使能)
    output wire        inst_sram_req,
    output wire        inst_sram_wr,    
    output wire [ 1:0] inst_sram_size,  
    output wire [ 3:0] inst_sram_wstrb, 
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire        inst_sram_addr_ok, 
    input  wire        inst_sram_data_ok, 
    input  wire [31:0] inst_sram_rdata,
    
    // load/store均先等地址接受，再等data_ok；store不再视为发出即完成。
    output wire        data_sram_req,
    output wire        data_sram_wr,    
    output wire [ 1:0] data_sram_size,  
    output wire [ 3:0] data_sram_wstrb, 
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire        data_sram_addr_ok, 
    input  wire        data_sram_data_ok, 
    input  wire [31:0] data_sram_rdata,

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
// 64位自由运行计数器，与csr.v中的32位递减定时器各自独立。
// 本计数器只提供计时读数，不负责产生定时器中断，溢出后按64位自然回绕。
reg [63:0] stable_counter;
always @(posedge clk) reset <= ~resetn;

// 稳定计数器只受CPU复位影响，不受流水暂停、异常或ertn影响。
// 使用内部同步reset清零；正常工作时每拍加1，无需任何指令使能。
// rdcntvl/vh在EX期间选择高/低半部，并在EX->MEM握手沿锁存沿前读数。
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
// 系统调用异常和ertn在WB统一提交，并对全流水线执行精确冲刷。
// wb_ex表示提交异常；ertn_flush表示提交异常返回；两者合成pipeline_flush。
// redirect_target是重启取指的目标；异常选EENTRY，返回选ERA，具体选择在WB定义。
wire wb_ex, ertn_flush, pipeline_flush;
wire [31:0] redirect_target;
// ID级暂停、分支生效及错误顺序指令取消信号。
wire ds_raw_stall;//ID 级因为 RAW 数据相关而需要暂停
wire ds_br_cond, br_taken_cancel;
//ds_br_cond：当前 ID 指令在语义上是否要求跳转。
//br_taken_cancel：跳转正式生效时，取消已经取到的顺序下一条指令。


// CSR控制与普通指令控制一起逐级保存，避免用ID的新指令控制WB旧指令。
// *_res_from_csr：最终GPR结果应在WB读取CSR，而不是取ALU或RAM结果。
// *_csr_we：写CSR的意图；*_csr_num/wmask/wvalue：编号、逐位写掩码及新数据。
// *_ertn随指令到WB才产生返回事件，不能在译码时直接修改CSR或切换PC。
// EX/MEM/WB的其余访存、GPR写使能和目的寄存器仍与同一条指令配对。
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
// CSR状态写者在ID预译码为1位标志，随流水线传递。
// 标志表示该指令可能改变中断判定状态，用于阻止年轻ID指令过早采样has_int。
// 未复位的数据位可以残留，使用时必须结合对应级valid，冲刷后不会形成假屏障。
reg es_csr_state_writer_flag;
reg ms_csr_state_writer_flag;
reg ws_csr_state_writer_flag;


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
wire [31:0] es_exec_result;
reg  [ 6:0] es_md_op;
wire es_is_mul, es_is_div, es_div_signed, es_div_remainder;
wire es_fire, es_result_available;
wire [63:0] mul_product;
wire [31:0] es_mul_result, es_div_result;
wire div_done;
wire [31:0] div_quotient, div_remainder;
wire [31:0] ms_final_result;
// ms_alu_result提前声明以供前递引用，内容仍由EX/MEM寄存器写入。
// 它也可能保存计数器结果；load的实际数据由MEM中的ms_load_result提供。
reg  [31:0] ms_alu_result; // MEM寄存后的ALU/乘法/除法结果，也供分支前递。
reg  [31:0] ws_final_result;
// ws_final_result仅包含普通执行/访存结果，下面再加入CSR结果选择。
// csr_rvalue为当前WB所选CSR的组合读值；ex_entry/ertn_entry来自CSR保存的入口/ERA。
// csr_commit_we是最终CSR提交使能，区别于流水中尚未提交的*_csr_we意图。
// has_int由CSR的pending、局部使能、全局IE共同决定；在ID发射时作为异常标志采样。
// older_redirect_in_ms/ws标记较老的异常/ertn，提前阻止年轻EX访存。

wire [31:0] ws_writeback_result;
wire [31:0] csr_rvalue, ex_entry, ertn_entry;
wire csr_commit_we, has_int;
wire older_redirect_in_ms, older_redirect_in_ws;
wire es_mem_access_allowed;

// 异常标志独立传递；INT的Ecode为0，不能用Ecode非零代替有效位。
// 这六个常量是异常向量的位下标，不是最终写入ESTAT的Ecode编码。
// [0]INT中断，[1]ADEF取指地址错误，[2]SYS系统调用，[3]BRK断点，
// [4]INE非法指令，[5]ALE访存地址对齐错误；最终优先级和Ecode在WB统一决定。
localparam integer EXC_INT  = 0;
localparam integer EXC_ADEF = 1;
localparam integer EXC_SYS  = 2;
localparam integer EXC_BRK  = 3;
localparam integer EXC_INE  = 4;
localparam integer EXC_ALE  = 5;
// ID产生前五类标志；EX计算访存地址后补入ALE，随后随指令传到WB。
// *_excp_any结合本级valid判断，不能让无效槽中的残留异常位产生事件。
reg  [5:0] es_excp, ms_excp, ws_excp;
wire [5:0] ds_excp, es_excp_with_ale;
wire ds_excp_any, es_excp_any, es_excp_any_with_ale;
wire ms_excp_any, ws_excp_any;
wire es_ale;
// 地址与异常向量同步保存：ALE使用EX有效地址；ADEF在WB直接使用该指令PC。
// wb_ecode/esubcode/vaddr分别是最终送入CSR的异常主码、子码和错误地址。
reg  [31:0] ms_vaddr, ws_vaddr;
wire [5:0] wb_ecode;
wire [8:0] wb_esubcode;
wire [31:0] wb_vaddr;

// ID在状态相关屏障排空后才依据最新CSR状态标记中断。
// ds_csr_state_writer是本条ID指令的预译码结果，后三个writer表示在途较老写者。
// ds_csr_state_stall与普通GPR的RAW暂停不同：即使寄存器不相关，也必须等状态提交。
// ds_inst_known是已实现指令的译码白名单，ds_ine表示有效指令不在白名单中。
wire ds_csr_state_stall;
wire ds_csr_state_writer;
wire es_csr_state_writer, ms_csr_state_writer, ws_csr_state_writer;
wire ds_inst_known, ds_ine;

// rdcntvl/vh读取独立、持续运行的64位稳定计数器。
// EX只需保存读高/读低标志，无需把64位计数器整体沿流水线传递。
reg es_rdcntvl, es_rdcntvh;
wire [31:0] es_counter_result;




reg  [31:0] fetch_pc;
reg  [31:0] fs_pc;
reg         fs_adef, ds_adef;

reg         fs_pending;
reg         fs_inst_buffer_valid;
reg  [31:0] fs_inst_buffer;
wire [31:0] ds_br_target;


wire        fetch_cancel, fetch_adef, fetch_accept, inst_addr_fire;

wire        fetch_can_issue, br_stall;
reg  [31:0] ds_pc, ds_inst;


reg ms_wait_data;


assign fs_ready_go = fs_adef || fs_inst_buffer_valid
                   || (fs_pending && inst_sram_data_ok);
// 先等待影响中断判定的较老CSR提交，再决定当前ID指令能否发射。
// 已有异常时无需再等待其普通GPR操作数，因为该槽最终只提交异常，不执行正常结果。
// 即使ds_excp_any为1，也仍受es_allowin限制，不能覆盖EX中未完成的旧指令。
assign ds_ready_go = !ds_csr_state_stall && (ds_excp_any || !ds_raw_stall);

// 正常load/store只有地址被接受才能离开EX；异常令牌和ertn不发请求也不等待。
assign es_ready_go = (!es_is_div || div_done)
                   && (!(es_res_from_mem || es_mem_we) || es_excp_any_with_ale
                       || es_ertn || (data_sram_req && data_sram_addr_ok));

// store响应被本条指令消费后才放行，避免后续load误用旧store的完成通知。
assign ms_ready_go = !ms_wait_data || data_sram_data_ok;
assign ws_ready_go = 1'b1;

// allowin：本级为空，或本级完成且下一级允许接收。
assign ws_allowin = !ws_valid || ws_ready_go;
assign ms_allowin = !ms_valid || (ms_ready_go && ws_allowin);
assign es_allowin = !es_valid || (es_ready_go && ms_allowin);
assign ds_allowin = !ds_valid || (ds_ready_go && es_allowin);
assign fs_allowin = !fs_valid || (fs_ready_go && ds_allowin);

// to_next_valid表示向下一级提供有效指令，与下一级allowin共同决定传递。（当前指令有效，且处理完成，可以交给下一级）

assign fs_to_ds_valid = fs_valid && fs_ready_go && !fetch_cancel;
assign ds_to_es_valid = ds_valid && ds_ready_go;
assign es_to_ms_valid = es_valid && es_ready_go;
assign ms_to_ws_valid = ms_valid && ms_ready_go;
// es_fire表示EX实际向MEM传递且未被WB冲刷。

//es_fire 只在 EX 真正把指令交给 MEM 时成立。若交接的是除法指令，就用它通知除法器：本次结果已经接收，可以返回空闲。
assign es_fire = es_to_ms_valid && ms_allowin && !pipeline_flush;

//==========================================================

//==========================================================

assign fetch_cancel = pipeline_flush || br_taken_cancel;

assign fetch_adef = |fetch_pc[1:0];

assign fetch_can_issue = resetn && !reset && !fetch_cancel && !br_stall
                       && fs_allowin && (!fs_pending || inst_sram_data_ok);

assign inst_sram_req   = fetch_can_issue && !fetch_adef;

assign inst_sram_wr    = 1'b0;
assign inst_sram_size  = MEM_WORD;

assign inst_sram_wstrb = 4'b0000;

assign inst_sram_addr  = fetch_pc;
assign inst_sram_wdata = 32'b0;

assign inst_addr_fire  = inst_sram_req && inst_sram_addr_ok;

assign fetch_accept   = fetch_can_issue && (fetch_adef || inst_addr_fire);


// 重定向立即保存目标、不依赖addr_ok；顺序PC仅在接收新槽后加4，等待旧响应时目标不会丢失。
always @(posedge clk) begin
    if (reset)
        fetch_pc <= 32'h1c000000;
    else if (pipeline_flush)
        fetch_pc <= redirect_target;
    else if (br_taken_cancel)
        fetch_pc <= ds_br_target;
    else if (fetch_accept)
        fetch_pc <= fetch_pc + 32'd4;
end


always @(posedge clk) begin
    if (reset)
        fs_pending <= 1'b0;
    else if (inst_addr_fire)
        fs_pending <= 1'b1;
    else if (inst_sram_data_ok)
        fs_pending <= 1'b0;
end


always @(posedge clk) begin
    if (reset || fetch_cancel) begin
        fs_valid <= 1'b0;
        fs_adef <= 1'b0;
    end else if (fs_allowin) begin
        fs_valid <= fetch_accept;
        if (fetch_accept) begin
            fs_pc <= fetch_pc;
            fs_adef <= fetch_adef;
        end
    end
end


// 解除阻塞后只传递一次，防止响应脉冲过去后丢失指令；新槽接收或重定向时清缓存有效位
always @(posedge clk) begin
    if (reset || fetch_cancel || fetch_accept)
        fs_inst_buffer_valid <= 1'b0;
    else if (fs_to_ds_valid && ds_allowin)//完成IF->ID传递，缓存任务完成 或 当拍可接收，不用缓冲
        fs_inst_buffer_valid <= 1'b0;
    else if (fs_valid && fs_pending && inst_sram_data_ok) begin
        fs_inst_buffer_valid <= 1'b1;
        fs_inst_buffer <= inst_sram_rdata;
    end
end


always @(posedge clk) begin
    if (reset || fetch_cancel) begin
        ds_valid <= 1'b0;
        ds_adef <= 1'b0;
    end else if (ds_allowin) begin
        ds_valid <= fs_to_ds_valid;
        if (fs_to_ds_valid) begin
            ds_pc <= fs_pc;
            ds_inst <= fs_adef ? 32'b0 :
                       fs_inst_buffer_valid ? fs_inst_buffer : inst_sram_rdata;
            ds_adef <= fs_adef;
        end
    end
end

//==========================================================
// ID：原单周期译码、读寄存器和分支逻辑迁移到此级
//==========================================================
// ID产生的控制信号用于选择操作数，并通过级间寄存器传到使用它的级。
wire [11:0] alu_op;
wire [ 6:0] md_op;
wire        src1_is_pc;
wire        src2_is_imm;
wire        res_from_mem;
// res_from_csr控制GPR写回数据来源，csr_we控制是否改写CSR。
// 两者不能混为一谈：csrrd只读也写GPR，csrwr/csrxchg读旧值写GPR同时更新CSR。
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
wire        inst_slti, inst_sltui, inst_andi, inst_ori, inst_xori;
wire        inst_sll_w, inst_srl_w, inst_sra_w, inst_pcaddu12i;
wire        inst_mul_w, inst_mulh_w, inst_mulh_wu;
wire        inst_div_w, inst_mod_w, inst_div_wu, inst_mod_wu;

// 新增3条CSR指令、ertn和syscall。
// inst_csr为CSR指令族，rj编码再细分为纯读、整字写、按掩码交换。
wire inst_csr, inst_csrrd, inst_csrwr, inst_csrxchg;
wire inst_ertn, inst_syscall;
// 新增break与三条计时器读取指令。
// rdcntvl/vh读稳定计数器，rdcntid复用CSR.TID读取；ds_csr_*保存当前ID的访问参数。
wire inst_break, inst_rdcntvl, inst_rdcntvh, inst_rdcntid;
wire [13:0] ds_csr_num;
wire [31:0] ds_csr_wmask, ds_csr_wvalue;


wire inst_blt, inst_bge, inst_bltu, inst_bgeu;
wire inst_ld_b, inst_ld_h, inst_ld_bu, inst_ld_hu, inst_st_b, inst_st_h;
wire ds_is_load, ds_is_store, ds_is_cond_branch;
wire ds_br_lt_signed, ds_br_lt_unsigned;

wire        need_ui5;
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

//ID 中依赖这个 load 的指令，需要继续等，MEM load尚未响应时阻塞依赖其最新结果的ID指令。
wire ds_ms_load_stall;
wire ds_branch_ex_stall;
wire ds_branch_ms_load_stall;
wire ds_div_use_stall;
// CSR结果到WB才可前递；该暂停信号处理ID读取其GPR结果的相关。
wire ds_csr_use_stall;

wire ds_rj_fwd_es,  ds_rj_fwd_ms,  ds_rj_fwd_ws;
wire ds_rkd_fwd_es, ds_rkd_fwd_ms, ds_rkd_fwd_ws;
wire es_pending_write, ms_pending_write, ws_pending_write;//对应流水级是否存在一条尚未完成寄存器写回的有效指令
wire ds_rj_raw_es, ds_rj_raw_ms, ds_rj_raw_ws;//rj与后三级存在RAW相关
wire ds_rkd_raw_es, ds_rkd_raw_ms, ds_rkd_raw_ws;//rkd与后三级存在RAW相关
wire ms_result_available; 

wire rj_eq_rd;
wire [31:0] ds_br_rj_value, ds_br_rkd_value;
// 从通用MEM前递再排除load，只让寄存后的非load结果进入分支比较。
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
// 分支仅译码高6位；窄访存保留12位有符号地址偏移。
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

// CSR按高8位译码；syscall保留低15位code，不制造GPR源依赖。
// CSR格式：[31:24]=0x04，[23:10]=CSR编号，[9:5]=rj，[4:0]=rd。
// rj=0：csrrd，rd只作目的；rj=1：csrwr，rd既提供新值又接收CSR旧值；
// rj>=2：csrxchg，rj寄存器提供逐位掩码，rd提供新值并接收CSR旧值。
// 上述rj=0/1是编码分支标记，csrwr不需要读取r1作为普通源操作数。
assign inst_csr     = ds_inst[31:24] == 8'h04;
assign inst_csrrd   = inst_csr && (rj == 5'd0);
assign inst_csrwr   = inst_csr && (rj == 5'd1);
assign inst_csrxchg = inst_csr && (rj != 5'd0) && (rj != 5'd1);
// ertn必须匹配完整固定编码；syscall的低15位是code，不参与该指令的识别。
// syscall在本CPU中只生成SYS异常，code位不会被误当成寄存器编号产生RAW暂停。
assign inst_ertn    = ds_inst == 32'h06483800;
assign inst_syscall = (ds_inst & 32'hffff8000) == 32'h002b0000;
// 严格约束编码，避免宽松译码吞掉INE。
// break与syscall类似，仅低15位code可变；rdcntvl/vh仅允许目的rd字段变化。
// 0xffffffe0保留高27位比较，确保rj等固定字段没有被错误放宽。
assign inst_break   = (ds_inst & 32'hffff8000) == 32'h002a0000;
assign inst_rdcntvl = (ds_inst & 32'hffffffe0) == 32'h00006000;
assign inst_rdcntvh = (ds_inst & 32'hffffffe0) == 32'h00006400;
// rdcntid的目的在rj字段，rd必须为0，所以掩码仅放开[9:5]。
// rj=0、rd=0的重叠编码归到rdcntvl，避免同一编码同时选中两种结果来源。
assign inst_rdcntid = ((ds_inst & 32'hfffffc1f) == 32'h00006000)
                     && (rj != 5'd0);
// rdcntid没有普通CSR编号字段，直接把访问地址重定向到TID(0x40)。
// 其他非CSR指令也会组合地产生此信号，但只有相应控制有效时才使用它。
assign ds_csr_num   = inst_rdcntid ? 14'h0040 : ds_inst[23:10];

// 白名单覆盖原51条和4条新增指令；零指令必须按INE处理。
// 用现有译码结果的或作为白名单，避免合法指令进入INE，也避免未知指令静默执行。
// 这里只说明本实验已实现的指令范围，不额外判断未实现的CSR编号是否合法。
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
// ADEF槽中的ds_inst是占位0，不能因此再报INE；普通有效的全0指令仍属于INE。
assign ds_ine = ds_valid && !ds_adef && !ds_inst_known;//指令有效，没有取指错误，未知指令
//ds_excp：把异常标志拼成一个 6 位向量。
// has_int是CSR当前状态的组合结果，只有ID真正发射时才锁存入es_excp。
// 多个异常位允许同时存在，最终只由WB按固定优先级选择一个提交。
assign ds_excp = {1'b0, ds_ine, inst_break, inst_syscall,
                  ds_adef, has_int};
//判断这条指令是否存在异常
assign ds_excp_any = ds_valid && (|ds_excp);




assign md_op = {inst_mod_wu, inst_div_wu, inst_mod_w, inst_div_w,
                inst_mulh_wu, inst_mulh_w, inst_mul_w};

// ALU控制依次为加、减、有符号/无符号比较、与、或非、或、异或、
// 逻辑左移、逻辑右移、算术右移和高位立即数装载。
// load/store用加法算有效地址；jirl/bl用加法算链接地址PC+4。
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

assign need_ui5   =  inst_slli_w | inst_srli_w | inst_srai_w;
assign need_ui12  =  inst_andi | inst_ori | inst_xori;
assign need_si12  =  inst_addi_w | ds_is_load | ds_is_store | inst_slti | inst_sltui;
assign need_si16  =  inst_jirl | ds_is_cond_branch;
assign need_si20  =  inst_lu12i_w | inst_pcaddu12i;
assign need_si26  =  inst_b | inst_bl;
assign src2_is_4  =  inst_jirl | inst_bl;

// slti/sltui都符号扩展i12；逻辑立即数零扩展，移位只取低5位。
// pcaddu12i使用当前指令PC加{i20,12'b0}，不改变分支控制。
assign imm = src2_is_4 ? 32'h4                      :
             need_si20 ? {i20[19:0], 12'b0}         :
             need_ui12 ? {20'b0, i12}              :
             need_ui5  ? {27'b0, ds_inst[14:10]}    :
                         {{20{i12[11]}}, i12[11:0]} ;

// 分支偏移符号扩展并左移2位，将指令中的字偏移转换为字节偏移。
assign br_offs = need_si26 ? {{ 4{i26[25]}}, i26[25:0], 2'b0} :
                             {{14{i16[15]}}, i16[15:0], 2'b0} ;

assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

// CSR写指令从rd取待写CSR的新数据，需把第二读端口从rk切到rd。
// rd同时还是GPR目的寄存器，但读发生在本指令写回之前，因此能取得它的旧内容。
assign src_reg_is_rd = ds_is_cond_branch | ds_is_store | inst_csrwr | inst_csrxchg;

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
                       ds_is_load  |
                       ds_is_store |
                       inst_lu12i_w|
                       inst_jirl   |
                       inst_bl     ;

assign res_from_mem  = ds_is_load;
// 三种CSR指令都把CSR旧值写到GPR；rdcntid也走同一条CSR读通路。
// csrrd/rdcntid不改写CSR，只有csrwr/csrxchg产生写意图，实际提交还需WB资格检查。
assign res_from_csr  = inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid;
assign csr_we        = inst_csrwr | inst_csrxchg;
// 新值和掩码都取已完成前递选择的操作数，避免紧邻前序GPR写回时读取过期数据。
// csrwr用全1掩码整字写；csrxchg用rj值逐位写，未选中的位由csr.v保留原值。
// 纯读指令的这些参数无须清零，因为csr_we=0使它们不会产生写入副作用。
assign ds_csr_wvalue = rkd_value;
assign ds_csr_wmask  = inst_csrwr ? 32'hffffffff : rj_value;
assign dst_is_r1     = inst_bl;

// 沿用实践6修正：bl需要写r1；store及非链接分支不写寄存器。
// gr_we仅表示译码写回意图，真实写使能在WB结合valid及复位生成。
// 改为枚举确实有GPR结果的运算，不能再用“非store且非分支”概括。
// 否则syscall、ertn、break或未知编码可能误写GPR；计数器读需额外加入写回集合。
assign gr_we         = (((|alu_op) && !ds_is_store) || (|md_op) || res_from_csr
                     || inst_rdcntvl || inst_rdcntvh);
assign mem_we        = ds_is_store;
// rdcntid的rj是目的而非源；其他指令沿用bl写r1、其余写rd的规则。
assign dest          = inst_rdcntid ? rj : (dst_is_r1 ? 5'd1 : rd);

assign rf_raddr1 = rj;
assign rf_raddr2 = src_reg_is_rd ? rd :rk;

// 按指令语义标记真实源：jirl读rj，store还读rd；立即数字段不算源。
// csrxchg读取rj掩码，csrwr/csrxchg都读取第二端口上的rd新值。
// csrrd、ertn、syscall、break、rdcntvl/vh/id不读取GPR源，不能因编码字段形成假相关。
// 特别是rdcntid虽然目的编码在rj中，也不把rj旧值作为本条指令的输入。
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
// 异常指令虽然保留原译码的目的字段，但不再是合法结果生产者。
// EX直接排除含ALE的异常；MEM/WB使用在级间入口已清除异常资格的gr_we。
// 这样既阻止异常结果前递，也避免把最终WB异常选择的长组合路径接回ID相关网络。
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

assign ds_is_reg_branch = ds_is_cond_branch | inst_jirl;

// EX只前递已完成的非load结果，寄存器型转移仍等待MEM。
// 最新EX写者未就绪时屏蔽MEM/WB中的同名旧值，并由RAW暂停阻止接收。
// CSR读值到WB才从u_csr读出，所以EX和MEM都不能把普通执行结果前递。
// 即使MEM/WB存在更老的同名写者，最新EX写者匹配时仍优先阻止使用它们的旧值。
// MEM为最新CSR写者时也必须屏蔽WB旧值，并由ds_csr_use_stall等待它进入WB。
assign es_result_available = !es_excp_any_with_ale  //没有ale异常
                           && !es_res_from_mem && !es_res_from_csr//不是load（MEM取得结果），不是csr(WB取得结果)
                           && (!es_is_div || div_done);

// MEM等待load响应时不前递总线数据；只有结果已就绪、可向WB传递时才允许前递。
assign ms_result_available = ms_to_ws_valid && !ms_res_from_csr; //csr从WB才取得结果
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
// 仅最新MEM load写者阻塞相关分支，避免数据RAM直通分支/取指。
// 两个源分别检查：若同一源还命中更年轻的EX写者，MEM就不是这个源的最新写者。
// ds_branch_ms_load_stall：分支/jirl依赖load时等WB。
// 普通运算可在MEM收到load响应的当拍前递，未返回时由新增ds_ms_load_stall阻塞。
assign ds_branch_ms_load_stall = ds_is_reg_branch && ms_res_from_mem
                               && ((ds_rj_raw_ms && !ds_rj_raw_es)
                                || (ds_rkd_raw_ms && !ds_rkd_raw_es));
assign ds_div_use_stall = es_is_div && !div_done && (ds_rj_raw_es || ds_rkd_raw_es);
// CSR返回值到WB才可用；逐源检查最新写者，防止退用旧MEM/WB值。
// 例：csrrd r5,csr后紧跟add.w读取r5，前者位于EX或MEM时暂停，进入WB后可直接前递。
// 若EX已存在更年轻的同名普通写者，则应跟随EX，不为MEM中较老的CSR结果额外等待。
assign ds_csr_use_stall = (es_res_from_csr && (ds_rj_raw_es || ds_rkd_raw_es))
                       || (ms_res_from_csr
                           && ((ds_rj_raw_ms && !ds_rj_raw_es)
                            || (ds_rkd_raw_ms && !ds_rkd_raw_es)));
// 非相关ID指令也受es_allowin约束，不能在除法等待期间提前跳转。
// CSR结果暂停、MEM load分支暂停均沿用exp13，再叠加本次新增的MEM load响应等待。
// 最终ds_ready_go还会独立叠加CSR状态屏障，异常令牌只跳过普通RAW等待。

assign ds_ms_load_stall = ms_res_from_mem && !ms_ready_go
                        && ((ds_rj_raw_ms && !ds_rj_raw_es)
                         || (ds_rkd_raw_ms && !ds_rkd_raw_es));

assign ds_raw_stall = ds_ms_load_stall || ds_load_use_stall || ds_branch_ex_stall
                   || ds_branch_ms_load_stall || ds_div_use_stall || ds_csr_use_stall;

// 影响中断判定的CSR在ID只译码一次，后三级仅传递1位标志，
// 避免EX/MEM/WB各自重复14位CSR号比较造成面积和布线压力。
// 中断状态相关集合：CRMD(0x0)改全局IE，ECFG(0x4)改局部使能，
// ESTAT(0x5)改软件pending，TCFG(0x41)改定时器配置，TICLR(0x44)清定时器pending。
// ertn也恢复IE，因此同样作为状态写者；此处对这些写指令采用保守阻塞，不细分写掩码。
// 标志与指令一起传递，只要任一较老写者还在EX/MEM/WB，ID就暂不发射。
// WB写入在上升沿才完成，所以WB中仍有写者的这一拍也要等待，下一拍才看新has_int。
assign ds_csr_state_writer = inst_ertn ||
    (csr_we && ((ds_csr_num == 14'h0000) || (ds_csr_num == 14'h0004) ||
                (ds_csr_num == 14'h0005) || (ds_csr_num == 14'h0041) ||
                (ds_csr_num == 14'h0044)));//CRMD ECFG  ESTAT TCFG TICLR
//可能修改中断状态
assign es_csr_state_writer = es_valid && es_csr_state_writer_flag;
assign ms_csr_state_writer = ms_valid && ms_csr_state_writer_flag;
assign ws_csr_state_writer = ws_valid && ws_csr_state_writer_flag;
assign ds_csr_state_stall = es_csr_state_writer || ms_csr_state_writer
                         || ws_csr_state_writer;
//等待中断状态更新完成

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

// WB前递改用ws_writeback_result，确保CSR旧值和rdcntid也能被后继使用。
// 若仍使用ws_final_result，CSR指令会把无关的普通执行结果错误前递给后继操作数。
assign rj_value = ds_rj_fwd_es ? es_exec_result :
                  ds_rj_fwd_ms ? ms_final_result :
                  ds_rj_fwd_ws ? ws_writeback_result :
                                 rf_rdata1;

assign rkd_value = ds_rkd_fwd_es ? es_exec_result :
                   ds_rkd_fwd_ms ? ms_final_result :
                   ds_rkd_fwd_ws ? ws_writeback_result :
                                   rf_rdata2;

// 操作数就绪且分支能离开ID时才重定向，并取消旧IF对应的ID槽。
// 分支仍进入EX，bl/jirl正常写回链接值；不清除后三级或目标IF。
// 分支MEM前递直接取寄存后的执行结果，不经过含RAM数据的最终结果选择器。
// load在MEM不参与分支前递，到WB后使用已锁存的ws_writeback_result。
// 分支MEM输入只取ms_alu_result，绕开ms_final_result里的RAM数据选择。
// 比较器结果会影响同拍取指地址，这样可以截断“数据RAM -> 分支比较 -> 指令RAM”的长路径。
// CSR结果也不会从MEM送入分支，需等WB的ws_writeback_result，与普通操作数前递一致。
assign ds_br_rj_fwd_ms = ds_rj_fwd_ms && !ms_res_from_mem;
assign ds_br_rkd_fwd_ms = ds_rkd_fwd_ms && !ms_res_from_mem;
assign ds_br_rj_value = ds_br_rj_fwd_ms ? ms_alu_result :
                        ds_rj_fwd_ws ? ws_writeback_result : rf_rdata1;
assign ds_br_rkd_value = ds_br_rkd_fwd_ms ? ms_alu_result :
                         ds_rkd_fwd_ws ? ws_writeback_result : rf_rdata2;
assign rj_eq_rd = (ds_br_rj_value == ds_br_rkd_value);
// 显式区分有符号和无符号比较，避免相减溢出影响分支。
assign ds_br_lt_signed = ($signed(ds_br_rj_value) < $signed(ds_br_rkd_value));
assign ds_br_lt_unsigned = (ds_br_rj_value < ds_br_rkd_value);
assign ds_br_cond = (inst_beq && rj_eq_rd)
                || (inst_bne && !rj_eq_rd)
                || (inst_blt && ds_br_lt_signed)
                || (inst_bge && !ds_br_lt_signed)
                || (inst_bltu && ds_br_lt_unsigned)
                || (inst_bgeu && !ds_br_lt_unsigned)
                || inst_jirl || inst_bl || inst_b;

assign br_stall = ds_valid && (ds_is_reg_branch || inst_b || inst_bl)
                 && (!ds_ready_go || !es_allowin);//ID种指令有效，是分支/跳转，没有完成或ex不能接收
// 分支正式生效条件：WB异常/ertn优先，冲刷当拍禁止分支取消事件。
assign br_taken_cancel = resetn && !reset && !pipeline_flush
                       && ds_to_es_valid && es_allowin && ds_br_cond;


// PC相对目标必须基于ds_pc；jirl目标为rj+偏移，不能混用IF级PC。
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

// 普通指令也写入全零md_op；EX等待时控制位与操作数一起保持。
// 异常/ertn冲刷除清valid，还清EX乘除法控制，避免保留旧运算类型。
// 除法单元本身也接收pipeline_flush复位，后面两处控制需要配合使用。
always @(posedge clk) begin
    if (reset)
        es_md_op <= 7'b0;
    else if (pipeline_flush)
        es_md_op <= 7'b0;
    else if (ds_to_es_valid && es_allowin)
        es_md_op <= md_op;
end

// EX级valid优先级：reset > pipeline_flush > 正常allowin握手。
// 冲刷不必逐项清空PC、操作数和CSR元数据：所有使用点都由valid或提交资格限定。
// 数据锁存块即使在冲刷沿更新，es_valid也保持0，旧/新残留内容不会成为有效指令。
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
        // 把“最终读CSR”的结果来源与同条指令送往后级。
        es_res_from_csr <= res_from_csr;
        // 元数据与本条指令一同锁存，EX暂停时保持。
        es_mem_size     <= ds_mem_size;
        es_load_unsigned <= ds_load_unsigned;
        es_gr_we        <= gr_we;
        es_mem_we       <= mem_we;
        es_dest         <= dest;
        es_rkd_value    <= rkd_value;
        // CSR/异常元数据只随有效指令前进，暂停时保持。
        // 编号、掩码、新数据都在ID操作数前递完成后锁存；到WB时不能再回读ID源寄存器。
        // es_csr_we只是意图，真正CSR写入要等该指令到WB且未被异常/ertn取消。
        es_csr_we       <= csr_we;
        es_csr_num      <= ds_csr_num;
        es_csr_wmask    <= ds_csr_wmask;
        es_csr_wvalue   <= ds_csr_wvalue;

        es_syscall      <= inst_syscall;
        es_ertn         <= inst_ertn;
        // 只锁存一次状态写者预译码结果，供较年轻ID指令的中断屏障使用。
        es_csr_state_writer_flag <= ds_csr_state_writer;
        // 中断决定与静态异常只在ID实际发射沿锁存。
        // ID因RAW或状态屏障等待期间，has_int可以变化；以实际发射沿前的值为准。
        // 发射后INT等标志随该指令保持，避免后续外部中断电平变化改写在途异常。
        es_excp         <= ds_excp;
        // 只保存读取计数器哪半部的控制；实际计数值在EX离开时采样，不在ID提前保存。
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

// 这里是进入EX时已有的异常，尚不含本拍由地址计算产生的ALE。
assign es_excp_any = es_valid && (|es_excp);
// 异常令牌上的乘除法不启动、不等待。
// 例如一条div指令在ID被标记INT后，只需传递中断现场，不应再启动并等待无用除法。
// es_is_div被抑制后es_ready_go直接就绪，该异常槽可在下一级允许时前进。
assign es_is_mul = es_valid && !es_excp_any && (|es_md_op[2:0]);
assign es_is_div = es_valid && !es_excp_any && (|es_md_op[6:3]);
assign es_div_signed = es_md_op[3] | es_md_op[4];
assign es_div_remainder = es_md_op[4] | es_md_op[6];

// exp10_mul33必须配置为33x33有符号、66位输出、PipeStages=0。
mul_unit u_mul_unit(
    .src1        (es_alu_src1),
    .src2        (es_alu_src2),
    .signed_mode (es_md_op[0] | es_md_op[1]),
    .product     (mul_product)
);

div_unit u_div_unit(
    .clk         (clk),
    // 异常冲刷复用局部复位，清除年轻在途除法及IP返回。
    // WB较老指令异常/返回时，EX可能仍在等待年轻除法；必须同步取消其状态和迟到结果。
    // div_unit内部负责IP复位保持及释放时序，不能只清EX valid后留下旧done结果。
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

assign es_mul_result = es_md_op[0] ? mul_product[31:0] : mul_product[63:32];
assign es_div_result = es_div_remainder ? div_remainder : div_quotient;
// rdcntvh选高32位，rdcntvl选低32位；在EX->MEM上升沿采样沿前读数。
// 计数器在同一沿也自增，非阻塞赋值保证本条指令采到自增前的值。
// 两条独立的高/低半部读取不会自动形成64位原子快照，硬件也不会因读取暂停计数。
assign es_counter_result = es_rdcntvh ? stable_counter[63:32]
                                      : stable_counter[31:0];
// 计数读结果并入统一EX结果，随后复用普通ALU结果的MEM/WB保存和GPR前递通路。
// rdcntid不在此选择：它到WB通过CSR.TID组合读通路提供结果。
assign es_exec_result = (es_rdcntvl || es_rdcntvh) ? es_counter_result :
                        es_is_mul ? es_mul_result :
                        es_is_div ? es_div_result : es_alu_result;

// ALE在EX使用完整有效地址检测，早期异常优先且当拍取消访存。
// 字访问要求地址[1:0]=00，半字访问要求地址[0]=0，字节访问没有对齐限制。
// 只有有效load/store才检查；已经带INT/ADEF/SYS/BRK/INE的槽不再补出ALE。
// 地址来自同条指令ALU计算结果，不能用RAM返回数据或截断后的字地址做检测。
assign es_ale = es_valid && !es_excp_any //指令有效，无其他异常
             && (es_res_from_mem || es_mem_we)//load store
             && (((es_mem_size == MEM_WORD) && (es_alu_result[1:0] != 2'b00))
              || ((es_mem_size == MEM_HALF) && es_alu_result[0]));
// 用EX新产生的ALE替换向量最高位，保留ID传来的其余五类异常。
// 含ALE的完整异常资格当拍就用于关闭RAM，不能等到下一拍进入MEM后再阻止访问。
assign es_excp_with_ale = {es_ale, es_excp[EXC_INE:EXC_INT]};//放入异常向量
assign es_excp_any_with_ale = es_valid && (|es_excp_with_ale);//查看有无异常


// 否则错误请求可能先被接受，之后冲刷流水线也无法撤销。
assign older_redirect_in_ms = ms_valid && (ms_excp_any || ms_ertn);
assign older_redirect_in_ws = ws_valid && (ws_excp_any || ws_ertn);

// 不再依赖es_fire，避免req -> es_ready_go -> es_fire -> req形成组合环。
assign es_mem_access_allowed = resetn && !reset && !pipeline_flush && es_valid && ms_allowin
                            && !es_excp_any_with_ale && !es_ertn
                            && !older_redirect_in_ms && !older_redirect_in_ws
                            && (es_res_from_mem || es_mem_we);

assign data_sram_req   = es_mem_access_allowed;

assign data_sram_wr    = es_mem_we;
assign data_sram_size  = es_mem_size;
// 依据store宽度和地址低位生成字节写掩码。
assign es_store_mask  = (es_mem_size == MEM_BYTE) ? (4'b0001 << es_alu_result[1:0]) :
                        (es_mem_size == MEM_HALF) ?
                            (es_alu_result[1] ? 4'b1100 : 4'b0011) : 4'b1111;

// 保留对ALE和较老异常/ertn的抑制，只选通本条store真正写入的字节。
assign data_sram_wstrb = {4{es_mem_access_allowed && es_mem_we}} & es_store_mask;
assign data_sram_addr  = es_alu_result;//使用ALU算出的有效地址
assign data_sram_wdata = (es_mem_size == MEM_BYTE) ? {4{es_rkd_value[7:0]}} :
                         (es_mem_size == MEM_HALF) ? {2{es_rkd_value[15:0]}} : es_rkd_value;

//==========================================================
// EXE -> MEM：传递统一执行结果及其配套写回信息
//==========================================================

// load/store均须在MEM等data_ok；原有元数据锁存逻辑保持不变。
reg [31:0] ms_pc;

//ms_wait_data 表示：MEM 中这条指令已经成功发出访存请求，需要等待 data_sram_data_ok，才能离开 MEM
// 普通指令、异常load/store令牌未发请求，不等响应；复位或WB冲刷清除此状态。
always @(posedge clk) begin
    if (reset || pipeline_flush)
        ms_wait_data <= 1'b0;
    else if (ms_allowin)
        ms_wait_data <= es_to_ms_valid && data_sram_req && data_sram_addr_ok;
end

// MEM同样在WB重定向时清valid；此时年轻执行结果和异常令牌一起作废。
// 下方元数据仅在EX->MEM握手时更新，EX除法等待期间不会提前改变MEM中的指令身份。
always @(posedge clk) begin
    if (reset)
        ms_valid <= 1'b0;
    else if (pipeline_flush)
        ms_valid <= 1'b0;
    else if (ms_allowin)
        ms_valid <= es_to_ms_valid;

    if (es_to_ms_valid && ms_allowin) begin
        ms_pc           <= es_pc;
        ms_alu_result   <= es_exec_result;
        ms_res_from_mem <= es_res_from_mem;
        // CSR读来源继续传递，MEM普通结果尚不能替代CSR旧值。
        ms_res_from_csr <= es_res_from_csr;
        // 仅使用本条load的类型与地址低位进行MEM选通。
        ms_mem_size     <= es_mem_size;
        ms_load_unsigned <= es_load_unsigned;
        ms_addr_low     <= es_alu_result[1:0];
        // 在EX/MEM边界固化异常资格，异常令牌进入MEM时已不可写通用寄存器
        // 这样MEM的pending_write只需检查寄存后的ms_gr_we，不必把异常组合判断再送回ID。
        ms_gr_we        <= es_gr_we && !es_excp_any_with_ale;
        ms_dest         <= es_dest;
        // CSR编号/掩码/新值继续成组传递；MEM不真正访问或更新CSR。
        ms_csr_we       <= es_csr_we;
        ms_csr_num      <= es_csr_num;
        ms_csr_wmask    <= es_csr_wmask;
        ms_csr_wvalue   <= es_csr_wvalue;
        // SYS兼容标志、ertn返回意图与中断状态写者标志都保持同一条指令的对应关系。
        ms_syscall      <= es_syscall;
        ms_ertn         <= es_ertn;
        ms_csr_state_writer_flag <= es_csr_state_writer_flag;
        // ALE在进入MEM的沿并入异常令牌，同时保存完整错误地址。
        // 这里对所有指令保存ALU结果以简化控制，但只有WB最终选择ALE时才拿它更新BADV。
        // ADEF最终使用指令PC，不能把此处无意义的ALU结果当作取指错误地址。
        ms_excp         <= es_excp_with_ale;
        ms_vaddr        <= es_alu_result;
    end
end

//==========================================================

//==========================================================
// 原单周期final_result选择逻辑移至MEM。
// RAM返回值与ms_res_from_mem对应同一条load，不可在EXE提前使用，



// 小端选通及扩展在MEM完成，普通操作数可前递完整32位load结果。
// 分支相关load改为等WB后前递，避免MEM的RAM输出直接进入分支比较。
assign ms_load_byte = (ms_addr_low == 2'b00) ? data_sram_rdata[7:0] :
                      (ms_addr_low == 2'b01) ? data_sram_rdata[15:8] :
                      (ms_addr_low == 2'b10) ? data_sram_rdata[23:16] : data_sram_rdata[31:24];
assign ms_load_half = ms_addr_low[1] ? data_sram_rdata[31:16] : data_sram_rdata[15:0];
assign ms_load_result = (ms_mem_size == MEM_BYTE) ?
                         (ms_load_unsigned ? {24'b0, ms_load_byte} : {{24{ms_load_byte[7]}}, ms_load_byte}) :
                        (ms_mem_size == MEM_HALF) ?
                         (ms_load_unsigned ? {16'b0, ms_load_half} : {{16{ms_load_half[15]}}, ms_load_half}) :
                         data_sram_rdata;
// MEM保留完整异常向量，归约结果用于压掉年轻访存及固化下一拍GPR写资格。
assign ms_excp_any = ms_valid && (|ms_excp);
assign ms_final_result = ms_res_from_mem ? ms_load_result : ms_alu_result;

//==========================================================
// MEM -> WB：锁存最终结果、目的寄存器、写回控制和PC
//==========================================================
// PC、控制和数据必须跨过相同数量的级间寄存器，确保写回信息对应。

reg [31:0] ws_pc;

// WB事件在本周期末提交并冲刷，清ws_valid避免同一事件下一拍重复触发。
// valid清除优先于allowin；即便本沿把年轻MEM数据锁入WB，也因ws_valid=0而无法提交。
always @(posedge clk) begin
    if (reset)
        ws_valid <= 1'b0;
    else if (pipeline_flush)
        ws_valid <= 1'b0;
    else if (ws_allowin)
        ws_valid <= ms_to_ws_valid;

    if (ms_to_ws_valid && ws_allowin) begin
        ws_pc           <= ms_pc;
        // CSR结果选择保留到WB，届时u_csr才以本条指令编号读出旧值。
        ws_res_from_csr <= ms_res_from_csr;
        // 继续在MEM/WB边界固化资格，使WB前递只依赖寄存后的写使能。
        // 异常槽仍保留PC和异常向量用于提交，但不能成为合法的GPR结果生产者。
        ws_gr_we        <= ms_gr_we && !ms_excp_any;
        ws_dest         <= ms_dest;
        ws_final_result <= ms_final_result;
        // 到达WB的CSR参数、返回意图、状态写者标志都属于ws_pc这条指令。
        // ws_csr_we仍只是意图，下面csr_commit_we还会排除异常和ertn。
        ws_csr_we       <= ms_csr_we;
        ws_csr_num      <= ms_csr_num;
        ws_csr_wmask    <= ms_csr_wmask;
        ws_csr_wvalue   <= ms_csr_wvalue;
        ws_syscall      <= ms_syscall;
        ws_ertn         <= ms_ertn;
        ws_csr_state_writer_flag <= ms_csr_state_writer_flag;
        // 完整异常位和访存错误地址一起锁存，确保最终Ecode、ERA、BADV来自同一条指令。
        ws_excp         <= ms_excp;
        ws_vaddr        <= ms_vaddr;
    end
end

//==========================================================
// WB：寄存器写回与debug输出
//==========================================================
// WB统一提交六类异常；INT有效位独立于其零值Ecode。
// 先结合ws_valid判断是否真的有异常，再生成一次提交事件，不能以Ecode!=0检测异常。
// ertn仅在本条没有任何异常时生效：若ertn同时携带INT等异常，应先提交异常。
// pipeline_flush由WB已有状态直接生成，不依赖rf_we/csr_commit_we/es_fire，避免组合环。
assign ws_excp_any = ws_valid && (|ws_excp);
assign wb_ex          = resetn && !reset && ws_excp_any;
assign ertn_flush     = resetn && !reset && ws_valid && !ws_excp_any && ws_ertn;
assign pipeline_flush = wb_ex || ertn_flush;
// 异常使用EENTRY ex_entry；无异常的ertn使用ERA ertn_entry
assign redirect_target = wb_ex ? ex_entry : ertn_entry;

// 同条异常优先级：INT > ADEF > SYS > BRK > INE > ALE。
// 异常位先随指令传递，直到WB才编码，因此INT的0编码与“无异常”可区分。
// 对多条指令的先后关系则由流水线顺序提交保证，较老异常提交会清除所有年轻槽。
assign wb_ecode = ws_excp[EXC_INT]  ? 6'h00 :
                  ws_excp[EXC_ADEF] ? 6'h08 :
                  ws_excp[EXC_SYS]  ? 6'h0b :
                  ws_excp[EXC_BRK]  ? 6'h0c :
                  ws_excp[EXC_INE]  ? 6'h0d :
                  ws_excp[EXC_ALE]  ? 6'h09 : 6'h00;
// 本实验支持的这些异常使用子码0；ADEF的BADV取异常PC，其他路径提供保存的访存地址。
// csr.v只在最终Ecode为ADEF/ALE时更新BADV，所以其他异常不会因该地址选择而误写BADV。
assign wb_esubcode = 9'b0;
assign wb_vaddr = ws_excp[EXC_ADEF] ? ws_pc : ws_vaddr;
//如果有取指地址错误ADEF → 选择指令PC，否则选择保存的访存地址


// CSR组合读取得写入前的旧值；软件写、异常保存和返回均在本周期末提交。
// 只有有效且无异常、非ertn的CSR写指令才能修改CSR。
// CSR指令若携带INT等异常，既不能写CSR，也不能把它的旧CSR值正常写回GPR。

assign csr_commit_we = resetn && !reset && ws_valid && ws_csr_we
                     && !ws_excp_any && !ws_ertn;
                     
// CSR所有读写编号/数据都由WB驱动，实现按程序顺序提交。
// 上升沿前csr_rvalue是旧值，供CSR指令写GPR；同一沿u_csr再按掩码更新自身状态。
// wb_ex提供异常入口保存事件及Ecode/PC/BADV；ertn_flush恢复CRMD状态。
// CSR反向提供入口EENTRY、返回ERA和has_int；硬中断采样与定时器运行在其内部完成。
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

// 统一WB最终结果：CSR三指令/rdcntid选CSR，其他选已锁存普通结果。
// 该选择必须同时供GPR写端口、ID普通前递、分支前递和debug使用，保持数据一致。
// 对CSR指令尤其如此：其ws_final_result并不是应返回的CSR旧值。
assign ws_writeback_result = ws_res_from_csr ? csr_rvalue : ws_final_result;

// 原gr_we && valid改为WB级有效位约束，写端口只使用ws_*信息。
// 复位期间禁止写寄存器，防止流水寄存器残留控制信号造成副作用。
// WB异常/ertn冲刷当拍禁止GPR提交；异常现场更新仍由wb_ex送CSR。
// 更年轻指令的访存已在EX被提前屏蔽，其GPR/CSR写回则因各级valid清零而取消。
assign rf_we    = resetn && !reset && ws_valid && ws_gr_we && !pipeline_flush;
assign rf_waddr = ws_dest;
assign rf_wdata = ws_writeback_result;

// debug输出统一来自同一条WB指令，不再输出取指PC。
// 四位debug写使能复制真实rf_we；目的寄存器为r0时沿用原接口约定，
// regfile读r0恒为0，测试平台在trace比对时忽略写r0的记录。
// debug数据也使用含CSR选择的真实最终值，不能再直接输出ws_final_result。
// 异常/ertn时rf_we为0，debug不会把异常令牌当成普通GPR写回记录。
assign debug_wb_pc       = ws_pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = ws_dest;
assign debug_wb_rf_wdata = ws_writeback_result;

endmodule
