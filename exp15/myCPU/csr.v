`timescale 1ns / 1ps
`default_nettype none


// 本模块负责保存处理器的控制/状态寄存器，并提供：
//   1. CSR组合读、带逐位掩码的同步写；
//   2. WB提交异常时保存现场，执行ertn时恢复运行状态；
//   3. 软件中断、八路硬件中断、定时器中断的状态与中断请求；
//   4. 可配置为单次或周期模式的32位递减定时器。
// 这里的递减定时器不同于mycpu_top.v中供rdcntvl/vh读取的64位稳定计数器。
// 所有状态在clk上升沿更新；未命中赋值分支的寄存器保持原值。
module csr #(
    // TID的复位初值；复位后仍可通过CSR指令修改TID。
    parameter [31:0] CORE_ID = 32'b0
)(
    input  wire        clk,
    input  wire        reset,       // 高有效同步复位。
    input  wire [13:0] csr_num,     // 当前访问的CSR编号，读写共用。
    input  wire        csr_we,      // WB允许提交的CSR写使能；读不需要使能。
    input  wire [31:0] csr_wmask,   // 每位为1则写新值，为0则保留该位旧值。
    input  wire [31:0] csr_wvalue,  // 待写入的数据，只有掩码选中的位生效。
    output reg  [31:0] csr_rvalue,  // 组合读结果；写入沿前返回当前旧值。
    input  wire        wb_ex,       // WB提交异常的事件，包含中断异常。
    input  wire [ 5:0] wb_ecode,    // 本次最终选中的异常主码。
    input  wire [ 8:0] wb_esubcode, // 异常子码，由流水线提供。
    input  wire [31:0] wb_pc,       // 异常指令PC，异常时保存到ERA。
    input  wire [31:0] wb_vaddr,    // 错误地址：ADEF用取指PC，ALE用访存地址。
    input  wire        ertn_flush,  // WB提交ertn的事件，恢复异常前PLV和IE。
    input  wire [ 7:0] hw_int_in,   // 八路高有效硬件中断，每拍采样到ESTAT。
    output wire        has_int,     // 存在已使能的待处理中断，供流水线判断。
    output wire [31:0] ex_entry,    // 异常处理入口，来自EENTRY。
    output wire [31:0] ertn_entry   // 异常返回地址，来自ERA。
);

// CSR地址表。localparam与教材中`CSR_xxx宏的作用相同：给编号命名。
// 只有下面列出的CSR具有读出定义；软件写还受各字段的可写范围限制。
localparam [13:0] CSR_CRMD   = 14'h0000;
localparam [13:0] CSR_PRMD   = 14'h0001;
localparam [13:0] CSR_ECFG   = 14'h0004;
localparam [13:0] CSR_ESTAT  = 14'h0005;
localparam [13:0] CSR_ERA    = 14'h0006;
localparam [13:0] CSR_BADV   = 14'h0007;
localparam [13:0] CSR_EENTRY = 14'h000c;
localparam [13:0] CSR_SAVE0  = 14'h0030;
localparam [13:0] CSR_SAVE1  = 14'h0031;
localparam [13:0] CSR_SAVE2  = 14'h0032;
localparam [13:0] CSR_SAVE3  = 14'h0033;
localparam [13:0] CSR_TID    = 14'h0040;
localparam [13:0] CSR_TCFG   = 14'h0041;
localparam [13:0] CSR_TVAL   = 14'h0042;
localparam [13:0] CSR_TICLR  = 14'h0044;

// 实际只存储需要变化的字段，读出时再拼成完整的32位CSR。
reg [1:0] csr_crmd_plv;        // CRMD[1:0]：当前特权级，异常入口置为0。
reg       csr_crmd_ie;         // CRMD[2]：全局中断使能，异常入口清零。
reg [1:0] csr_prmd_pplv;       // PRMD[1:0]：异常发生前的PLV。
reg       csr_prmd_pie;        // PRMD[2]：异常发生前的IE。
reg [12:0] csr_ecfg_lie;       // ECFG[12:0]：各中断源的局部使能位。
reg [1:0] csr_estat_is_sw;     // ESTAT.IS[1:0]：由软件写入的中断状态。
reg [7:0] csr_estat_is_hw;     // ESTAT.IS[9:2]：采样得到的硬件中断状态。
reg       csr_estat_is_timer;  // ESTAT.IS[11]：定时器到期后保持的pending位。
reg [5:0] csr_estat_ecode;     // ESTAT[21:16]：最近一次异常的主码。
reg [8:0] csr_estat_esubcode;  // ESTAT[30:22]：最近一次异常的子码。
reg [31:0] csr_era;            // ERA：异常返回PC，可由软件修改。
reg [31:0] csr_badv;           // BADV：最近一次地址错误异常的错误地址。
reg [25:0] csr_eentry_va;      // EENTRY[31:6]：入口高位，低6位固定为0。
reg [31:0] csr_save0, csr_save1, csr_save2, csr_save3; // 软件保存现场用。
reg [31:0] csr_tid;            // TID：核/线程标识，供rdcntid等访问。
reg        csr_tcfg_en;       // TCFG[0]：递减定时器使能。
reg        csr_tcfg_periodic; // TCFG[1]：1为周期模式，0为单次模式。
reg [29:0] csr_tcfg_initval;  // TCFG[31:2]：装载值高30位，装载时低2位补0。
reg [31:0] timer_cnt;          // TVAL的实际存储，软件只读，硬件递减/重装。

// ESTAT.IS位布局：[12]=0，[11]=定时器，[10]=0，[9:2]=硬中断，[1:0]=软中断。
// 本实现没有连接IS[12]对应的中断源，因此该位读出始终为0。
wire [12:0] csr_estat_is = {1'b0, csr_estat_is_timer, 1'b0,
                            csr_estat_is_hw, csr_estat_is_sw};
// 通用逐位合并：new = (old & ~mask) | (value & mask)。
// csrwr由顶层提供全1掩码；csrxchg由顶层提供源寄存器中的掩码。
// csr_num选择CRMD时，csr_rvalue[1:0]就是csr_crmd_plv，因此取合并结果的
// [1:0]与教材直接对PLV字段做“掩码写新值、反掩码保留旧值”完全等价。
wire [31:0] csr_merged = (csr_rvalue & ~csr_wmask)
                       | (csr_wvalue & csr_wmask);
// 拼接当前TCFG，再算本次写入后的配置；计数重装也必须使用合并后的新值。
wire [31:0] csr_tcfg_value = {csr_tcfg_initval,
                              csr_tcfg_periodic, csr_tcfg_en};
wire [31:0] tcfg_next_value = (csr_tcfg_value & ~csr_wmask)
                            | (csr_wvalue & csr_wmask);
// 顶层传入的csr_we已经排除了异常指令和ertn的提交，见csr_commit_we。
wire write_tcfg = csr_we && (csr_num == CSR_TCFG);
// TICLR[0]是写1清除位：必须同时满足选中该位、写入1，才清定时器pending。
// 写0或掩码未选中bit0均无效；TICLR本身不需要保存数据。
wire clear_timer = csr_we && (csr_num == CSR_TICLR)
                 && csr_wmask[0] && csr_wvalue[0];
// 到期判定使用时钟沿前的旧状态；置位优先于同拍TICLR清除。
// 计数从1减到0的时钟沿尚不置pending；下一个沿看到旧值为0时才置位。
wire timer_expire = csr_tcfg_en && (timer_cnt == 32'b0);

// 组合异步读：csr_num或对应寄存器变化后，csr_rvalue随之更新。
// 不需要csr_re；case包含default，所有路径均赋值，不会推导出锁存器。
// CSR读写指令可在提交沿前取得旧值，随后在同一上升沿更新寄存器。
always @(*) begin
    case (csr_num)
        // 本实验仅保存PLV/IE；DA(bit3)固定为1，PG(bit4)固定为0。
        // 其余未实现位读0，软件写入这些位也不会生成额外存储状态。
        CSR_CRMD:   csr_rvalue = 32'h00000008 | {29'b0, csr_crmd_ie, csr_crmd_plv};
        CSR_PRMD:   csr_rvalue = {29'b0, csr_prmd_pie, csr_prmd_pplv};
        CSR_ECFG:   csr_rvalue = {19'b0, csr_ecfg_lie};
        // bit31=0，ESubCode[30:22]，Ecode[21:16]，保留位[15:13]=0，IS[12:0]。
        CSR_ESTAT:  csr_rvalue = {1'b0, csr_estat_esubcode, csr_estat_ecode,
                                  3'b0, csr_estat_is};
        CSR_ERA:    csr_rvalue = csr_era;
        CSR_BADV:   csr_rvalue = csr_badv;
        CSR_EENTRY: csr_rvalue = {csr_eentry_va, 6'b0}; // 入口按64字节对齐。
        CSR_SAVE0:  csr_rvalue = csr_save0;
        CSR_SAVE1:  csr_rvalue = csr_save1;
        CSR_SAVE2:  csr_rvalue = csr_save2;
        CSR_SAVE3:  csr_rvalue = csr_save3;
        CSR_TID:    csr_rvalue = csr_tid;
        CSR_TCFG:   csr_rvalue = csr_tcfg_value;
        CSR_TVAL:   csr_rvalue = timer_cnt; // 读取实时计数，不会停止定时器。
        CSR_TICLR:  csr_rvalue = 32'b0;    // 写1清除接口，读出固定为0。
        default:    csr_rvalue = 32'b0;    // 未实现CSR的读出行为。
    endcase
end

// 先逐位检查“该源有pending且该源已使能”，再归约或，最后检查全局IE。
// has_int只表示存在可响应中断，异常令牌的生成和精确提交由流水线负责。
// 清全局IE或局部LIE只会屏蔽响应，不会清除ESTAT中的pending状态。
assign has_int    = csr_crmd_ie && (|(csr_estat_is & csr_ecfg_lie));//总开关，请求中断的中断源，允许响应的中断源
assign ex_entry   = {csr_eentry_va, 6'b0};//异常入口地址按64字节对齐
assign ertn_entry = csr_era;

// 同步状态更新。各段if分别控制不同寄存器，不是整块只有一个分支能执行。
// 同一上升沿的非阻塞赋值都使用沿前旧值，执行后统一更新状态。
always @(posedge clk) begin
    if (reset) begin
        // 复位后进入PLV0，关闭全局/局部中断，清除异常现场和中断状态。
        csr_crmd_plv       <= 2'b0;
        csr_crmd_ie        <= 1'b0;
        csr_prmd_pplv      <= 2'b0;
        csr_prmd_pie       <= 1'b0;
        csr_ecfg_lie       <= 13'b0;
        csr_estat_is_sw    <= 2'b0;
        csr_estat_is_hw    <= 8'b0;
        csr_estat_is_timer <= 1'b0;
        csr_estat_ecode    <= 6'b0;
        csr_estat_esubcode <= 9'b0;
        csr_era            <= 32'b0;
        csr_badv           <= 32'b0;
        csr_eentry_va      <= 26'b0;
        csr_save0          <= 32'b0;
        csr_save1          <= 32'b0;
        csr_save2          <= 32'b0;
        csr_save3          <= 32'b0;
        csr_tid            <= CORE_ID; // ID由参数提供，其余软件保存寄存器清零。
        csr_tcfg_en        <= 1'b0;
        csr_tcfg_periodic  <= 1'b0;
        csr_tcfg_initval   <= 30'b0;
        timer_cnt          <= 32'hffffffff; // 定时器关闭，计数处于停止哨兵值。
    end
    else begin
        // 外部中断每拍采样，不受异常、ertn或CSR软件写分支影响。
        // 这里保存电平而非锁存脉冲；外部撤销后，下一次采样会清除对应位。
        // 软件写ESTAT只修改软中断位，不能直接覆盖这八路采样结果。
        csr_estat_is_hw <= hw_int_in;

        // CRMD.PLV/IE的优先级：reset > wb_ex > ertn_flush > CSR软件写。
        // 进入异常时先把旧PLV/IE保存到PRMD，再进入PLV0并关闭全局中断。
        // 因为使用非阻塞赋值，保存的是异常前的值，不是本沿要写入的0。
        if (wb_ex) begin
            csr_prmd_pplv <= csr_crmd_plv;
            csr_prmd_pie  <= csr_crmd_ie;
            csr_crmd_plv  <= 2'b0;
            csr_crmd_ie   <= 1'b0;
        end
        else if (ertn_flush) begin
            // 异常返回：恢复先前的特权级和全局中断使能；PRMD本身保持不变。
            csr_crmd_plv <= csr_prmd_pplv;
            csr_crmd_ie  <= csr_prmd_pie;
        end
        else if (csr_we && csr_num == CSR_CRMD) begin
            // 仅PLV[1:0]和IE[2]可写；csr_merged已经完成逐位掩码合并。
            csr_crmd_plv <= csr_merged[1:0];
            csr_crmd_ie  <= csr_merged[2];
        end

        // 异常现场：主码/子码只能由异常硬件更新；ERA也允许软件修改。
        // ertn不会在这里清除现场，返回地址始终由ERA的当前值提供。
        if (wb_ex) begin
            csr_estat_ecode    <= wb_ecode;
            csr_estat_esubcode <= wb_esubcode;
            csr_era            <= wb_pc;
        end
        else if (!ertn_flush && csr_we && csr_num == CSR_ERA)
            csr_era <= csr_merged;

        // 只有最终选择为ADEF/ALE的异常才由硬件更新BADV。
        // Ecode=0x08为取指地址错误，0x09为访存地址对齐错误。
        // 中断、syscall、break、非法指令等其他异常不会通过此硬件分支改BADV。
        // wb_vaddr已由顶层根据异常来源选好，本模块直接保存完整32位地址。
        if (wb_ex && ((wb_ecode == 6'h08) || (wb_ecode == 6'h09)))//ADEF ALE
            csr_badv <= wb_vaddr;
        else if (!ertn_flush && csr_we && csr_num == CSR_BADV)
            csr_badv <= csr_merged;

        // 其他CSR的普通软件写：异常和ertn提交时不执行此写入口。
        // 未列出的CSR/字段不写入；TVAL只读，TICLR的写入副作用在后面处理。
        if (!wb_ex && !ertn_flush && csr_we) begin//没有提交异常，没有执行异常返回，存在被允许的CSR写入
            case (csr_num)
                CSR_PRMD: begin
                    // 允许异常处理程序调整返回时要恢复的PLV/IE。
                    csr_prmd_pplv <= csr_merged[1:0];
                    csr_prmd_pie  <= csr_merged[2];
                end
                // 0x1bff允许bit12、bit11、bit9:0，强制保留位bit10为0。
                // 虽然LIE[12]可保存使能，IS[12]在本实现固定为0，不会触发中断。
                CSR_ECFG:   csr_ecfg_lie    <= csr_merged[12:0] & 13'h1bff;
                CSR_ESTAT:  csr_estat_is_sw <= csr_merged[1:0]; // 只写软中断位。
                CSR_EENTRY: csr_eentry_va   <= csr_merged[31:6]; // 舍弃入口低6位。
                CSR_SAVE0:  csr_save0       <= csr_merged;
                CSR_SAVE1:  csr_save1       <= csr_merged;
                CSR_SAVE2:  csr_save2       <= csr_merged;
                CSR_SAVE3:  csr_save3       <= csr_merged;
                CSR_TID:    csr_tid         <= csr_merged;
                CSR_TCFG: begin
                    // 更新三个配置字段，计数器装载在下方独立处理。
                    csr_tcfg_en       <= tcfg_next_value[0];
                    csr_tcfg_periodic <= tcfg_next_value[1];
                    csr_tcfg_initval  <= tcfg_next_value[31:2];
                end
                default: begin end
            endcase
        end

        // TCFG每次有效写且合并后En=1都按新值重装；En=0保持计数值。
        // 计数器优先级：reset > 写TCFG > 已使能时递减/到期处理 > 保持。
        // 即使En原来已经为1，再次写TCFG且合并后En=1也会重新开始计时。
        if (write_tcfg) begin
            if (tcfg_next_value[0])
                // InitVal左移2位形成实际初值，低2位补0；使用本次写后的配置。
                timer_cnt <= {tcfg_next_value[31:2], 2'b00};
            // 合并后En=0时不赋值：冻结旧计数，同时配置分支会关闭定时器。
        end
        else if (csr_tcfg_en && (timer_cnt != 32'hffffffff)) begin
            if (timer_cnt == 32'b0)
                // 旧计数已经到0：周期模式重装旧配置的InitVal，单次模式停止。
                // 单次到期不会把TCFG.En清零，而是用0xffffffff阻止继续递减。
                timer_cnt <= csr_tcfg_periodic
                           ? {csr_tcfg_initval, 2'b00} : 32'hffffffff;
            else
                // 使能且尚未到期时，每个时钟周期减1，与流水线暂停无关。
                timer_cnt <= timer_cnt - 32'd1;
        end

        // 定时器pending是保持型状态，与timer_cnt的递减/重装分开更新。
        // 到期后即使关闭定时器或进入异常，pending仍保留，直到写TICLR清除。
        // 同拍“旧计数到期”和“TICLR写1”时，到期置位优先，避免丢失新事件。
        // 写TCFG也不会抑制基于旧状态判断出的本拍到期事件。
        if (timer_expire)
            csr_estat_is_timer <= 1'b1;
        else if (clear_timer)
            csr_estat_is_timer <= 1'b0;
    end
end

endmodule
