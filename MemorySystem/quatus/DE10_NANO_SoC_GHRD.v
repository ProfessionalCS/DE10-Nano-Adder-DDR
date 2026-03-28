//=======================================================
//  DE10-Nano Adder with DDR3 Interface
//  Board: Terasic DE10-Nano (Cyclone V 5CSEBA6U23I7)
//=======================================================
//
// WHAT THIS DOES
// --------------
// The HPS (ARM CPU running Linux) talks to the FPGA over the
// H2F bridge at 0xC0000000. The FPGA adds two 32-bit numbers
// and writes the result to DDR3 memory.
//
//   HPS writes operand 1 → adder_a PIO
//   HPS writes operand 2 → adder_b PIO
//   FPGA computes sum = operand1 + operand2
//   HPS reads sum back from adder_sum PIO
//   FPGA also auto-writes sum to DDR3 at 0x3FFF003C
//
//
// ADDRESS MAP (H2F bridge at 0xC0000000)
// --------------------------------------
// These addresses are set by Qsys (Platform Designer).
// The HPS writes/reads these using /dev/mem + mmap.
//
//   Address      Offset  What                   R/W   Size
//   0xC0000000   +0x00   pio128 word 0          W     128-bit PIO
//   0xC0000004   +0x04   pio128 word 1          W       (4 independent
//   0xC0000008   +0x08   pio128 word 2          W        32-bit words,
//   0xC000000C   +0x0C   pio128 word 3          W        byteenable-safe)
//   0xC0000010   +0x10   sum (result)           R     64-bit status PIO
//   0xC0000014   +0x14   debug word             R       (see below)
//   0xC0000018   +0x18   adder_b (operand 2)    W     64-bit PIO
//   0xC0000020   +0x20   adder_a (operand 1)    W     64-bit PIO
//
//   IMPORTANT: Do NOT use 0xFF200000 (LW bridge) — it is DISABLED
//   in this design. Accessing it will hang the bus and kill SSH.
//
//
// DDR3 MEMORY PATH (FPGA → DDR3)
// -------------------------------
// The FPGA writes the sum to DDR3 automatically whenever the HPS
// writes new operands. It goes through:
//   simple_mem.sv → fpga_mem_bridge → hps_0.f2h_axi_slave → DDR3
//
// The address 0x3FFF0000 is chosen in this file (see ADDR_A below).
// The sum lands at 0x3FFF003C because simple_mem writes a 512-bit
// cache line in 8 x 64-bit beats, and the sum is in the top 32 bits.
//
//
// DEBUG WORD (read at 0xC0000014)
// -------------------------------
//   Bits    What                            How to check
//   [31:24] Magic = 0xDB                    If not 0xDB: bridge is dead
//   [23]    Heartbeat                       Toggles every ~1 second
//   [22]    hps_fpga_reset_n                1 = HPS is running
//   [21]    pio_dirty                       1 = new write, DDR3 pending
//   [20]    ddr3_written                    1 = DDR3 written at least once
//   [19:18] seq state                       0=idle, 1=writing, 2=writing
//
//
// LEDs
// ----
//   LED[7]   Heartbeat (1 Hz blink = FPGA alive)
//   LED[6]   pio_dirty (HPS wrote something)
//   LED[5]   DDR3 write in progress
//   LED[4]   HPS running (reset released)
//   LED[3:0] DEADBEEF latch (write 0xDEADBEEF to adder_a to trigger)
//
//
// QUICK TEST (SSH into board as root)
// ------------------------------------
//   ./enable_bridges
//   ./devmem2 0xC0000014 w                   # check 0xDB magic
//   ./devmem2 0xC0000020 w w 0x1000          # operand 1
//   ./devmem2 0xC0000018 w w 0x0234          # operand 2
//   ./devmem2 0xC0000010 w                   # read sum → 0x1234
//   sleep 0.02 && ./devmem2 0x3FFF003C w     # DDR3 → 0x1234
//
//=======================================================

module DE10_NANO_SoC_GHRD(

    //////////// CLOCK //////////
    input               FPGA_CLK1_50,
    input               FPGA_CLK2_50,
    input               FPGA_CLK3_50,

    //////////// HPS DDR3 (active by the hard memory controller) //////////
    // These pin names are BOARD-SPECIFIC to the DE10-Nano.
    // They are assigned to physical FPGA balls in the .qsf file.
    // If you port this to a different board, you MUST change these
    // to match that board's DDR3 pin names and pin assignments.
    output   [14: 0]    HPS_DDR3_ADDR,
    output   [ 2: 0]    HPS_DDR3_BA,
    output              HPS_DDR3_CAS_N,
    output              HPS_DDR3_CK_N,
    output              HPS_DDR3_CK_P,
    output              HPS_DDR3_CKE,
    output              HPS_DDR3_CS_N,
    output   [ 3: 0]    HPS_DDR3_DM,
    inout    [31: 0]    HPS_DDR3_DQ,
    inout    [ 3: 0]    HPS_DDR3_DQS_N,
    inout    [ 3: 0]    HPS_DDR3_DQS_P,
    output              HPS_DDR3_ODT,
    output              HPS_DDR3_RAS_N,
    output              HPS_DDR3_RESET_N,
    input               HPS_DDR3_RZQ,
    output              HPS_DDR3_WE_N,

    //////////// LED //////////
    output   [ 7: 0]    LED
);

//=======================================================
//  Wires connecting to the Qsys system (soc_system)
//=======================================================
wire         hps_fpga_reset_n;     // 1 = HPS is running, 0 = held in reset
wire         fpga_clk_50;          // 50 MHz clock from board oscillator
wire [63:0]  adder_a_export;       // HPS writes operand 1 here (via PIO at 0x20)
wire [63:0]  adder_b_export;       // HPS writes operand 2 here (via PIO at 0x18)
wire [63:0]  adder_sum_export;     // FPGA drives result + debug back to HPS (PIO at 0x10)
wire [127:0] pio128_out_export;    // 128-bit general-purpose PIO from HPS (at 0x00)

assign fpga_clk_50 = FPGA_CLK1_50;

//=======================================================
//  Heartbeat — 1 Hz LED blink so you know the FPGA is alive
//  Counts to 50 million (50 MHz clock) then toggles
//=======================================================
reg [25:0] heartbeat_cnt;
reg        heartbeat;

always @(posedge fpga_clk_50 or negedge hps_fpga_reset_n) begin
    if (!hps_fpga_reset_n) begin
        heartbeat_cnt <= 26'd0;
        heartbeat     <= 1'b0;
    end else begin
        if (heartbeat_cnt == 26'd49_999_999) begin
            heartbeat_cnt <= 26'd0;
            heartbeat     <= ~heartbeat;  // toggle every 1 second
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 26'd1;
        end
    end
end

//=======================================================
//  Adder — the actual computation
//
//  Each operand comes from a SEPARATE PIO so they don't
//  interfere with each other. We only use the low 32 bits
//  of each 64-bit PIO (the high 32 bits get clobbered on
//  every write because pio64_out has no byteenable).
//=======================================================
wire [31:0] sum_a = adder_a_export[31:0] + adder_b_export[31:0];
wire [31:0] sum_b = adder_a_export[63:32] + adder_b_export[63:32]; // not used in tests

// Simulation-only debug prints (ignored by Quartus)
// synthesis translate_off
always @(posedge fpga_clk_50) begin
    if (adder_a_export !== 64'bx && adder_b_export !== 64'bx) begin
        $display("[ADDER] t=%0t  adder_a[31:0]=0x%08h  adder_b[31:0]=0x%08h  sum_a=0x%08h",
                 $time,
                 adder_a_export[31:0],
                 adder_b_export[31:0],
                 sum_a);
    end
end
// synthesis translate_on

//=======================================================
//  DEADBEEF trigger — fun LED test
//  Write 0xDEADBEEF to adder_a and LED[3:0] latches
//  whatever is in adder_b[3:0] at that moment.
//=======================================================
reg [3:0] led_latch;
always @(posedge fpga_clk_50 or negedge hps_fpga_reset_n) begin
    if (!hps_fpga_reset_n)
        led_latch <= 4'h0;
    else if (adder_a_export[31:0] == 32'hDEAD_BEEF)
        led_latch <= adder_b_export[3:0];
end

// synthesis translate_off
always @(posedge fpga_clk_50) begin
    if (adder_a_export[31:0] == 32'hDEAD_BEEF)
        $display("[LED] t=%0t  DEADBEEF trigger! latching adder_b[3:0]=0x%h into LED[3:0]",
                 $time, adder_b_export[3:0]);
end
// synthesis translate_on

//=======================================================
//  DDR3 write — automatically saves results to memory
//
//  Whenever the HPS writes new operands, the FPGA packs
//  the sum into a 512-bit (64-byte) cache line and writes
//  it to DDR3 via the F2H bridge.
//
//  You can pick any DDR3 address here. We use the top of
//  the 1 GB range so it doesn't collide with Linux.
//  You can accidentally break the kernel if you play with this and have to re-image ;<
//  The HPS can read the result with: devmem2 0x3FFF003C w
//=======================================================
localparam [31:0] ADDR_A = 32'h3FFF_0000;  // MAGIC NUMBER — hand-picked DDR3 address
localparam [31:0] ADDR_B = 32'h3FFF_0040;  // MAGIC NUMBER — 64 bytes after ADDR_A 

wire [511:0] line_a = {sum_a, 480'd0};     // sum_a in top 32 bits, rest zero
wire [511:0] line_b = {sum_b, 480'd0};

// Detect when the HPS writes new operands
reg [63:0] prev_a, prev_b;
reg        pio_dirty;
always @(posedge fpga_clk_50 or negedge hps_fpga_reset_n) begin
    if (!hps_fpga_reset_n) begin
        prev_a    <= 64'd0;
        prev_b    <= 64'd0;
        pio_dirty <= 1'b0;
    end else begin
        prev_a <= adder_a_export;
        prev_b <= adder_b_export;
        if (adder_a_export != prev_a || adder_b_export != prev_b)
            pio_dirty <= 1'b1;
        else if (seq_start)
            pio_dirty <= 1'b0;
    end
end

// synthesis translate_off
always @(posedge fpga_clk_50) begin
    if (adder_a_export != prev_a || adder_b_export != prev_b)
        $display("[PIO]  t=%0t  PIO changed → pio_dirty asserted. a=0x%016h b=0x%016h",
                 $time, adder_a_export, adder_b_export);
end
// synthesis translate_on

// Simple state machine: when pio_dirty fires, write line_a then line_b to DDR3
reg  [1:0]  seq;             // 0 = idle, 1 = writing sum_a, 2 = writing sum_b
reg         mem_request;
reg  [31:0] mem_addr;
reg  [511:0] mem_wdata;
wire         mem_done;
wire         seq_start = (seq == 2'd0) && pio_dirty;

// Stays high forever after the first successful DDR3 write
reg ddr3_written;
always @(posedge fpga_clk_50 or negedge hps_fpga_reset_n) begin
    if (!hps_fpga_reset_n) ddr3_written <= 1'b0;
    else if (mem_done)     ddr3_written <= 1'b1;
end

always @(posedge fpga_clk_50 or negedge hps_fpga_reset_n) begin
    if (!hps_fpga_reset_n) begin
        seq         <= 2'd0;
        mem_request <= 1'b0;
        mem_addr    <= 32'd0;
        mem_wdata   <= 512'd0;
    end else begin
        mem_request <= 1'b0;        // default: no request this cycle
        case (seq)
        2'd0: if (pio_dirty) begin  // kick off adder A
            mem_request <= 1'b1;
            mem_addr    <= ADDR_A;
            mem_wdata   <= line_a;
            seq         <= 2'd1;
        end
        2'd1: if (mem_done) begin   // A done → kick off B
            mem_request <= 1'b1;
            mem_addr    <= ADDR_B;
            mem_wdata   <= line_b;
            seq         <= 2'd2;
        end
        2'd2: if (mem_done) begin   // B done → back to idle
            seq <= 2'd0;
        end
        default: seq <= 2'd0;
        endcase
    end
end

// synthesis translate_off
always @(posedge fpga_clk_50) begin
    if (mem_request)
        $display("[DDR3] t=%0t  mem_request seq=%0d  addr=0x%08h  data[511:480]=0x%08h",
                 $time, seq, mem_addr, mem_wdata[511:480]);
    if (mem_done)
        $display("[DDR3] t=%0t  mem_done (DDR3 write completed)", $time);
end
// synthesis translate_on

// simple_mem: takes a 512-bit value and writes it to DDR3
// as 8 sequential 64-bit Avalon beats (no bursts, dead simple)
wire [31:0] avm_address;
wire        avm_read;
wire        avm_write;
wire [63:0] avm_writedata;
wire [7:0]  avm_byteenable;
wire [63:0] avm_readdata;
wire        avm_readdatavalid;
wire        avm_waitrequest;

simple_mem mem0 (
    .clk            (fpga_clk_50),
    .rst_n          (hps_fpga_reset_n),
    .request        (mem_request),
    .store          (1'b1),
    .addr           (mem_addr),
    .wdata          (mem_wdata),
    .rdata          (),
    .done           (mem_done),
    .avm_address    (avm_address),
    .avm_read       (avm_read),
    .avm_write      (avm_write),
    .avm_writedata  (avm_writedata),
    .avm_byteenable (avm_byteenable),
    .avm_readdata   (avm_readdata),
    .avm_readdatavalid (avm_readdatavalid),
    .avm_waitrequest(avm_waitrequest)
);

// synthesis translate_off
always @(posedge fpga_clk_50) begin
    if (avm_write)
        $display("[AVM]  t=%0t  Avalon write addr=0x%08h data=0x%016h be=0x%02h waitreq=%b",
                 $time, avm_address, avm_writedata, avm_byteenable, avm_waitrequest);
end
// synthesis translate_on

//=======================================================
//  DEBUG word exposed via adder_sum_export[63:32]
//  Read at 0xC0000014 with:  ./devmem2 0xC0000014 w
//
//  Bit layout:
//    [31:24] = 0xDB  (magic marker — if you see this, the bridge works)
//    [23]    = heartbeat (toggles every 1 s — FPGA clock alive)
//    [22]    = hps_fpga_reset_n (1 = HPS out of reset)
//    [21]    = pio_dirty (1 = HPS just wrote a new value)
//    [20]    = ddr3_written (1 = DDR3 has been written at least once)
//    [19:18] = seq state (0=idle, 1=writing_A, 2=writing_B)
//    [17: 0] = 0 (reserved)
//=======================================================
wire [31:0] debug_word = {
    8'hDB,               // [31:24] magic marker
    heartbeat,           // [23]
    hps_fpga_reset_n,    // [22]
    pio_dirty,           // [21]
    ddr3_written,        // [20]
    seq,                 // [19:18]
    18'd0                // [17:0]
};

assign adder_sum_export = {debug_word, sum_a};

//=======================================================
//  LED assignment
//  [7]   heartbeat  — blinks ~1 Hz regardless of HPS
//  [6]   pio_dirty  — HPS wrote new data
//  [5]   seq active — DDR3 write in progress
//  [4]   hps reset  — HPS is running (active-HIGH)
//  [3:0] DEADBEEF latch — shows adder_b[3:0] after trigger
//=======================================================
assign LED = {
    heartbeat,           // [7]
    pio_dirty,           // [6]
    (seq != 2'd0),       // [5]
    hps_fpga_reset_n,    // [4]
    led_latch            // [3:0]
};

//=======================================================
//  Qsys SoC (HPS + PIOs + DDR3)
//=======================================================
soc_system u0(
               .pio128_out_new_signal   (pio128_out_export),
               .adder_a_export          (adder_a_export),
               .adder_b_export          (adder_b_export),
               .adder_sum_export        (adder_sum_export),
               .fpga_mem_address        (avm_address),
               .fpga_mem_read           (avm_read),
               .fpga_mem_readdata       (avm_readdata),
               .fpga_mem_readdatavalid  (avm_readdatavalid),
               .fpga_mem_write          (avm_write),
               .fpga_mem_writedata      (avm_writedata),
               .fpga_mem_byteenable     (avm_byteenable),
               .fpga_mem_waitrequest    (avm_waitrequest),
               .fpga_mem_burstcount     (1'b1),
               .fpga_mem_debugaccess    (1'b0),
               .clk_clk                 (FPGA_CLK1_50),
               .reset_reset_n           (hps_fpga_reset_n),
               .memory_mem_a            (HPS_DDR3_ADDR),
               .memory_mem_ba           (HPS_DDR3_BA),
               .memory_mem_ck           (HPS_DDR3_CK_P),
               .memory_mem_ck_n         (HPS_DDR3_CK_N),
               .memory_mem_cke          (HPS_DDR3_CKE),
               .memory_mem_cs_n         (HPS_DDR3_CS_N),
               .memory_mem_ras_n        (HPS_DDR3_RAS_N),
               .memory_mem_cas_n        (HPS_DDR3_CAS_N),
               .memory_mem_we_n         (HPS_DDR3_WE_N),
               .memory_mem_reset_n      (HPS_DDR3_RESET_N),
               .memory_mem_dq           (HPS_DDR3_DQ),
               .memory_mem_dqs          (HPS_DDR3_DQS_P),
               .memory_mem_dqs_n        (HPS_DDR3_DQS_N),
               .memory_mem_odt          (HPS_DDR3_ODT),
               .memory_mem_dm           (HPS_DDR3_DM),
               .memory_oct_rzqin        (HPS_DDR3_RZQ),
               .hps_0_h2f_reset_reset_n (hps_fpga_reset_n)
           );

endmodule
