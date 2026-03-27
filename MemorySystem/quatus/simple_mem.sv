// ============================================================
//  simple_mem.sv — Easy DDR3 read / write over Avalon-MM
// ============================================================
//
//  Usage:
//    1. Put your address on `addr` (must be 64-byte aligned).
//    2. For a STORE: put 512-bit data on `wdata`, set `store`=1.
//       For a LOAD:  set `store`=0.
//    3. Pulse `request` high for one clock cycle.
//    4. Wait for `done` to pulse — that means the operation finished.
//       On a load, `rdata` holds the 512-bit result when `done` fires.
//
//  Internals: the Avalon bus is 64-bit wide, so one 512-bit cache
//  line takes 8 individual 64-bit beats (no bursts).  This is slow
//  but dead-simple.
//
//  Beat map (which bits go to which address offset):
//    beat 0 → wdata[ 63:  0] → addr + 0
//    beat 1 → wdata[127: 64] → addr + 8
//    ...
//    beat 7 → wdata[511:448] → addr + 56
//
// ============================================================

module simple_mem (
    input  logic         clk,
    input  logic         rst_n,

    // ── simple request interface ────────────────────────
    input  logic         request,       // pulse to start
    input  logic         store,         // 1 = write,  0 = read
    input  logic [31:0]  addr,          // 64-byte-aligned DDR3 address
    input  logic [511:0] wdata,         // data to write  (ignored on read)
    output logic [511:0] rdata,         // data read back  (valid at done)
    output logic         done,          // one-cycle pulse when finished

    // ── Avalon-MM master (wire straight to fpga_mem) ────
    output logic [31:0]  avm_address,
    output logic         avm_read,
    output logic         avm_write,
    output logic [63:0]  avm_writedata,
    output logic [7:0]   avm_byteenable,
    input  logic [63:0]  avm_readdata,
    input  logic         avm_readdatavalid,
    input  logic         avm_waitrequest
);

    // FSM states
    typedef enum logic [2:0] {
        IDLE,
        WR_BEAT,        // present one 64-bit write, wait for accept
        RD_BEAT,        // present one 64-bit read,  wait for accept
        RD_WAIT,        // wait for readdatavalid
        DONE
    } state_t;

    state_t       state;
    logic [2:0]   beat;            // 0..7
    logic         is_store;        // latched direction
    logic [31:0]  base_addr;       // latched address
    logic [511:0] buf_data;        // write: latched wdata / read: assembled

    // ── address for current beat ───────────────────────
    wire [31:0] beat_addr = base_addr + {26'b0, beat, 3'b0};

    // ── pick the 64-bit slice for this beat ────────────
    wire [63:0] beat_word = buf_data[beat*64 +: 64];

    // ── Avalon outputs (directly from state) ───────────
    always_comb begin
        avm_address    = beat_addr;
        avm_write      = (state == WR_BEAT);
        avm_read       = (state == RD_BEAT);
        avm_writedata  = beat_word;
        avm_byteenable = (state == WR_BEAT || state == RD_BEAT) ? 8'hFF : 8'h00;
    end

    // ── main FSM ───────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            beat      <= 3'd0;
            is_store  <= 1'b0;
            base_addr <= 32'd0;
            buf_data  <= 512'd0;
            rdata     <= 512'd0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;                       // default: no done pulse

            case (state)
            // ────────────────────────────────────────────
            IDLE: begin
                if (request) begin
                    base_addr <= addr;
                    is_store  <= store;
                    buf_data  <= wdata;
                    beat      <= 3'd0;
                    state     <= store ? WR_BEAT : RD_BEAT;
                end
            end

            // ──────────── WRITE PATH ────────────────────
            WR_BEAT: begin
                if (!avm_waitrequest) begin     // beat accepted
                    if (beat == 3'd7) begin
                        state <= DONE;
                    end else begin
                        beat <= beat + 3'd1;
                    end
                end
            end

            // ──────────── READ PATH ─────────────────────
            RD_BEAT: begin
                if (!avm_waitrequest) begin     // read issued
                    state <= RD_WAIT;
                end
            end

            RD_WAIT: begin
                if (avm_readdatavalid) begin
                    buf_data[beat*64 +: 64] <= avm_readdata;
                    if (beat == 3'd7) begin
                        rdata <= buf_data;
                        rdata[beat*64 +: 64] <= avm_readdata;  // last beat
                        state <= DONE;
                    end else begin
                        beat  <= beat + 3'd1;
                        state <= RD_BEAT;
                    end
                end
            end

            // ──────────── FINISH ────────────────────────
            DONE: begin
                done  <= 1'b1;
                state <= IDLE;
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule
