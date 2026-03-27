`timescale 1ns/1ps
/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off BLKSEQ */

// ════════════════════════════════════════════════════════════════════════════
// L2_copy — Functional L2 cache built on the same skeleton as L1_Cache.sv
//
//   ▸ N-way set-associative (default 4-way, 16 sets)
//   ▸ Tree-PLRU replacement (same convention as llcd.sv)
//   ▸ Parameterised MSHRs for outstanding memory misses
//   ▸ Integrated backing-memory array (simulation; replace with M10K for FPGA)
//
//   Drop-in replacement for dummy_L2 — same port list:
//     L1 read-miss  : l2_req_valid / l2_req_addr  →  l2_resp_valid / l2_resp_data
//     L1 writeback  : wb_valid / wb_addr / wb_data   (absorbed, no response)
//
//   Hit latency  : 2 cycles (1 input-latch + 1 tag-check/respond)
//   Miss latency : 2 + MEM_LATENCY cycles (input-latch + alloc + memory fetch)
// ════════════════════════════════════════════════════════════════════════════

module L2_copy #(
    parameter int WAYS        = 4,       // associativity
    parameter int SETS        = 16,      // number of sets
    parameter int MSHR_COUNT  = 4,       // outstanding miss trackers
    parameter int MEM_LINES   = 4096,    // backing-memory depth (lines)
    parameter int MEM_LATENCY = 3,       // memory-fetch cycles (sim only)
    parameter bit USE_AVALON  = 1'b0     // 0 = sim backing_mem, 1 = external Avalon
)(
    input  logic         clk,
    input  logic         rst_n,

    // ── L1 read-miss interface ──────────────────────────────────────────
    input  logic         l2_req_valid,
    input  logic [29:0]  l2_req_addr,
    output logic         l2_resp_valid,
    output logic [511:0] l2_resp_data,

    // ── L1 dirty-writeback interface ────────────────────────────────────
    input  logic         wb_valid,
    input  logic [29:0]  wb_addr,
    input  logic [511:0] wb_data,

    // ── External memory interface (active only when USE_AVALON=1) ──────
    output logic         ext_mem_rd_req,    // pulse: request a 512b read
    output logic [23:0]  ext_mem_rd_addr,   // block address (paddr[29:6])
    input  logic         ext_mem_rd_valid,  // pulse: read data ready
    input  logic [511:0] ext_mem_rd_data,   // 512b read result
    output logic         ext_mem_wr_req,    // pulse: request a 512b write
    output logic [23:0]  ext_mem_wr_addr,   // block address (paddr[29:6])
    output logic [511:0] ext_mem_wr_data,   // 512b data to write
    input  logic         ext_mem_wr_done,   // pulse: write accepted
    input  logic         ext_mem_busy       // master is busy
);

localparam bit L2_VERBOSE = 1'b0;  // flip to 1 for debug prints

// ━━━ Derived geometry ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
localparam int WAY_W     = $clog2(WAYS);          // 2 for 4-way
localparam int INDEX_W   = $clog2(SETS);           // 4 for 16 sets
localparam int TAG_W     = 24 - INDEX_W;           // 20 (block_addr = paddr[29:6] = 24b)
localparam int MEM_IDX_W = $clog2(MEM_LINES);     // 12 for 4096
localparam int MSHR_ID_W = (MSHR_COUNT > 1) ? $clog2(MSHR_COUNT) : 1;
localparam logic [3:0] MEM_LAT_INIT = MEM_LATENCY - 1;

// ━━━ Cache arrays (same pattern as L1: data + tag + valid + dirty) ━━━━━━
logic [511:0]      data_array  [0:WAYS-1][0:SETS-1];
logic [TAG_W-1:0]  tag_array   [0:WAYS-1][0:SETS-1];
logic              valid_array [0:WAYS-1][0:SETS-1];
logic              dirty_array [0:WAYS-1][0:SETS-1];

// PLRU bits (3 per set for 4-way; matches llcd convention)
//   [0] = left-subtree,  [1] = right-subtree,  [2] = root
logic [WAYS-2:0] plru_bits [0:SETS-1];

// ━━━ MSHR — Miss Status Holding Registers ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// L2 works on full 512-bit lines → no byte-level merge queue (unlike L1).
typedef struct packed {
    logic valid;
    logic [23:0] block_addr;   // line address = paddr[29:6]
    logic mem_sent;            // memory request already issued
} mshr_t;

mshr_t mshr [0:MSHR_COUNT-1];

// ━━━ Backing memory (sim only — shrunk to 1 entry when USE_AVALON=1) ━━━━
localparam int ACTUAL_MEM_LINES = USE_AVALON ? 1 : MEM_LINES;
logic [511:0] backing_mem [0:ACTUAL_MEM_LINES-1];

// Memory-fetch pipeline (single outstanding request)
logic                  mem_busy;
logic [3:0]            mem_counter;
logic [23:0]           mem_pend_addr;
logic [MSHR_ID_W-1:0] mem_pend_id;

// ━━━ Avalon-mode eviction FIFO (2 pending dirty writebacks) ━━━━━━━━━━━━━
// Two-entry FIFO prevents data loss when a refill eviction and a writeback
// eviction both need to write to DDR3 in the same cycle.
logic [1:0]   evict_valid;     // valid bits for entries 0 and 1
logic [23:0]  evict_addr  [0:1];
logic [511:0] evict_data  [0:1];
logic         evict_pending;   // convenience: any entry valid
assign evict_pending = |evict_valid;
// Full: can't accept another eviction
logic         evict_full;
assign evict_full = &evict_valid;

// Avalon-mode: remember that ext_mem_rd_valid arrived during refill
logic         avm_rd_arrived;

// ━━━ Input-stage registers (capture one-cycle pulses from L1) ━━━━━━━━━━━
logic         s1_req_valid;
logic [29:0]  s1_req_addr;
logic         s1_wb_valid;
logic [29:0]  s1_wb_addr;
logic [511:0] s1_wb_data;

// ━━━ Deferred-hit buffer (refill-vs-hit collision, max 1 cycle) ━━━━━━━━━
logic         defer_valid;
logic [511:0] defer_data;

// ━━━ Deferred-writeback buffer (refill-vs-wb same-set collision) ━━━━━━━━
logic         defer_wb_valid;
logic [29:0]  defer_wb_addr;
logic [511:0] defer_wb_data;

// ━━━ Address decode from stage-1 latched values ━━━━━━━━━━━━━━━━━━━━━━━━━
logic [23:0]        s1_req_blk;
logic [INDEX_W-1:0] s1_req_idx;
logic [TAG_W-1:0]   s1_req_tag;

assign s1_req_blk = s1_req_addr[29:6];
assign s1_req_idx = s1_req_blk[INDEX_W-1:0];
assign s1_req_tag = s1_req_blk[23:INDEX_W];

logic [23:0]        s1_wb_blk;
logic [INDEX_W-1:0] s1_wb_idx;
logic [TAG_W-1:0]   s1_wb_tag;

assign s1_wb_blk = s1_wb_addr[29:6];
assign s1_wb_idx = s1_wb_blk[INDEX_W-1:0];
assign s1_wb_tag = s1_wb_blk[23:INDEX_W];

// ━━━ Combinational tag-hit detection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Read-request hit
logic [WAYS-1:0]  s1_req_way_hit;
logic             s1_req_hit;
logic [WAY_W-1:0] s1_req_hit_w;

always_comb begin
    for (int i = 0; i < WAYS; i++)
        s1_req_way_hit[i] = valid_array[i][s1_req_idx] &&
                             (tag_array[i][s1_req_idx] == s1_req_tag);
    s1_req_hit = |s1_req_way_hit;
    s1_req_hit_w = '0;
    for (int i = WAYS-1; i >= 0; i--)
        if (s1_req_way_hit[i]) s1_req_hit_w = i[WAY_W-1:0];
end

// Writeback hit
logic [WAYS-1:0]  s1_wb_way_hit;
logic             s1_wb_hit;
logic [WAY_W-1:0] s1_wb_hit_w;

always_comb begin
    for (int i = 0; i < WAYS; i++)
        s1_wb_way_hit[i] = valid_array[i][s1_wb_idx] &&
                            (tag_array[i][s1_wb_idx] == s1_wb_tag);
    s1_wb_hit = |s1_wb_way_hit;
    s1_wb_hit_w = '0;
    for (int i = WAYS-1; i >= 0; i--)
        if (s1_wb_way_hit[i]) s1_wb_hit_w = i[WAY_W-1:0];
end

// ━━━ PLRU functions (same convention as llcd.sv) ━━━━━━━━━━━━━━━━━━━━━━━━
//   plru[2]=root  plru[0]=left-subtree  plru[1]=right-subtree
function automatic logic [WAY_W-1:0] plru_victim(input logic [WAYS-2:0] bits);
    if (bits[2])   // evict from right subtree
        return bits[1] ? WAY_W'(3) : WAY_W'(2);
    else           // evict from left subtree
        return bits[0] ? WAY_W'(1) : WAY_W'(0);
endfunction

function automatic logic [WAYS-2:0] plru_after_access(
    input logic [WAYS-2:0] bits,
    input logic [WAY_W-1:0] way
);
    logic [WAYS-2:0] nb;
    nb = bits;
    if (way < 2) begin
        nb[0] = (way == WAY_W'(0)) ? 1'b1 : 1'b0;
    end else begin
        nb[1] = (way == WAY_W'(2)) ? 1'b1 : 1'b0;
    end
    nb[2] = (way < 2) ? 1'b1 : 1'b0;
    return nb;
endfunction

// Pick install way: first invalid way in the set, else PLRU victim
function automatic logic [WAY_W-1:0] find_install_way(
    input logic [INDEX_W-1:0] sidx
);
    logic found;
    found = 1'b0;
    for (int i = 0; i < WAYS; i++) begin
        if (!valid_array[i][sidx] && !found) begin
            find_install_way = i[WAY_W-1:0];
            found = 1'b1;
        end
    end
    if (!found)
        find_install_way = plru_victim(plru_bits[sidx]);
endfunction

// ━━━ Main sequential logic ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        l2_resp_valid  <= 1'b0;
        l2_resp_data   <= '0;
        s1_req_valid   <= 1'b0;
        s1_req_addr    <= '0;
        s1_wb_valid    <= 1'b0;
        s1_wb_addr     <= '0;
        s1_wb_data     <= '0;
        defer_valid    <= 1'b0;
        defer_data     <= '0;
        defer_wb_valid <= 1'b0;
        defer_wb_addr  <= '0;
        defer_wb_data  <= '0;
        mem_busy       <= 1'b0;
        mem_counter    <= '0;
        mem_pend_addr  <= '0;
        mem_pend_id    <= '0;
        evict_valid    <= 2'b00;
        evict_addr[0]  <= '0;
        evict_addr[1]  <= '0;
        evict_data[0]  <= '0;
        evict_data[1]  <= '0;
        avm_rd_arrived <= 1'b0;
        ext_mem_rd_req  <= 1'b0;
        ext_mem_rd_addr <= '0;
        ext_mem_wr_req  <= 1'b0;
        ext_mem_wr_addr <= '0;
        ext_mem_wr_data <= '0;

        for (int i = 0; i < MSHR_COUNT; i++) begin
            mshr[i].valid      <= 1'b0;
            mshr[i].block_addr <= '0;
            mshr[i].mem_sent   <= 1'b0;
        end
        for (int w = 0; w < WAYS; w++)
            for (int s = 0; s < SETS; s++) begin
                valid_array[w][s] <= 1'b0;
                dirty_array[w][s] <= 1'b0;
                tag_array[w][s]   <= '0;
                data_array[w][s]  <= '0;
            end
        for (int s = 0; s < SETS; s++)
            plru_bits[s] <= '0;

    end else begin : process
        // Working flags shared across sections
        logic refill_active;
        logic [INDEX_W-1:0] refill_set;
        refill_active = 1'b0;
        refill_set    = '0;

        // ── Stage 0: Capture inputs (one-cycle pulses from L1) ──────────
        s1_req_valid <= l2_req_valid;
        s1_req_addr  <= l2_req_addr;
        s1_wb_valid  <= wb_valid;
        s1_wb_addr   <= wb_addr;
        s1_wb_data   <= wb_data;

        // ── Default ─────────────────────────────────────────────────────
        l2_resp_valid  <= 1'b0;
        ext_mem_rd_req <= 1'b0;   // one-cycle pulses
        ext_mem_wr_req <= 1'b0;

        // ════════════════════════════════════════════════════════════════
        //  A: Deferred hit (from previous-cycle refill/hit collision)
        // ════════════════════════════════════════════════════════════════
        if (defer_valid) begin
            l2_resp_valid <= 1'b1;
            l2_resp_data  <= defer_data;
            defer_valid   <= 1'b0;
        end

        // ════════════════════════════════════════════════════════════════
        //  B: Memory refill completing
        //     SIM mode  : triggered by mem_counter reaching 0
        //     Avalon mode: triggered by ext_mem_rd_valid pulse
        // ════════════════════════════════════════════════════════════════
        else if (USE_AVALON
                 ? (mem_busy && ext_mem_rd_valid)
                 : (mem_busy && mem_counter == 0)) begin
            logic [23:0]        fill_blk;
            logic [INDEX_W-1:0] fill_idx;
            logic [TAG_W-1:0]   fill_tag;
            logic [WAY_W-1:0]   fill_way;
            logic [511:0]       fill_data;

            fill_blk  = mshr[mem_pend_id].block_addr;
            fill_idx  = fill_blk[INDEX_W-1:0];
            fill_tag  = fill_blk[23:INDEX_W];
            fill_way  = find_install_way(fill_idx);

            // Data source: Avalon master vs sim backing_mem
            if (USE_AVALON)
                fill_data = ext_mem_rd_data;
            else
                fill_data = backing_mem[fill_blk[MEM_IDX_W-1:0]];

            refill_active = 1'b1;
            refill_set    = fill_idx;

            // Evict dirty victim
            if (valid_array[fill_way][fill_idx] &&
                dirty_array[fill_way][fill_idx]) begin
                logic [23:0] evict_blk_local;
                evict_blk_local = {tag_array[fill_way][fill_idx], fill_idx};
                if (USE_AVALON) begin
                    // Buffer the eviction — drain in section F
                    if (!evict_valid[0]) begin
                        evict_valid[0] <= 1'b1;
                        evict_addr[0]  <= evict_blk_local;
                        evict_data[0]  <= data_array[fill_way][fill_idx];
                    end else begin
                        evict_valid[1] <= 1'b1;
                        evict_addr[1]  <= evict_blk_local;
                        evict_data[1]  <= data_array[fill_way][fill_idx];
                    end
                end else begin
                    backing_mem[evict_blk_local[MEM_IDX_W-1:0]] <= data_array[fill_way][fill_idx];
                end
                `ifndef SYNTHESIS
                if (L2_VERBOSE) $display("L2: EVICT dirty blk=%06h way=%0d",
                    evict_blk_local, fill_way);
                `endif
            end

            // Install fetched line
            data_array[fill_way][fill_idx]  <= fill_data;
            tag_array[fill_way][fill_idx]   <= fill_tag;
            valid_array[fill_way][fill_idx] <= 1'b1;
            dirty_array[fill_way][fill_idx] <= 1'b0;
            plru_bits[fill_idx] <= plru_after_access(plru_bits[fill_idx], fill_way);

            // Respond to L1
            l2_resp_valid <= 1'b1;
            l2_resp_data  <= fill_data;

            // Free MSHR & release memory pipeline
            mshr[mem_pend_id].valid <= 1'b0;
            mem_busy <= 1'b0;

            `ifndef SYNTHESIS
            if (L2_VERBOSE) $display("L2: REFILL blk=%06h way=%0d set=%0d",
                fill_blk, fill_way, fill_idx);
            `endif

            // Collision: read request also pending in stage-1
            if (s1_req_valid && s1_req_hit) begin
                defer_valid <= 1'b1;
                defer_data  <= data_array[s1_req_hit_w][s1_req_idx];
            end else if (s1_req_valid && !s1_req_hit) begin
                logic mshr_dup, mshr_done;
                mshr_dup  = 1'b0;
                mshr_done = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++)
                    if (mshr[i].valid && mshr[i].block_addr == s1_req_blk)
                        mshr_dup = 1'b1;
                if (!mshr_dup) begin
                    for (int i = 0; i < MSHR_COUNT; i++) begin
                        if (!mshr[i].valid && !mshr_done) begin
                            mshr[i].valid      <= 1'b1;
                            mshr[i].block_addr <= s1_req_blk;
                            mshr[i].mem_sent   <= 1'b0;
                            mshr_done = 1'b1;
                        end
                    end
                end
            end
        end

        // ════════════════════════════════════════════════════════════════
        //  C: Process latched read request (no refill this cycle)
        // ════════════════════════════════════════════════════════════════
        else if (s1_req_valid) begin
            if (s1_req_hit) begin
                l2_resp_valid <= 1'b1;
                l2_resp_data  <= data_array[s1_req_hit_w][s1_req_idx];
                plru_bits[s1_req_idx] <= plru_after_access(
                    plru_bits[s1_req_idx], s1_req_hit_w);
                `ifndef SYNTHESIS
                if (L2_VERBOSE) $display("L2: READ HIT  addr=%08h way=%0d set=%0d",
                    s1_req_addr, s1_req_hit_w, s1_req_idx);
                `endif
            end else begin
                // Miss — allocate MSHR (same pattern as L1 with dedup)
                logic mshr_dup, mshr_done;
                mshr_dup  = 1'b0;
                mshr_done = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++)
                    if (mshr[i].valid && mshr[i].block_addr == s1_req_blk)
                        mshr_dup = 1'b1;
                if (!mshr_dup) begin
                    for (int i = 0; i < MSHR_COUNT; i++) begin
                        if (!mshr[i].valid && !mshr_done) begin
                            mshr[i].valid      <= 1'b1;
                            mshr[i].block_addr <= s1_req_blk;
                            mshr[i].mem_sent   <= 1'b0;
                            mshr_done = 1'b1;
                        end
                    end
                end
                `ifndef SYNTHESIS
                if (L2_VERBOSE) $display("L2: READ MISS addr=%08h dup=%0b alloc=%0b",
                    s1_req_addr, mshr_dup, mshr_done);
                `endif
            end
        end

        // ════════════════════════════════════════════════════════════════
        //  D: Memory latency countdown (sim mode only)
        // ════════════════════════════════════════════════════════════════
        if (!USE_AVALON) begin
            if (mem_busy && mem_counter > 0)
                mem_counter <= mem_counter - 1;
        end

        // ════════════════════════════════════════════════════════════════
        //  E: Process latched writeback (runs in parallel with read path)
        //     Defers if refill just targeted the same set (avoids way
        //     collision from both trying to install into the same slot).
        // ════════════════════════════════════════════════════════════════
        if (s1_wb_valid) begin
            if (refill_active && refill_set == s1_wb_idx) begin
                // Same-set collision with refill → buffer for next cycle
                defer_wb_valid <= 1'b1;
                defer_wb_addr  <= s1_wb_addr;
                defer_wb_data  <= s1_wb_data;
            end else begin
                if (s1_wb_hit) begin
                    data_array[s1_wb_hit_w][s1_wb_idx] <= s1_wb_data;
                    dirty_array[s1_wb_hit_w][s1_wb_idx] <= 1'b1;
                    plru_bits[s1_wb_idx] <= plru_after_access(
                        plru_bits[s1_wb_idx], s1_wb_hit_w);
                end else begin
                    logic [WAY_W-1:0] wb_way;
                    wb_way = find_install_way(s1_wb_idx);
                    if (valid_array[wb_way][s1_wb_idx] &&
                        dirty_array[wb_way][s1_wb_idx]) begin
                        logic [23:0] evblk;
                        evblk = {tag_array[wb_way][s1_wb_idx], s1_wb_idx};
                        if (USE_AVALON) begin
                            if (!evict_valid[0]) begin
                                evict_valid[0] <= 1'b1;
                                evict_addr[0]  <= evblk;
                                evict_data[0]  <= data_array[wb_way][s1_wb_idx];
                            end else begin
                                evict_valid[1] <= 1'b1;
                                evict_addr[1]  <= evblk;
                                evict_data[1]  <= data_array[wb_way][s1_wb_idx];
                            end
                        end else begin
                            backing_mem[evblk[MEM_IDX_W-1:0]] <= data_array[wb_way][s1_wb_idx];
                        end
                    end
                    data_array[wb_way][s1_wb_idx]  <= s1_wb_data;
                    tag_array[wb_way][s1_wb_idx]   <= s1_wb_tag;
                    valid_array[wb_way][s1_wb_idx] <= 1'b1;
                    dirty_array[wb_way][s1_wb_idx] <= 1'b1;
                    plru_bits[s1_wb_idx] <= plru_after_access(
                        plru_bits[s1_wb_idx], wb_way);
                end
                `ifndef SYNTHESIS
                if (L2_VERBOSE) $display("L2: WB %s addr=%08h set=%0d",
                    s1_wb_hit ? "HIT " : "MISS", s1_wb_addr, s1_wb_idx);
                `endif
            end
        end

        // Process deferred writeback (from previous-cycle same-set collision)
        if (defer_wb_valid && !s1_wb_valid) begin
            logic [23:0]        dwb_blk;
            logic [INDEX_W-1:0] dwb_idx;
            logic [TAG_W-1:0]   dwb_tag;
            logic [WAYS-1:0]    dwb_way_hit;
            logic               dwb_hit;
            logic [WAY_W-1:0]   dwb_hit_w;

            dwb_blk = defer_wb_addr[29:6];
            dwb_idx = dwb_blk[INDEX_W-1:0];
            dwb_tag = dwb_blk[23:INDEX_W];

            for (int i = 0; i < WAYS; i++)
                dwb_way_hit[i] = valid_array[i][dwb_idx] &&
                                  (tag_array[i][dwb_idx] == dwb_tag);
            dwb_hit = |dwb_way_hit;
            dwb_hit_w = '0;
            for (int i = WAYS-1; i >= 0; i--)
                if (dwb_way_hit[i]) dwb_hit_w = i[WAY_W-1:0];

            if (dwb_hit) begin
                data_array[dwb_hit_w][dwb_idx] <= defer_wb_data;
                dirty_array[dwb_hit_w][dwb_idx] <= 1'b1;
                plru_bits[dwb_idx] <= plru_after_access(
                    plru_bits[dwb_idx], dwb_hit_w);
            end else begin
                logic [WAY_W-1:0] dw;
                dw = find_install_way(dwb_idx);
                if (valid_array[dw][dwb_idx] &&
                    dirty_array[dw][dwb_idx]) begin
                    logic [23:0] evblk;
                    evblk = {tag_array[dw][dwb_idx], dwb_idx};
                    if (USE_AVALON) begin
                        if (!evict_valid[0]) begin
                            evict_valid[0] <= 1'b1;
                            evict_addr[0]  <= evblk;
                            evict_data[0]  <= data_array[dw][dwb_idx];
                        end else begin
                            evict_valid[1] <= 1'b1;
                            evict_addr[1]  <= evblk;
                            evict_data[1]  <= data_array[dw][dwb_idx];
                        end
                    end else begin
                        backing_mem[evblk[MEM_IDX_W-1:0]] <= data_array[dw][dwb_idx];
                    end
                end
                data_array[dw][dwb_idx]  <= defer_wb_data;
                tag_array[dw][dwb_idx]   <= dwb_tag;
                valid_array[dw][dwb_idx] <= 1'b1;
                dirty_array[dw][dwb_idx] <= 1'b1;
                plru_bits[dwb_idx] <= plru_after_access(
                    plru_bits[dwb_idx], dw);
            end
            defer_wb_valid <= 1'b0;
        end

        // ════════════════════════════════════════════════════════════════
        //  F: Issue one MSHR → memory request (fixed priority, lowest ID)
        //     Avalon mode: also drain the eviction buffer when master idle
        // ════════════════════════════════════════════════════════════════
        if (USE_AVALON) begin
            // --- Avalon mode: drain eviction FIFO first, then issue reads ---
            if (evict_valid[0] && !ext_mem_busy) begin
                ext_mem_wr_req  <= 1'b1;
                ext_mem_wr_addr <= evict_addr[0];
                ext_mem_wr_data <= evict_data[0];
                // Shift entry 1 → entry 0
                evict_valid[0]  <= evict_valid[1];
                evict_addr[0]   <= evict_addr[1];
                evict_data[0]   <= evict_data[1];
                evict_valid[1]  <= 1'b0;
            end else if (!mem_busy && !ext_mem_busy && !evict_pending) begin
                logic issued;
                issued = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++) begin
                    if (mshr[i].valid && !mshr[i].mem_sent && !issued) begin
                        mem_busy        <= 1'b1;
                        mem_pend_addr   <= mshr[i].block_addr;
                        mem_pend_id     <= i[MSHR_ID_W-1:0];
                        mshr[i].mem_sent <= 1'b1;
                        ext_mem_rd_req  <= 1'b1;
                        ext_mem_rd_addr <= mshr[i].block_addr;
                        issued = 1'b1;
                        `ifndef SYNTHESIS
                        if (L2_VERBOSE) $display("L2: AVM RD REQ mshr[%0d] blk=%06h",
                            i, mshr[i].block_addr);
                        `endif
                    end
                end
            end
        end else begin
            // --- Sim mode: start counter-based memory pipeline ---
            if (!mem_busy) begin
                logic issued;
                issued = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++) begin
                    if (mshr[i].valid && !mshr[i].mem_sent && !issued) begin
                        mem_busy      <= 1'b1;
                        mem_counter   <= MEM_LAT_INIT;
                        mem_pend_addr <= mshr[i].block_addr;
                        mem_pend_id   <= i[MSHR_ID_W-1:0];
                        mshr[i].mem_sent <= 1'b1;
                        issued = 1'b1;
                        `ifndef SYNTHESIS
                        if (L2_VERBOSE) $display("L2: MEM REQ mshr[%0d] blk=%06h",
                            i, mshr[i].block_addr);
                        `endif
                    end
                end
            end
        end

    end // process
end // always_ff

// ━━━ Backing memory initialisation (sim mode only) ━━━━━━━━━━━━━━━━━━━━━━
`ifndef SYNTHESIS
initial begin
    for (int i = 0; i < ACTUAL_MEM_LINES; i++)
        backing_mem[i] = '0;
end
`endif

endmodule
