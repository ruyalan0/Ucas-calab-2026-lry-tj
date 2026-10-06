`timescale 1ns / 1ps
`default_nettype none

// One outstanding division. Requires the NonBlocking IP configuration in
// create_exp10_ip.tcl: paired inputs, 8 clocks/division, no output TREADY.
module div_unit(
    input  wire        clk,
    input  wire        reset,
    input  wire        resetn,
    input  wire        enable,
    input  wire        signed_mode,
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    input  wire        consume,
    output wire        done,
    output reg  [31:0] quotient,
    output reg  [31:0] remainder
);
localparam [1:0] IDLE = 2'd0, SEND = 2'd1, WAIT = 2'd2, DONE = 2'd3;
reg [1:0] state;
reg [31:0] dividend_r, divisor_r;
reg signed_r;

// Hold both IPs in reset for at least two sampled clocks and wait one more
// clock after release for the IP's internally registered reset to propagate.
reg [1:0] reset_release;
reg ip_up;
wire active = resetn && !reset;
wire ip_resetn = active && (&reset_release);
always @(posedge clk) begin
    if (!active) begin
        reset_release <= 2'b00;
        ip_up <= 1'b0;
    end else begin
        reset_release <= {reset_release[0], 1'b1};
        ip_up <= ip_resetn;
    end
end

wire send_valid = active && ip_up && (state == SEND);
wire signed_valid = send_valid && signed_r;
wire unsigned_valid = send_valid && !signed_r;
wire s_dividend_ready, s_divisor_ready, s_out_valid;
wire u_dividend_ready, u_divisor_ready, u_out_valid;
wire [63:0] s_out_data, u_out_data;
wire selected_ready = signed_r ? (s_dividend_ready && s_divisor_ready)
                                      : (u_dividend_ready && u_divisor_ready);
wire ip_fire = send_valid && selected_ready;
wire selected_out_valid = signed_r ? s_out_valid : u_out_valid;
wire [63:0] selected_out_data = signed_r ? s_out_data : u_out_data;

exp10_div_signed u_signed(
    .aclk(clk), .aresetn(ip_resetn),
    .s_axis_dividend_tvalid(signed_valid),
    .s_axis_dividend_tready(s_dividend_ready),
    .s_axis_dividend_tdata(dividend_r),
    .s_axis_divisor_tvalid(signed_valid),
    .s_axis_divisor_tready(s_divisor_ready),
    .s_axis_divisor_tdata(divisor_r),
    .m_axis_dout_tvalid(s_out_valid),
    .m_axis_dout_tdata(s_out_data)
);

exp10_div_unsigned u_unsigned(
    .aclk(clk), .aresetn(ip_resetn),
    .s_axis_dividend_tvalid(unsigned_valid),
    .s_axis_dividend_tready(u_dividend_ready),
    .s_axis_dividend_tdata(dividend_r),
    .s_axis_divisor_tvalid(unsigned_valid),
    .s_axis_divisor_tready(u_divisor_ready),
    .s_axis_divisor_tdata(divisor_r),
    .m_axis_dout_tvalid(u_out_valid),
    .m_axis_dout_tdata(u_out_data)
);

assign done = active && ip_up && (state == DONE);
always @(posedge clk) begin
    if (!active || !ip_up) begin
        state <= IDLE;
        signed_r <= 1'b0;
        dividend_r <= 32'b0;
        divisor_r <= 32'b0;
        quotient <= 32'b0;
        remainder <= 32'b0;
    end else begin
        case (state)
            IDLE: if (enable) begin
                dividend_r <= dividend;
                divisor_r <= divisor;
                signed_r <= signed_mode;
                state <= SEND;
            end
            SEND: if (ip_fire)
                state <= WAIT;
            WAIT: if (selected_out_valid) begin
                quotient <= selected_out_data[63:32];
                remainder <= selected_out_data[31:0];
                state <= DONE;
            end
            DONE: if (consume)
                state <= IDLE;
            default: state <= IDLE;
        endcase
    end
end
endmodule
