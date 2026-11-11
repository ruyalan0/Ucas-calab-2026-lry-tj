`timescale 1ns / 1ps
`default_nettype none

// Xilinx mult_gen v12.0: signed 33x33, full 66-bit output, PipeStages=0.
module mul_unit(
    input  wire [31:0] src1,
    input  wire [31:0] src2,
    input  wire        signed_mode,
    output wire [63:0] product
);
wire [32:0] mul_a = {signed_mode & src1[31], src1};
wire [32:0] mul_b = {signed_mode & src2[31], src2};
wire [65:0] product66;

exp10_mul33 u_multiplier(.A(mul_a), .B(mul_b), .P(product66));
assign product = product66[63:0];
endmodule
