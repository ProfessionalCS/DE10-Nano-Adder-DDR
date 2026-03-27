// pio64_in — 64-bit input PIO (FPGA drives → HPS reads)
//
// FIX: changed default avs_s0_readdata from 'x to 64'd0.
//   'x synthesises to don't-care (fine for hardware) but
//   causes X-propagation in simulation that masks real bugs.
//
// DEBUG: simulation $display lines (stripped by synthesis).

module pio64_in (
  input  logic        clk,
  input  logic        reset,

  // Avalon-MM slave interface
  input  logic        avs_s0_read,
  output logic [63:0] avs_s0_readdata,

  // FPGA-side data bus
  input  logic [63:0] pio_in
);

always_comb begin
  if (avs_s0_read) begin
    avs_s0_readdata = pio_in;
  end else begin
    avs_s0_readdata = 64'd0;   // was 'x — changed to 0 for simulation cleanliness
  end
end

// synthesis translate_off
//
// DEBUG: print every HPS read so you can see what the HPS is observing.
// In a real simulation testbench the clock is driven, so these fire.
// On hardware these lines are stripped by the synthesizer.
always_ff @(posedge clk) begin
  if (!reset && avs_s0_read) begin
    $display("[pio64_in]  t=%0t  HPS READ  pio_in=0x%016h  (sum_a=0x%08h  debug=0x%08h)",
             $time,
             pio_in,
             pio_in[31:0],     // sum_a in low word
             pio_in[63:32]);   // debug word in high word
  end
end
// synthesis translate_on

endmodule
