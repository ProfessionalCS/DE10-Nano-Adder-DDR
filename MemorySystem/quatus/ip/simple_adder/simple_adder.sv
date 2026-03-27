
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */

module simple_adder(
  input  logic [63:0] a,      // a[15:0]  = x_in
                               // a[31:16] = y_in
                               // a[32]    = start_in
                               // a[33]    = rst_in_N (active low, so 1 = running)
  input  logic [63:0] b,      // unused for now, available for future use
  input  logic        c,      // clock
  output logic [63:0] sum     // sum[15:0]  = fp result
                               // sum[19:16] = oor flags
                               // sum[20]    = valid
                               // sum[21]    = ready
										 
);

  logic [15:0] x_in;
  logic [15:0] y_in;
  logic        start_in;
  logic        rst_in_N;

  logic [15:0] fp_result;
  logic [3:0]  fp_oor;
  logic        fp_valid;
  logic        fp_ready;

  // Unpack inputs from 'a'
  assign x_in    = a[15:0];
  assign y_in    = a[31:16];
  assign start_in = a[32];
  assign rst_in_N = a[33];

  // Instantiate fpmult
  fpmult #(.P(8), .Q(8)) fp_inst (
    .rst_in_N  (rst_in_N),
    .clk_in    (c),
    .x_in      (x_in),
    .y_in      (y_in),
    .round_in  (2'b00),
    .start_in  (start_in),
    .p_out     (fp_result),
    .oor_out   (fp_oor),
    .valid_out (fp_valid),
    .ready_out (fp_ready)
  );

  // Pack outputs into 'sum'
  assign sum[15:0]  = fp_result;
  assign sum[19:16] = fp_oor;
  assign sum[20]    = fp_valid;
  assign sum[21]    = fp_ready;
  assign sum[63:22] = '0;

endmodule
