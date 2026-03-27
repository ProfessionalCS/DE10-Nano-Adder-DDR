`timescale 1ns/1ps
// Page size : 4 KiB  (12-bit page offset)
// VPN       : 48 - 12 = 36 bits
// PPN       : 30 - 12 = 18 bits

/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
module dtlb (
    input  logic        clk,
    input  logic        rst_n,

    // Lookup port
    input  logic        lookup_req_i, //I want to look up something 
    input  logic [47:0] lookup_vaddr_i, //Vitural Address 

    //Output
    output logic        lookup_hit_o, //Theres a hit
    output logic [29:0] lookup_paddr_o, //Physical Address

    // Fill port (from OP_TLB_FILL trace entries)
    // lower 12 bits of fill_vaddr_i and fill_paddr_i are page offset, unused
    input  logic        fill_req_i, //Theres is something to write into tlb
    input  logic [47:0] fill_vaddr_i, //Vitural Address
    input  logic [29:0] fill_paddr_i //Physical Address
);
/* verilator lint_on UNUSEDSIGNAL */

    localparam int unsigned NUM_ENTRIES = 16;
    localparam int unsigned VPN_BITS    = 36;  // 48 - 12
    localparam int unsigned PPN_BITS    = 18;  // 30 - 12
    localparam int unsigned PLRU_BITS   = 15;  // NUM_ENTRIES - 1

    // TLB storage

    logic                 valid [NUM_ENTRIES];
    logic [VPN_BITS-1:0]  vpn   [NUM_ENTRIES];
    logic [PPN_BITS-1:0]  ppn   [NUM_ENTRIES];
    logic [PLRU_BITS-1:0] plru_tree;

    // Lookup hit detection (combinational)

    logic [VPN_BITS-1:0]    lookup_vpn;
    assign lookup_vpn = lookup_vaddr_i[47:12]; 

    logic [NUM_ENTRIES-1:0] hit_vec;
    logic [3:0]             hit_idx;
    logic                   any_hit;

    genvar g;
    generate
        for (g = 0; g < NUM_ENTRIES; g++) begin : gen_hit
            assign hit_vec[g] = valid[g] & (vpn[g] == lookup_vpn); // hit_vec will be 010000000000 mean it was a hit in the 2 index
        end
    endgenerate

    always_comb begin
        hit_idx = 4'b0;
        any_hit = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (hit_vec[i]) begin
                hit_idx = 4'(i); //Stores index of where it hit
                any_hit = 1'b1;
            end
        end
    end


    // Fill hit detection
    logic [VPN_BITS-1:0] fill_vpn; //Vitual page number
    logic [PPN_BITS-1:0] fill_ppn; //Physical page number
    assign fill_vpn = fill_vaddr_i[47:12]; //Removing the offset for the  vitual address
    assign fill_ppn = fill_paddr_i[29:12];

    logic [NUM_ENTRIES-1:0] fill_hit_vec;
    logic [3:0]             fill_hit_idx;
    logic                   fill_any_hit;

    generate
        for (g = 0; g < NUM_ENTRIES; g++) begin : gen_fill_hit
            assign fill_hit_vec[g] = valid[g] & (vpn[g] == fill_vpn);
        end
    endgenerate

    always_comb begin
        fill_hit_idx = 4'b0;
        fill_any_hit = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (fill_hit_vec[i]) begin
                fill_hit_idx = 4'(i);
                fill_any_hit = 1'b1;
            end
        end
    end


    // First invalid slot (for cold fills)

    logic [3:0] first_invalid;
    logic       any_invalid;

    always_comb begin
        first_invalid = 4'b0;
        any_invalid   = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (!valid[i] && !any_invalid) begin
                first_invalid = 4'(i);
                any_invalid   = 1'b1;
            end
        end
    end

    // Pseudo-LRU victim selection (combinational tree walk)
    // Tree node layout (0-indexed):
    //   node 0        : root, splits {0..7} vs {8..15}
    //   nodes 1,2     : level 1
    //   nodes 3..6    : level 2
    //   nodes 7..14   : level 3, each governs a pair of leaves
    // Bit=0 -> go left to find victim; Bit=1 -> go right

    logic [3:0] ni0, ni1, ni2;
    logic [3:0] victim_idx;

    always_comb begin
        ni0        = plru_tree[0] ? 4'd2 : 4'd1;
        ni1        = plru_tree[ni0] ? (ni0 * 4'd2 + 4'd2) : (ni0 * 4'd2 + 4'd1);
        ni2        = plru_tree[ni1] ? (ni1 * 4'd2 + 4'd2) : (ni1 * 4'd2 + 4'd1);
        victim_idx = plru_tree[ni2] ? ((ni2 - 4'd7) * 4'd2 + 4'd1)
                                    : ((ni2 - 4'd7) * 4'd2);
    end

    // Pseudo-LRU update function
    // Flips nodes along root->leaf path to point AWAY from accessed entry.
    function automatic logic [PLRU_BITS-1:0] plru_update(
        input logic [PLRU_BITS-1:0] tree,
        input logic [3:0]           idx
    );
        logic [PLRU_BITS-1:0] t;
        logic [3:0] n3, n2, n1;

        t     = tree;
        n3    = 4'd7 + {1'b0, idx[3:1]};     // level-3 node = 7 + idx/2
        t[n3] = ~idx[0];                       // point away from leaf

        n2    = (n3 - 4'd1) >> 1;             // parent of n3
        t[n2] = (n3 == (n2 * 4'd2 + 4'd2)) ? 1'b0 : 1'b1;

        n1    = (n2 - 4'd1) >> 1;             // parent of n2
        t[n1] = (n2 == (n1 * 4'd2 + 4'd2)) ? 1'b0 : 1'b1;

        t[0]  = (n1 == 4'd2) ? 1'b0 : 1'b1;  // root

        return t;
    endfunction

    // Fill write index
    logic [3:0] fill_write_idx;
    always_comb begin
        if      (fill_any_hit) fill_write_idx = fill_hit_idx;
        else if (any_invalid)  fill_write_idx = first_invalid;
        else                   fill_write_idx = victim_idx;
    end


    // Sequential state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                valid[i] <= 1'b0;
                vpn[i]   <= '0;
                ppn[i]   <= '0;
            end
            plru_tree      <= '0;
            lookup_hit_o   <= 1'b0;
            lookup_paddr_o <= '0;
        end else begin

            // Fill: write new translation
            if (fill_req_i) begin
                valid[fill_write_idx] <= 1'b1;
                vpn  [fill_write_idx] <= fill_vpn;
                ppn  [fill_write_idx] <= fill_ppn;
                plru_tree <= plru_update(plru_tree, fill_write_idx);
            end

            // Lookup: register output, update PLRU
            lookup_hit_o <= lookup_req_i & any_hit;
            if (lookup_req_i && any_hit) begin
                lookup_paddr_o <= {ppn[hit_idx], lookup_vaddr_i[11:0]}; //Physical page number at the hit index + offset!
                if (fill_req_i)
                    plru_tree <= plru_update(plru_update(plru_tree, fill_write_idx), hit_idx);
                else
                    plru_tree <= plru_update(plru_tree, hit_idx);
            end else begin
                lookup_paddr_o <= '0;
            end

        end
    end
/* verilator lint_off EOFNEWLINE */
endmodule
