// pio64_out — 64-bit output PIO (HPS writes → FPGA output)
//
// BUG FIX: added avs_s0_byteenable port.
//
// WHY THIS MATTERS:
//   The HPS H2F AXI master is 32-bit wide.  When the HPS does a
//   32-bit write to a 64-bit Avalon slave, the Qsys mm_bridge passes
//   the 32-bit data in the correct byte lane of avs_s0_writedata and
//   sets the matching byteenable bits.  WITHOUT byteenable handling,
//   a write to the LOW 32 bits also zeroes the HIGH 32 bits and vice
//   versa — corrupting the PIO value.
//
// NOTE ON SYNTHESIS:
//   The generated soc_system/synthesis/soc_system.v does NOT connect
//   avs_s0_byteenable to this module (Qsys didn't know about it).
//   To fully activate this fix you must either:
//     a) Re-run Platform Designer / Qsys to regenerate the IP, or
//     b) Manually wire the byteenable from mm_interconnect_2 (see
//        soc_system_mm_interconnect_2.v, wire pio64_out_0_s0_agent_m0_byteenable).
//   Until then the port will be left unconnected (treated as all-ones
//   by the synthesizer → full 64-bit write, same as before the fix).
//   The DE10_NANO_SoC_GHRD.v fix (cross-PIO addition) makes the adder
//   work correctly WITHOUT needing byteenable, so the system works
//   even before you regenerate.
//
// DEBUG:
//   Simulation $display lines are wrapped in synthesis translate_off
//   so they are stripped during synthesis but active in Verilator /
//   ModelSim / VCS.

module pio64_out (
  input  logic        clk,
  input  logic        reset,

  // Avalon-MM slave interface
  input  logic        avs_s0_write,
  input  logic [7:0]  avs_s0_byteenable,   // NEW: byte-lane enable
  input  logic [63:0] avs_s0_writedata,
  output logic [63:0] pio_out
);

always_ff @(posedge clk) begin
  if (reset) begin
    pio_out <= 64'd0;

    // synthesis translate_off
    $display("[pio64_out] t=%0t  RESET — pio_out cleared to 0", $time);
    // synthesis translate_on

  end else if (avs_s0_write) begin
    // Apply only the enabled byte lanes — prevents 32-bit HPS writes
    // from corrupting the untouched 32-bit half.
    for (int i = 0; i < 8; i++) begin
      if (avs_s0_byteenable[i])
        pio_out[i*8 +: 8] <= avs_s0_writedata[i*8 +: 8];
    end

    // synthesis translate_off
    $display("[pio64_out] t=%0t  WRITE  writedata=0x%016h  byteenable=0b%08b  pio_out_next=?",
             $time, avs_s0_writedata, avs_s0_byteenable);
    // synthesis translate_on
  end
end

// synthesis translate_off
always_ff @(posedge clk) begin
  if (!reset && avs_s0_write) begin
    // Print the result one cycle later so pio_out reflects the update
    @(posedge clk);
    $display("[pio64_out] t=%0t  pio_out after write = 0x%016h", $time, pio_out);
  end
end
// synthesis translate_on

endmodule
