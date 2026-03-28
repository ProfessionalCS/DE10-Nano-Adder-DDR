// pio128_out — 128-bit output PIO (HPS writes → FPGA reads)
//
// The HPS H2F bus is 32-bit wide. Each 32-bit write sets the
// matching byteenable lanes only — the other 96 bits are untouched.
// This lets you write all four 32-bit words independently:
//   write base+0x0  → bits [31:0]
//   write base+0x4  → bits [63:32]
//   write base+0x8  → bits [95:64]
//   write base+0xC  → bits [127:96]

module pio128_out (
    input  logic          clk,
    input  logic          reset,

    // Avalon-MM slave
    input  logic          avs_s0_write,
    input  logic [15:0]   avs_s0_byteenable,
    input  logic [127:0]  avs_s0_writedata,

    // FPGA-side outputs (Qsys generates two ports: one for the
    // avalon_slave_0 readdata interface, one for the pio128 conduit)
    output logic [127:0]  pio_out,
    output logic [127:0]  pio128_out
);

always_ff @(posedge clk) begin
    if (reset) begin
        pio_out <= 128'd0;
    end else if (avs_s0_write) begin
        for (int i = 0; i < 16; i++) begin
            if (avs_s0_byteenable[i])
                pio_out[i*8 +: 8] <= avs_s0_writedata[i*8 +: 8];
        end
    end
end

assign pio128_out = pio_out;

endmodule
