/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

module top_with_L1 #(
    parameter bit USE_REAL_L2 = 1'b0,
    parameter bit USE_AVALON  = 1'b0,   // 1 = L2 uses external Avalon memory
    parameter int L2_SETS     = 16      // L2 set count (shrink for FPGA)
) (
    input logic clk,
    input logic rst_n,
    input logic [120:0] trace_line,
    output logic obs_tlb_req,
    output logic obs_cache_req,
    output logic obs_cache_we,
    output logic [29:0] obs_cache_paddr,
    output logic [63:0] obs_cache_wdata,
    output logic obs_cache_ret_valid,
    output logic [63:0] obs_cache_ret_data,
    output logic obs_cache_ret_is_load,
    output logic obs_l2_req_valid,
    output logic [29:0] obs_l2_req_addr,
    output logic obs_wb_valid,
    output logic [29:0] obs_wb_addr,

    // ── External memory ports (active when USE_AVALON=1) ────────────────
    output logic         ext_mem_rd_req,
    output logic [23:0]  ext_mem_rd_addr,
    input  logic         ext_mem_rd_valid,
    input  logic [511:0] ext_mem_rd_data,
    output logic         ext_mem_wr_req,
    output logic [23:0]  ext_mem_wr_addr,
    output logic [511:0] ext_mem_wr_data,
    input  logic         ext_mem_wr_done,
    input  logic         ext_mem_busy
);
    // LSQ <-> TLB
    logic tlb_req;
    logic [47:0] tlb_vaddr;
    logic tlb_hit;
    logic [29:0] tlb_paddr;
    logic tlb_fill;
    logic [29:0] fill_tlb_paddr;
    logic [47:0] fill_tlb_vaddr;

    // LSQ <-> L1
    logic cache_ready;
    logic cache_ret_valid;
    logic [63:0] cache_ret_data;
    logic cache_req;
    logic cache_we;
    logic [29:0] cache_paddr;
    logic [63:0] cache_wdata;

    // L1 <-> L2
    logic l2_req_valid;
    logic [29:0] l2_req_addr;
    logic l2_resp_valid;
    logic [511:0] l2_resp_data;
    logic         wb_valid;
    logic [29:0]  wb_addr;
    logic [511:0] wb_data;

    // L1 load-response indicator
    logic         cache_ret_is_load;

    assign obs_tlb_req = tlb_req;
    assign obs_cache_req = cache_req;
    assign obs_cache_we = cache_we;
    assign obs_cache_paddr = cache_paddr;
    assign obs_cache_wdata = cache_wdata;
    assign obs_cache_ret_valid = cache_ret_valid;
    assign obs_cache_ret_data = cache_ret_data;
    assign obs_cache_ret_is_load = cache_ret_is_load;
    assign obs_l2_req_valid = l2_req_valid;
    assign obs_l2_req_addr = l2_req_addr;
    assign obs_wb_valid = wb_valid;
    assign obs_wb_addr = wb_addr;

    assign cache_ready = 1'b1;

    lsq #(.N(16)) dut_lsq (
        .clk(clk),
        .rst_n(rst_n),
        .trace_line(trace_line),
        .tlb_hit(tlb_hit),
        .tlb_paddr(tlb_paddr),
        .cache_ready(cache_ready),
        .cache_ret_valid(cache_ret_valid),
        .cache_ret_data(cache_ret_data),
        .tlb_req(tlb_req),
        .tlb_vaddr(tlb_vaddr),
        .tlb_fill(tlb_fill),
        .fill_tlb_paddr(fill_tlb_paddr),
        .fill_tlb_vaddr(fill_tlb_vaddr),
        .cache_req(cache_req),
        .cache_we(cache_we),
        .cache_paddr(cache_paddr),
        .cache_wdata(cache_wdata)
    );

    dtlb dut_tlb (
        .clk(clk),
        .rst_n(rst_n),
        .lookup_req_i(tlb_req),
        .lookup_vaddr_i(tlb_vaddr),
        .lookup_hit_o(tlb_hit),
        .lookup_paddr_o(tlb_paddr),
        .fill_req_i(tlb_fill),
        .fill_vaddr_i(fill_tlb_vaddr),
        .fill_paddr_i(fill_tlb_paddr)
    );

    L1 dut_l1 (
        .clk(clk),
        .rst_n(rst_n),
        .lookup_req_i(cache_req),
        .lookup_vaddr_i({18'b0, cache_paddr}),
        .lookup_paddr_i(cache_paddr),
        .lookup_hit_o(),
        .req_valid(cache_req),
        .req_addr(cache_paddr),
        .req_write(cache_we),
        .req_wdata(cache_wdata),
        .resp_valid(cache_ret_valid),
        .resp_rdata(cache_ret_data),
        .resp_is_load(cache_ret_is_load),
        .l2_req_valid(l2_req_valid),
        .l2_req_addr(l2_req_addr),
        .l2_resp_valid(l2_resp_valid),
        .l2_resp_data(l2_resp_data),
        .wb_valid(wb_valid),
        .wb_addr(wb_addr),
        .wb_data(wb_data)
    );

    generate
        if (USE_REAL_L2) begin : gen_real_l2
            L2_copy #(
                .USE_AVALON(USE_AVALON),
                .SETS(L2_SETS)
            ) dut_l2 (
                .clk(clk),
                .rst_n(rst_n),
                .l2_req_valid(l2_req_valid),
                .l2_req_addr(l2_req_addr),
                .l2_resp_valid(l2_resp_valid),
                .l2_resp_data(l2_resp_data),
                .wb_valid(wb_valid),
                .wb_addr(wb_addr),
                .wb_data(wb_data),
                // External memory (active when USE_AVALON=1)
                .ext_mem_rd_req(ext_mem_rd_req),
                .ext_mem_rd_addr(ext_mem_rd_addr),
                .ext_mem_rd_valid(ext_mem_rd_valid),
                .ext_mem_rd_data(ext_mem_rd_data),
                .ext_mem_wr_req(ext_mem_wr_req),
                .ext_mem_wr_addr(ext_mem_wr_addr),
                .ext_mem_wr_data(ext_mem_wr_data),
                .ext_mem_wr_done(ext_mem_wr_done),
                .ext_mem_busy(ext_mem_busy)
            );
        end else begin : gen_dummy_l2
            dummy_L2 dut_l2 (
                .clk(clk),
                .rst_n(rst_n),
                .l2_req_valid(l2_req_valid),
                .l2_req_addr(l2_req_addr),
                .l2_resp_valid(l2_resp_valid),
                .l2_resp_data(l2_resp_data),
                .wb_valid(wb_valid),
                .wb_addr(wb_addr),
                .wb_data(wb_data)
            );
            // Tie off external memory ports when not using real L2
            assign ext_mem_rd_req  = 1'b0;
            assign ext_mem_rd_addr = '0;
            assign ext_mem_wr_req  = 1'b0;
            assign ext_mem_wr_addr = '0;
            assign ext_mem_wr_data = '0;
        end
    endgenerate

endmodule
