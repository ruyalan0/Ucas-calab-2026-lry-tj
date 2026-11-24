`timescale 1ns / 1ps
`default_nettype none

// Independent fully associative TLB. Initialize by INVTLB 0/1 or indexed
// writes before use: the textbook interface deliberately has no reset port.
module tlb #(parameter TLBNUM = 16)(
    input wire clk,
    input wire [18:0] s0_vppn,
    input wire s0_va_bit12,
    input wire [9:0] s0_asid,
    output wire s0_found,
    output reg [$clog2(TLBNUM)-1:0] s0_index,
    output wire [19:0] s0_ppn,
    output wire [5:0] s0_ps,
    output wire [1:0] s0_plv,
    output wire [1:0] s0_mat,
    output wire s0_d,
    output wire s0_v,
    input wire [18:0] s1_vppn,
    input wire s1_va_bit12,
    input wire [9:0] s1_asid,
    output wire s1_found,
    output reg [$clog2(TLBNUM)-1:0] s1_index,
    output wire [19:0] s1_ppn,
    output wire [5:0] s1_ps,
    output wire [1:0] s1_plv,
    output wire [1:0] s1_mat,
    output wire s1_d,
    output wire s1_v,
    input wire invtlb_valid,
    input wire [4:0] invtlb_op,
    input wire we,
    input wire [$clog2(TLBNUM)-1:0] w_index,
    input wire w_e,
    input wire [18:0] w_vppn,
    input wire [5:0] w_ps,
    input wire [9:0] w_asid,
    input wire w_g,
    input wire [19:0] w_ppn0,
    input wire [1:0] w_plv0,
    input wire [1:0] w_mat0,
    input wire w_d0,
    input wire w_v0,
    input wire [19:0] w_ppn1,
    input wire [1:0] w_plv1,
    input wire [1:0] w_mat1,
    input wire w_d1,
    input wire w_v1,
    input wire [$clog2(TLBNUM)-1:0] r_index,
    output wire r_e,
    output wire [18:0] r_vppn,
    output wire [5:0] r_ps,
    output wire [9:0] r_asid,
    output wire r_g,
    output wire [19:0] r_ppn0,
    output wire [1:0] r_plv0,
    output wire [1:0] r_mat0,
    output wire r_d0,
    output wire r_v0,
    output wire [19:0] r_ppn1,
    output wire [1:0] r_plv1,
    output wire [1:0] r_mat1,
    output wire r_d1,
    output wire r_v1
);
localparam INDEX_WIDTH = $clog2(TLBNUM);
reg [TLBNUM-1:0] tlb_e;
reg [18:0] tlb_vppn [0:TLBNUM-1];
// Preserve PS: supplied harness uses 21 (2 MiB); 4 MiB uses 22.
reg [5:0] tlb_ps [0:TLBNUM-1];
reg [9:0] tlb_asid [0:TLBNUM-1];
reg [TLBNUM-1:0] tlb_g;
// Page data = {PPN, PLV, MAT, D, V}.
reg [25:0] tlb_page0 [0:TLBNUM-1];
reg [25:0] tlb_page1 [0:TLBNUM-1];
wire [TLBNUM-1:0] match0, match1;
genvar i;
generate for (i = 0; i < TLBNUM; i = i + 1) begin : entry_logic
    wire vpn_match0, vpn_match1, asid_match1;
    reg invalidate;
    // VPPN = VA[31:13]. Remove the offset AND the even/odd page bit.
    assign vpn_match0 = (tlb_ps[i] == 6'd22) ?
                            (s0_vppn[18:10] == tlb_vppn[i][18:10]) :
                        (tlb_ps[i] == 6'd21) ?
                            (s0_vppn[18:9] == tlb_vppn[i][18:9]) :
                            (s0_vppn == tlb_vppn[i]);
    assign vpn_match1 = (tlb_ps[i] == 6'd22) ?
                            (s1_vppn[18:10] == tlb_vppn[i][18:10]) :
                        (tlb_ps[i] == 6'd21) ?
                            (s1_vppn[18:9] == tlb_vppn[i][18:9]) :
                            (s1_vppn == tlb_vppn[i]);
    assign asid_match1 = (s1_asid == tlb_asid[i]);
    assign match0[i] = tlb_e[i] && vpn_match0 &&
                       (tlb_g[i] || (s0_asid == tlb_asid[i]));
    assign match1[i] = tlb_e[i] && vpn_match1 &&
                       (tlb_g[i] || asid_match1);

    // INVTLB reuses search port 1, and clears E only.
    always @(*) begin
        case (invtlb_op)
            5'd0, 5'd1: invalidate = 1'b1;
            5'd2: invalidate = tlb_g[i];
            5'd3: invalidate = !tlb_g[i];
            5'd4: invalidate = !tlb_g[i] && asid_match1;
            5'd5: invalidate = !tlb_g[i] && asid_match1 && vpn_match1;
            5'd6: invalidate = (tlb_g[i] || asid_match1) && vpn_match1;
            default: invalidate = 1'b0;
        endcase
    end
    always @(posedge clk) begin
        // An indexed write wins on this entry. Invalidation can still
        // clear other entries on the same edge.
        if (we && w_index == i) begin
            tlb_e[i] <= w_e;
            tlb_vppn[i] <= w_vppn;
            tlb_ps[i] <= w_ps;
            tlb_asid[i] <= w_asid;
            tlb_g[i] <= w_g;
            tlb_page0[i] <= {w_ppn0, w_plv0, w_mat0, w_d0, w_v0};
            tlb_page1[i] <= {w_ppn1, w_plv1, w_mat1, w_d1, w_v1};
        end else if (invtlb_valid && invalidate) begin
            tlb_e[i] <= 1'b0;
        end
    end
end endgenerate

assign s0_found = |match0;
assign s1_found = |match1;
integer k;
always @(*) begin
    s0_index = {INDEX_WIDTH{1'b0}};
    s1_index = {INDEX_WIDTH{1'b0}};
    // Deterministic lowest index if software creates duplicate hits.
    for (k = TLBNUM-1; k >= 0; k = k-1) begin
        if (match0[k]) s0_index = k[INDEX_WIDTH-1:0];
        if (match1[k]) s1_index = k[INDEX_WIDTH-1:0];
    end
end
wire odd0 = (tlb_ps[s0_index] == 6'd22) ? s0_vppn[9] :
            (tlb_ps[s0_index] == 6'd21) ? s0_vppn[8] : s0_va_bit12;
wire odd1 = (tlb_ps[s1_index] == 6'd22) ? s1_vppn[9] :
            (tlb_ps[s1_index] == 6'd21) ? s1_vppn[8] : s1_va_bit12;
assign {s0_ppn, s0_plv, s0_mat, s0_d, s0_v} = !s0_found ? 26'b0 :
                          (odd0 ? tlb_page1[s0_index] : tlb_page0[s0_index]);
assign {s1_ppn, s1_plv, s1_mat, s1_d, s1_v} = !s1_found ? 26'b0 :
                          (odd1 ? tlb_page1[s1_index] : tlb_page0[s1_index]);
assign s0_ps = s0_found ? tlb_ps[s0_index] : 6'b0;
assign s1_ps = s1_found ? tlb_ps[s1_index] : 6'b0;
// Indexed reads expose raw stored fields even if E=0. Exp18's CPU is
// responsible for TLBRD's architectural CSR clearing when E=0.
assign r_e = tlb_e[r_index];
assign r_vppn = tlb_vppn[r_index];
assign r_ps = tlb_ps[r_index];
assign r_asid = tlb_asid[r_index];
assign r_g = tlb_g[r_index];
assign {r_ppn0, r_plv0, r_mat0, r_d0, r_v0} = tlb_page0[r_index];
assign {r_ppn1, r_plv1, r_mat1, r_d1, r_v1} = tlb_page1[r_index];
endmodule
`default_nettype wire
