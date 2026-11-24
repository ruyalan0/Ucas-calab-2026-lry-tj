`timescale 1ns/1ps
`default_nettype none
// Combinational LA32 translation. fault = {TLBR, invalid, privilege, modified}.
// No virtual-address hole is imposed on the LA32 address space.
module mmu(
    input wire [31:0] vaddr,
    input wire [1:0] plv,
    input wire paging,
    input wire [31:0] dmw0, dmw1,
    input wire is_store, found,
    input wire [19:0] ppn,
    input wire [5:0] ps,
    input wire [1:0] page_plv,
    input wire page_v, page_d,
    output wire [31:0] paddr,
    output wire [3:0] fault
);
wire hit0 = vaddr[31:29] == dmw0[31:29] &&
            ((plv == 2'd0 && dmw0[0]) || (plv == 2'd3 && dmw0[3]));
wire hit1 = vaddr[31:29] == dmw1[31:29] &&
            ((plv == 2'd0 && dmw1[0]) || (plv == 2'd3 && dmw1[3]));
wire use_tlb = paging && !hit0 && !hit1;
// Retain exp18's PS=21 compatibility in addition to LA32 PS=12/22.
wire [31:0] tlb_addr = ps == 6'd22 ? {ppn[19:10], vaddr[21:0]} :
                      ps == 6'd21 ? {ppn[19:9], vaddr[20:0]} :
                                      {ppn, vaddr[11:0]};
assign paddr = !paging ? vaddr :
              hit0 ? {dmw0[27:25], vaddr[28:0]} :
              hit1 ? {dmw1[27:25], vaddr[28:0]} : tlb_addr;
// Exclusive faults encode architectural priority: found -> V -> PLV -> D.
assign fault[3] = use_tlb && !found;
assign fault[2] = use_tlb && found && !page_v;
assign fault[1] = use_tlb && found && page_v && plv > page_plv;
assign fault[0] = use_tlb && found && page_v && plv <= page_plv && is_store && !page_d;
endmodule
`default_nettype wire
