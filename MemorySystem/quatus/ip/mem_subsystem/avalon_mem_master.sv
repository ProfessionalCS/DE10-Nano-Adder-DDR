`timescale 1ns/1ps
/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off BLKSEQ */

// ════════════════════════════════════════════════════════════════════════════
// avalon_mem_master — Avalon-MM master that bridges L2 cache miss/eviction
//                     traffic to HPS DDR3 via the fpga_mem_bridge conduit.
//
//   The fpga_mem slave is 64-bit wide (8 bytes).  Our cache lines are
//   512-bit (64 bytes).  We issue 8 individual 64-bit reads or writes
//   per cache line (no bursts).
//
//   L2 interface (simple req/resp):
//     Read  : mem_rd_req + mem_rd_addr  →  mem_rd_valid + mem_rd_data (512b)
//     Write : mem_wr_req + mem_wr_addr + mem_wr_data (512b)  →  mem_wr_done
//
//   Avalon-MM master (no-burst, 64-bit data):
//     avm_address, avm_read, avm_readdata, avm_readdatavalid,
//     avm_write, avm_writedata, avm_byteenable, avm_waitrequest
//
//   Beat layout for 64-byte cache line (8 × 8 bytes):
//     beat 0:  line[ 63:  0]  addr + 0
//     beat 1:  line[127: 64]  addr + 8
//     beat 2:  line[191:128]  addr + 16
//     beat 3:  line[255:192]  addr + 24
//     beat 4:  line[319:256]  addr + 32
//     beat 5:  line[383:320]  addr + 40
//     beat 6:  line[447:384]  addr + 48
//     beat 7:  line[511:448]  addr + 56
// ════════════════════════════════════════════════════════════════════════════

module avalon_mem_master (
    input  logic         clk,
    input  logic         rst_n,

    // ── L2 read-miss interface (L2 → this module) ───────────────────────
    input  logic         mem_rd_req,       // pulse: L2 wants to read a line
    input  logic [23:0]  mem_rd_addr,      // block address (paddr[29:6])
    output logic         mem_rd_valid,     // pulse: 512-bit line ready
    output logic [511:0] mem_rd_data,      // the fetched cache line

    // ── L2 dirty-eviction interface (L2 → this module) ──────────────────
    input  logic         mem_wr_req,       // pulse: L2 wants to write back a line
    input  logic [23:0]  mem_wr_addr,      // block address (paddr[29:6])
    input  logic [511:0] mem_wr_data,      // 512-bit dirty line to write
    output logic         mem_wr_done,      // pulse: write completed

    // ── Busy flag (L2 should not issue new req while busy) ──────────────
    output logic         mem_busy,

    // ── Avalon-MM master (64-bit, wired to fpga_mem on soc_system) ──────
    output logic [31:0]  avm_address,
    output logic         avm_read,
    input  logic [63:0]  avm_readdata,
    input  logic         avm_readdatavalid,
    output logic         avm_write,
    output logic [63:0]  avm_writedata,
    output logic [7:0]   avm_byteenable,
    input  logic         avm_waitrequest
);

// ── FSM states ──────────────────────────────────────────────────────────
typedef enum logic [2:0] {
    S_IDLE,
    S_RD_ISSUE,     // assert avm_read, wait for !waitrequest
    S_RD_WAIT,      // wait for readdatavalid
    S_RD_DONE,      // deliver 512-bit result to L2
    S_WR_ISSUE,     // assert avm_write, wait for !waitrequest
    S_WR_DONE       // signal completion to L2
} state_t;

state_t state;

// ── Beat counter (0..7 for 8 × 64-bit = 512 bits) ──────────────────────
logic [2:0] beat_cnt;

// ── Latched request info ────────────────────────────────────────────────
logic [23:0]  req_block_addr;   // block address for current operation
logic [511:0] req_wr_data;      // latched write data
logic [511:0] rd_line;          // assembled read data

// ── Address computation ─────────────────────────────────────────────────
// block_addr = paddr[29:6] (24 bits).  Byte address = block_addr << 6.
// beat address = byte_addr + (beat_cnt × 8).
wire [31:0] line_byte_addr = {2'b0, req_block_addr, 6'b0};
wire [31:0] beat_addr      = line_byte_addr + {26'b0, beat_cnt, 3'b0};

// ── Extract 64-bit word from write data for current beat ────────────────
wire [63:0] wr_word = req_wr_data[beat_cnt*64 +: 64];

// ── Busy output ─────────────────────────────────────────────────────────
assign mem_busy = (state != S_IDLE);

// ── Main FSM ────────────────────────────────────────────────────────────
// Write-settle counter: after all 8 write-beats are accepted by the bridge,
// wait a few cycles before returning to IDLE so the downstream AXI fabric
// has time to commit the writes to SDRAM.  Without this, a following read
// to the same address can return stale DDR3 data.
localparam [3:0] WR_SETTLE_CYCLES = 4'd8;
logic [3:0] wr_settle_cnt;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        beat_cnt       <= 3'd0;
        req_block_addr <= '0;
        req_wr_data    <= '0;
        rd_line        <= '0;
        mem_rd_valid   <= 1'b0;
        mem_rd_data    <= '0;
        mem_wr_done    <= 1'b0;
        avm_address    <= '0;
        avm_read       <= 1'b0;
        avm_write      <= 1'b0;
        avm_writedata  <= '0;
        avm_byteenable <= '0;
        wr_settle_cnt  <= '0;
    end else begin
        // One-cycle pulses — clear by default
        mem_rd_valid <= 1'b0;
        mem_wr_done  <= 1'b0;

        // Explicit defaults: deassert bus when not driving
        avm_read  <= 1'b0;
        avm_write <= 1'b0;

        case (state)
        // ─────────────────────────────────────────────────────────────
        S_IDLE: begin
            beat_cnt  <= 3'd0;
            if (mem_rd_req) begin
                req_block_addr <= mem_rd_addr;
                rd_line        <= '0;
                state          <= S_RD_ISSUE;
            end else if (mem_wr_req) begin
                req_block_addr <= mem_wr_addr;
                req_wr_data    <= mem_wr_data;
                state          <= S_WR_ISSUE;
            end
        end

        // ═══════════════════ READ PATH ═══════════════════════════════
        // Assert read for current beat, hold until accepted
        S_RD_ISSUE: begin
            avm_address    <= beat_addr;
            avm_read       <= 1'b1;
            avm_byteenable <= 8'hFF;
            // When slave accepts (waitrequest deasserted), stop driving read
            if (avm_read && !avm_waitrequest) begin
                avm_read <= 1'b0;
                state    <= S_RD_WAIT;
            end
        end

        // Wait for readdatavalid
        S_RD_WAIT: begin
            if (avm_readdatavalid) begin
                rd_line[beat_cnt*64 +: 64] <= avm_readdata;
                if (beat_cnt == 3'd7) begin
                    state <= S_RD_DONE;
                end else begin
                    beat_cnt <= beat_cnt + 3'd1;
                    state    <= S_RD_ISSUE;
                end
            end
        end

        // Deliver assembled 512-bit cache line to L2
        S_RD_DONE: begin
            mem_rd_valid <= 1'b1;
            mem_rd_data  <= rd_line;
            state        <= S_IDLE;
        end

        // ═══════════════════ WRITE PATH ══════════════════════════════
        // Assert write for current beat, hold until accepted
        S_WR_ISSUE: begin
            avm_address    <= beat_addr;
            avm_write      <= 1'b1;
            avm_writedata  <= wr_word;
            avm_byteenable <= 8'hFF;
            // When slave accepts (waitrequest deasserted), move to next beat
            if (avm_write && !avm_waitrequest) begin
                avm_write <= 1'b0;
                if (beat_cnt == 3'd7) begin
                    wr_settle_cnt <= WR_SETTLE_CYCLES;
                    state         <= S_WR_DONE;
                end else begin
                    beat_cnt <= beat_cnt + 3'd1;
                    // Stay in S_WR_ISSUE for next beat
                end
            end
        end

        // Signal write completion to L2 after settle period
        S_WR_DONE: begin
            if (wr_settle_cnt > 0) begin
                wr_settle_cnt <= wr_settle_cnt - 4'd1;
            end else begin
                mem_wr_done <= 1'b1;
                state       <= S_IDLE;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
