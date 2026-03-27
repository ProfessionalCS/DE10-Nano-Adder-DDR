/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

// ----------------------------------------------------------------------------------------------------
// 
// Format of LSQ entry
//
// ----------------------------------------------------------------------------------------------------

// Format of entry:
// Valid            | 1b          | Active instruction vs. inactive instruction
// Resolved         | 1b          | Address has been calculated by the processor
// Addr             | 48b         | Virtual address (EA)
// Value Valid      | 1b          | Data is valid (loads: cache returned; stores: data known)
// Data             | 64b         | Data
// Trace ID         | 4b          | Trace ID for matching with trace lines
// SQ Tail          | 3b          | Snapshot of store_tail at enqueue (forwarding lower bound)
// LQ Tail          | 3b          | Snapshot of load_tail at enqueue (forwarding lower bound)
// Phys Addr        | 30b         | Physical address from TLB translation (saved on TLB hit)
// Total: 1 + 1 + 48 + 1 + 64 + 4 + 3 + 3 + 30 = 155 bits per entry

// ----------------------------------------------------------------------------------------------------
// 
// Load-Store Queue (LSQ)
//
// ----------------------------------------------------------------------------------------------------

// Enum provided by the assignment
typedef enum logic[2:0] {
    OP_MEM_LOAD = 3'd0,    // Perform a memory load
    OP_MEM_STORE = 3'd1,   // Send a memory store
    OP_MEM_RESOLVE = 3'd2, // Resolve an unresolved address
    OP_TLB_FILL = 3'd4     // Fill a line of the TLB 
} op_e;

// Load store queue (LSQ) (aka the controller module)
module lsq # (
    parameter int N = 16,
    parameter int Q_SIZE = 8
) (
    input logic clk,
    input logic rst_n, // Assume active low reset

    // Signals predefined from the traces that get fed into the LSQ
    input logic [120:0] trace_line, // Break this trace line into different components

    // Signals from the TLB
    input logic tlb_hit,
    input logic [29:0] tlb_paddr,

    // Signals from $L1
    input logic cache_ready,
    input logic cache_ret_valid,
    input logic [63:0] cache_ret_data, // Read

    // Signals to the TLB
    output logic tlb_req,
    output logic [47:0] tlb_vaddr,  // Registered vaddr stable for the full cycle tlb_req is high
    // Forward fill
    output logic tlb_fill,
    output logic [29:0] fill_tlb_paddr, // Forward the physical addr
    output logic [47:0] fill_tlb_vaddr,  // Forward the virtual addr

    // Signals to $L1
    output logic cache_req,
    output logic cache_we,
    output logic [29:0] cache_paddr,
    output logic [63:0] cache_wdata
);
    op_e trace_op;
    logic [3:0] trace_id;
    logic [47:0] trace_vaddr;
    logic trace_vaddr_is_valid;     // Only relevant to mem operations
    logic trace_value_is_valid;     // Only relevant to store operations
    logic [63:0] trace_value;       // Only relevant to store operations

    assign trace_op = op_e'(trace_line[54:52]);
    assign trace_id = trace_line[51:48];
    assign trace_vaddr = trace_line[47:0];
    assign tlb_vaddr = trace_line[47:0];            // Latch vaddr so it stays stable while tlb_req is high (same cycle as the queues)
    assign trace_vaddr_is_valid = trace_line[55];
    assign trace_value_is_valid = trace_line[120];
    assign trace_value = trace_line[119:56];

    // TLB forward fill from processor -> bypass LSQ -> TLB
    // REGISTERED: only pulse tlb_fill for one cycle when trace_id changes
    // and the operation is OP_TLB_FILL.  This prevents spurious fills caused
    // by PIO transient states (reg_b changes while reg_a still holds a
    // previous TLB_FILL opcode).
    
    localparam int LOAD_QUEUE_SIZE = N>>1;  // 16 entries -> 8 loads and 8 stores
    localparam int STORE_QUEUE_SIZE = N>>1;
    localparam int ENTRY_SIZE = 155;
    localparam int EA_SIZE = 48;
    localparam int PA_SIZE = 30;
    localparam int DATA_SIZE = 64;
    localparam int TRACE_ID_SIZE = 4;

    // Starting indicies
    localparam int VALID_IDX = ENTRY_SIZE - 1;
    localparam int RESOLVED_IDX = VALID_IDX - 1;
    localparam int EA_IDX = RESOLVED_IDX - 1;
    localparam int VVALID_IDX = EA_IDX - EA_SIZE;
    localparam int DATA_IDX = VVALID_IDX - 1;
    localparam int TRACE_ID_IDX = DATA_IDX - DATA_SIZE;
    localparam int SQ_TAIL_IDX = TRACE_ID_IDX - TRACE_ID_SIZE;
    localparam int LQ_TAIL_IDX = SQ_TAIL_IDX - $clog2(STORE_QUEUE_SIZE);
    localparam int PA_IDX = LQ_TAIL_IDX - $clog2(LOAD_QUEUE_SIZE);

    logic tlb_pending;                                      // TLB response is expected next cycle
    logic tlb_pending_is_load;                              // 1 = LOAD queue, 0 = STORE queue
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] tlb_pending_idx;    // queue slot of the entry awaiting translation
    logic tlb_resp_valid;                                   // 1 cycle after tlb_req: DTLB registered output is now valid

    logic cache_pending;                                    // Wait on the cache
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] cache_pending_idx;  // LQ entry that is waiting for cache data (since stores are auto write back to the cache)

    // Load and store queue stuff
    logic [LOAD_QUEUE_SIZE-1:0][ENTRY_SIZE-1:0] load_entries;
    logic [STORE_QUEUE_SIZE-1:0][ENTRY_SIZE-1:0] store_entries;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_head, load_tail;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_head, store_tail;

    logic load_is_full, load_is_empty;
    logic store_is_full, store_is_empty;

    logic [3:0] trace_id_prev;

    logic [LOAD_QUEUE_SIZE-1:0] load_matches;
    logic [STORE_QUEUE_SIZE-1:0] store_matches;

    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_update_idx;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_update_idx;

    logic [STORE_QUEUE_SIZE-1:0] stores_before_load_mask, stores_after_store_mask;
    logic [LOAD_QUEUE_SIZE-1:0]  loads_after_store_mask;

    // Final bit vectors combining matching EA and before/ after logic for forwarding and updates
    logic [STORE_QUEUE_SIZE-1:0] final_stores_before_load;
    logic [LOAD_QUEUE_SIZE-1:0]  final_loads_after_store;
    logic [STORE_QUEUE_SIZE-1:0] final_stores_after_store;
    
    // Match bit vector
    // When load or store resolves, we have to find all matching EA to do the following:
    // Store:
    // 1. Update any later loads that match the store (store broadcasts EA to later loads 
    // that might have completed before store resolved -> rexecute this load and everything after it)
    // 2. Update any later stores that match the store (store broadcasts EA to later stores
    // that would update the same EA, useful for saving in-order commits to the $L1)
    // Load:
    // 1. Broadcast EA to earlier stores (forwarding data from LSQ vs memory or cache as 
    // that would have stale data if not yet committed)

    _match #(.Q_SIZE(LOAD_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) load_match (
        .ea(trace_vaddr),
        .entries(load_entries),
        .matching_eas(load_matches)
    );

    _match #(.Q_SIZE(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) store_match (
        .ea(trace_vaddr),
        .entries(store_entries),
        .matching_eas(store_matches)
    );

    // Generate the LSQ operations
    // 1. Load instruction after exec stores (exec load, use information from prev stores rather than from the cache)
    _before_and_after #(.Q_SIZE(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) stores_before_load (
        .head(store_head),
        .tail(store_tail),
        .j(load_entries[load_update_idx][SQ_TAIL_IDX-:$clog2(STORE_QUEUE_SIZE)]), // Get the SQ tail index for the load being updated
        .entries(store_entries),
        .before_matches(stores_before_load_mask),
        .after_matches()  // Unused
    );

    // 2. Store instruction after exec loads (exec store, update later loads that might have gone ahead)
    _before_and_after #(.Q_SIZE(LOAD_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) loads_after_store (
        .head(load_head),
        .tail(load_tail),
        .j(store_entries[store_update_idx][LQ_TAIL_IDX-:$clog2(LOAD_QUEUE_SIZE)]), // Get the LQ tail index for the store being updated
        .entries(load_entries),
        .before_matches(), // Unused
        .after_matches(loads_after_store_mask)
    );

    // 3. Store instruction after exec stores (exec store, update later stores that might depend on this store)
    _before_and_after #(.Q_SIZE(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) stores_after_store (
        .head(store_head),
        .tail(store_tail),
        .j(store_update_idx), // Compare against the current store being executed (index)
        .entries(store_entries),
        .before_matches(), // Unused
        .after_matches(stores_after_store_mask)
    );
    
    // Flags for checking whether the queues is full or empty
    always_comb begin
        load_is_empty = (load_head == load_tail);
        store_is_empty = (store_head == store_tail);
        
        load_is_full = ($clog2(LOAD_QUEUE_SIZE)'(load_tail + 1) == load_head);
        store_is_full = ($clog2(STORE_QUEUE_SIZE)'(store_tail + 1) == store_head);
    end
    
    // Final bit vectors that combined the matching EA and before/ after logic
    assign final_stores_before_load = store_matches & stores_before_load_mask;  // Update load's value from previous store
    assign final_loads_after_store = load_matches  & loads_after_store_mask;    // Invalidate loads because they went ahead newly resolved stores
    assign final_stores_after_store = store_matches & stores_after_store_mask;  // Don't send store to the cache just yet (anything older than it should be bypassed)

    // Priority encoders for forwarding
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] fwd_store_to_load_idx;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] tmp_store_idx; // Tmp holder

    logic suppress_wb_stores_after_store;
    always_comb begin
        fwd_store_to_load_idx = '0;
        suppress_wb_stores_after_store = 0;

        // Load is resolving so it needs to pull from the earliest store from the store queue with matching EA
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            tmp_store_idx = ($clog2(STORE_QUEUE_SIZE))'(store_head + i); // Head contains the oldest store
            if (final_stores_before_load[tmp_store_idx]) begin
                fwd_store_to_load_idx = tmp_store_idx; // Get the youngest store (we want this data to forward to the load that is getting resolved)
            end
        end

        // Find the oldest store, mark it for updating the cache otherwise bypass writes to everything else
        // Aka store forwarding
        for (int i = 1; i < STORE_QUEUE_SIZE; i++) begin
            tmp_store_idx = $clog2(STORE_QUEUE_SIZE)'(store_head + i); // Start at the head + 1, find matching EA
            
            // Check if the younger entry is valid, resolved, and matches the retiring store's EA
            if (store_entries[tmp_store_idx][VALID_IDX] &&
                store_entries[tmp_store_idx][RESOLVED_IDX] &&
                (store_entries[tmp_store_idx][EA_IDX-:EA_SIZE] == store_entries[store_head][EA_IDX-:EA_SIZE])) begin
                suppress_wb_stores_after_store = 1;
                break;
            end
        end
    end

    // Find indices for resolving instructions out of order
    always_comb begin
        load_update_idx = '0; 
        store_update_idx = '0;

        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
            // If instruction is valid (active) and trace id is aligned with current instruction executing, then we have index for current execution
            if (load_entries[i][VALID_IDX] && load_entries[i][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id) begin
                load_update_idx = $clog2(LOAD_QUEUE_SIZE)'(i); // Convert idx to the correct dimension
            end
        end
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            if (store_entries[i][VALID_IDX] && store_entries[i][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id) begin
                store_update_idx = $clog2(STORE_QUEUE_SIZE)'(i);
            end
        end
    end
    
    // Figure out how to readdress the loads that were invalidate and need to be rerun
    logic rerun_invalidate_loads;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] rerun_load_idx;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] tmp_load_idx; // Tmp holder
    always_comb begin
        rerun_invalidate_loads = 0;
        rerun_load_idx = '0;

        // Always start from the oldest loads to the youngest
        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
            tmp_load_idx = ($clog2(LOAD_QUEUE_SIZE))'(load_head + i); // Head contains the oldest load
            
            if (load_entries[tmp_load_idx][VALID_IDX] &&
                load_entries[tmp_load_idx][RESOLVED_IDX] &&
                !load_entries[tmp_load_idx][VVALID_IDX]) begin

                // Make sure a TLB request isn't happening already
                if (!(tlb_pending && tlb_pending_is_load && tlb_pending_idx == tmp_load_idx) &&
                    !(cache_pending && cache_pending_idx == tmp_load_idx)) begin

                    rerun_invalidate_loads = 1;
                    rerun_load_idx = tmp_load_idx;
                    break;
                end
            end
        end
    end 

    // Synchronous
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache_req <= 0;
            cache_we <= 0;
            cache_paddr <= '0;
            cache_wdata <= '0;
            cache_pending <= 0;
            cache_pending_idx <= '0;

            tlb_req <= 0;
            tlb_pending <= 0;   
            tlb_pending_is_load <= 0;
            tlb_pending_idx <= '0;
            tlb_resp_valid <= 0;

            tlb_fill <= 1'b0;
            fill_tlb_paddr <= '0;
            fill_tlb_vaddr <= '0;

            trace_id_prev <= 4'hF;  // Start at 0xF so that the first TLB fill with id=0 is not dropped

            load_head <= '0;
            load_tail <= '0;
            store_head <= '0;
            store_tail <= '0;

            for (int i = 0; i < LOAD_QUEUE_SIZE; i++) load_entries[i] <= '0;
            for (int i = 0; i < STORE_QUEUE_SIZE; i++) store_entries[i] <= '0;

        end else begin
            cache_req <= 0;
            tlb_req <= 0;
            tlb_fill <= 1'b0;
            tlb_resp_valid <= tlb_req;  // DTLB output valid 1 cycle after request

            // 1. Handle loads after resolving store (handles the invalidation of all the loads)
            // A store has occurred, so invalidate all loads that are after this store
            for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
                if (final_loads_after_store[i]) begin
                    load_entries[i][VVALID_IDX] <= 0;
                end
            end

            // 2. Cache handler
            // $L1 has 2 cycle latency and $L2 has 5 cycle latency
            // Cache pending is only ever triggered by load requests (so we know it's a load and we just have to wait for valid data)
            // Stores will always write (handled by $L1)
            if (cache_pending && cache_ret_valid) begin
                load_entries[cache_pending_idx][VVALID_IDX] <= 1;
                load_entries[cache_pending_idx][DATA_IDX-:DATA_SIZE] <= cache_ret_data;
                cache_pending <= 0; 
            end
    
            // 3. TLB handler
            // Has 1 cycle latency
            // Cycle N: tlb_pending is waiting upon $L1 response and tlb_req is triggered
            // Cycle N+1: the TLB registered outputs are valid
            // On a hit: update the entry with the physical address
            // On a miss: invalidate the entry so it doesn't clog the queue
            //            (software-managed TLB: caller must fill TLB before access)
            if (tlb_pending && tlb_resp_valid && tlb_hit) begin
                tlb_req <= 0;
                tlb_pending <= 0;

                // Save the translated PA into the entry and mark it resolved.
                // The PA is needed at commit time: loads read the cache immediately
                // (fire-and-forget read), stores write the cache only at retirement.
                if (tlb_pending_is_load) begin
                    load_entries[tlb_pending_idx][RESOLVED_IDX] <= 1;
                    load_entries[tlb_pending_idx][PA_IDX-:PA_SIZE] <= tlb_paddr;

                    // Loads: fire the cache read right now so data arrives ASAP.
                    if (cache_ready) begin
                        cache_req <= 1;
                        cache_we <= 0;          // read
                        cache_paddr <= tlb_paddr;
                        cache_wdata <= '0;
                        cache_pending_idx <= tlb_pending_idx;
                        cache_pending <= 1;
                    end else begin
                        // Cache busy: mark resolved but leave VVALID=0 so the
                        // rerun_invalidate_loads logic retries once cache frees.
                        load_entries[tlb_pending_idx][VVALID_IDX] <= 0;
                    end

                end else begin
                    store_entries[tlb_pending_idx][RESOLVED_IDX] <= 1;
                    store_entries[tlb_pending_idx][PA_IDX-:PA_SIZE] <= tlb_paddr;
                    // Stores: do NOT write the cache here.
                    // The write is deferred to retirement so we only commit the youngest store to each address (WAW suppression)
                    // Writeback if non speculative
                end
            end else if (tlb_pending && tlb_resp_valid && !tlb_hit) begin
                // TLB MISS: clear pending and invalidate the entry so it
                // doesn't permanently clog the queue.  Software must fill
                // the TLB and re-issue the operation.
                tlb_req <= 0;
                tlb_pending <= 0;
                if (tlb_pending_is_load) begin
                    load_entries[tlb_pending_idx][VALID_IDX] <= 0;
                end else begin
                    store_entries[tlb_pending_idx][VALID_IDX] <= 0;
                end
            end

            // 4. Check for new operations (register memory loads and stores)
            // Only act on a trace-id edge when the trace carries a legitimate
            // operation.  PIO transient states (clear_status writes reg_a=0)
            // produce vv=0 noise that must be ignored entirely — including the
            // trace_id_prev update, so the real operation's edge isn't consumed.
            if (trace_id != trace_id_prev &&
                (trace_op == OP_TLB_FILL || trace_vaddr_is_valid)) begin
                // Update the previous trace tracker
                trace_id_prev <= trace_id;

                // TLB fill: capture fill data on the trace_id edge (one-shot)
                if (trace_op == OP_TLB_FILL) begin
                    tlb_fill <= 1'b1;
                    fill_tlb_paddr <= trace_line[85:56];
                    fill_tlb_vaddr <= trace_line[47:0];
                end

                // Need to hear request and queue on first cycle
                // Gate LOAD/STORE on vaddr_is_valid to reject spurious ops
                // from PIO transient states (e.g. clear_status writes reg_a=0)
                case (trace_op)
                    OP_MEM_LOAD: begin
                        if (!load_is_full && trace_vaddr_is_valid) begin
                            load_entries[load_tail][VALID_IDX] <= 1;
                            load_entries[load_tail][RESOLVED_IDX] <= 0;
                            load_entries[load_tail][EA_IDX-:EA_SIZE] <= trace_vaddr;
                            load_entries[load_tail][VVALID_IDX] <= 0;                        
                            load_entries[load_tail][DATA_IDX-:DATA_SIZE] <= '0;
                            load_entries[load_tail][TRACE_ID_IDX-:TRACE_ID_SIZE] <= trace_id;
                            load_entries[load_tail][SQ_TAIL_IDX-:$clog2(LOAD_QUEUE_SIZE)] <= store_tail;
                            load_entries[load_tail][LQ_TAIL_IDX-:$clog2(LOAD_QUEUE_SIZE)] <= '0;
                            load_entries[load_tail][PA_IDX-:PA_SIZE] <= '0;
                            
                            load_tail <= $clog2(LOAD_QUEUE_SIZE)'(load_tail + 1); // Another way to do modulo wraparound

                            // TLB request
                            tlb_req <= 1;
                            tlb_pending <= 1;
                            tlb_pending_is_load <= 1;
                            tlb_pending_idx <= load_tail;   // Get the tail (recently added load)
                        end
                    end

                    OP_MEM_STORE: begin
                        if (!store_is_full && trace_vaddr_is_valid) begin
                            store_entries[store_tail][VALID_IDX] <= 1;
                            store_entries[store_tail][RESOLVED_IDX] <= 0;
                            store_entries[store_tail][EA_IDX-:EA_SIZE] <= trace_vaddr;
                            store_entries[store_tail][VVALID_IDX] <= trace_value_is_valid;                        
                            store_entries[store_tail][DATA_IDX-:DATA_SIZE] <= trace_value;
                            store_entries[store_tail][TRACE_ID_IDX-:TRACE_ID_SIZE] <= trace_id;
                            store_entries[store_tail][SQ_TAIL_IDX-:$clog2(STORE_QUEUE_SIZE)] <= '0; 
                            store_entries[store_tail][LQ_TAIL_IDX-:$clog2(STORE_QUEUE_SIZE)] <= load_tail;
                            store_entries[store_tail][PA_IDX-:PA_SIZE] <= '0;
                            
                            store_tail <= $clog2(STORE_QUEUE_SIZE)'(store_tail + 1); // Another way to do modulo wraparound

                            // TLB request
                            tlb_req <= 1;
                            tlb_pending <= 1;
                            tlb_pending_is_load <= 0;
                            tlb_pending_idx <= store_tail;   // Get the tail (recently added store)
                        end
                    end

                    OP_MEM_RESOLVE: begin   // Resolve unresolved address
                        // Determine which queue holds this trace's ID and update it
                        if (load_entries[load_update_idx][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id && load_entries[load_update_idx][VALID_IDX]) begin
                            load_entries[load_update_idx][RESOLVED_IDX] <= 1;
                            load_entries[load_update_idx][EA_IDX-:EA_SIZE] <= trace_vaddr;
                            
                            // Store occurs and now we can just forward the data to the loads
                            if (|final_stores_before_load) begin
                                load_entries[load_update_idx][VVALID_IDX] <= 1;
                                load_entries[load_update_idx][DATA_IDX-:DATA_SIZE] <= store_entries[fwd_store_to_load_idx][DATA_IDX-:DATA_SIZE];

                            end else begin
                                // Find ANY matching EA (if there are none, there is no forwarding)
                                // No forwarding so go to the TLB and the cache for data
                                tlb_req <= 1;
                                tlb_pending <= 1;
                                tlb_pending_is_load <= 1;
                                tlb_pending_idx <= load_update_idx;
                            end

                        end else if (store_entries[store_update_idx][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id && store_entries[store_update_idx][VALID_IDX]) begin
                            store_entries[store_update_idx][RESOLVED_IDX] <= 1;
                            store_entries[store_update_idx][EA_IDX-:EA_SIZE] <= trace_vaddr;

                            // Store resolved and now we can forward the data to another store?
                            if (|final_stores_after_store) begin
                                // If ANY bit in this mask is 1, a younger store to this address exists so do nothing and DON'T request to tlb or the cache
                                // This store will sit in the queue and retire silently

                            end else begin // I don't think this test case should trigger since MEM RESOLVE is meant to have EA resolved OOO?
                                tlb_req <= 1;
                                tlb_pending <= 1;
                                tlb_pending_is_load <= 0;
                                tlb_pending_idx <= store_update_idx;
                            end
                        end
                    end

                    default: begin
                    end
                endcase
            
            // Not new trace but we should go back and readdress invalidated loads
            end else if (rerun_invalidate_loads && !tlb_pending && !cache_pending) begin
                tlb_req <= 1;
                tlb_pending <= 1;
                tlb_pending_is_load <= 1;
                tlb_pending_idx <= rerun_load_idx;
            end

            // Retire the oldest load if it is fully resolved and its data is valid
            if (load_entries[load_head][VALID_IDX] && 
                load_entries[load_head][RESOLVED_IDX] && 
                load_entries[load_head][VVALID_IDX]) begin

                if (!load_is_empty) begin
                    load_entries[load_head][VALID_IDX] <= 0; // Invalidate entry
                    load_head <= $clog2(LOAD_QUEUE_SIZE)'(load_head + 1); // Move head pointer
                end
            end

            // Retire the oldest store when it is fully resolved and its data is valid
            // At this point the store is non-speculative: commit to cache then dequeue
            if (store_entries[store_head][VALID_IDX] &&
                store_entries[store_head][RESOLVED_IDX] &&
                store_entries[store_head][VVALID_IDX]) begin

                if (!store_is_empty) begin
                    if (!suppress_wb_stores_after_store) begin
                        // Commit the store data to the cache using the saved PA.
                        cache_req <= 1;
                        cache_we <= 1;
                        cache_paddr <= store_entries[store_head][PA_IDX-:PA_SIZE];
                        cache_wdata <= store_entries[store_head][DATA_IDX-:DATA_SIZE];
                    end

                    // Dequeue irregardless of the store writing to the cache
                    store_entries[store_head][VALID_IDX] <= 0;
                    store_head <= $clog2(STORE_QUEUE_SIZE)'(store_head + 1);
                end
            end
        end
    end

endmodule

// ----------------------------------------------------------------------------------------------------
// 
// Helpers
//
// ----------------------------------------------------------------------------------------------------

// Combinational logic helper for finding matching EA amongst all load and store queues
// Incorporates before and after logic (from the slides)
module _match #(
    parameter int Q_SIZE = 8,
    parameter int ENTRY_SIZE = 125,
    parameter int EA_SIZE = 48  // Num of bits in the EA
) (
    input logic [EA_SIZE-1:0] ea, // The EA to compare with

    input logic [Q_SIZE-1:0][ENTRY_SIZE-1:0] entries, // With only EA and valid+resolved bits exposed
    output logic [Q_SIZE-1:0] matching_eas
);
    localparam VALID_IDX = ENTRY_SIZE - 1;
    localparam RESOLVED_IDX = VALID_IDX - 1;
    localparam EA_IDX = RESOLVED_IDX - 1;

    // Find matching EA
    always_comb begin
        // Synthesizeable for loop (parallel comparators)
        for (int i = 0; i < Q_SIZE; i++) begin
            matching_eas[i] = (entries[i][EA_IDX-:EA_SIZE] == ea) &&
                        entries[i][VALID_IDX] &&     // Check if valid bit is set (non-retired instruction)
                        entries[i][RESOLVED_IDX];    // Check if resolved bit is set (EA has been resolved) 
        end
    end

endmodule

// Combinational logic helper for finding before and after matches
// before(j) returns a bit vector that contains a 1 for all valid queue entries that are before position j
// after(j) returns a bit vector that contains a 1 for all valid queue entries that are after position j
module _before_and_after #(
    parameter int Q_SIZE = 8,
    parameter int ENTRY_SIZE = 125,
    parameter int EA_SIZE = 48
) (
    input logic [$clog2(Q_SIZE)-1:0] head,
    input logic [$clog2(Q_SIZE)-1:0] tail,
    input logic [$clog2(Q_SIZE)-1:0] j,

    input logic [Q_SIZE-1:0][ENTRY_SIZE-1:0] entries, // With only EA and valid+resolved bits exposed

    output logic [Q_SIZE-1:0] before_matches,
    output logic [Q_SIZE-1:0] after_matches
);
    localparam VALID_IDX = ENTRY_SIZE - 1;
    localparam RESOLVED_IDX = VALID_IDX - 1;
    localparam EA_IDX = RESOLVED_IDX - 1;

    // Get the valid bits (active entries, active but may not be resolved instructions)
    logic [Q_SIZE-1:0] valid_bits;
    always_comb begin
        for (int i = 0; i < Q_SIZE; i++) begin
            valid_bits[i] = entries[i][VALID_IDX];
        end 
    end

    logic [Q_SIZE-1:0] prec_head, prec_tail, prec_j, map_tail, map_j;
    logic [Q_SIZE-1:0] raw_before, raw_after;

    always_comb begin
        // Helper prec and map functions
        // prec(j) returns bit vector of 1s for all queue entries before j
        prec_head = (Q_SIZE'(1) << head) - 1'b1;    // Bit vector of size 8 shifted by head and indicate 1s where everything else is after head
        prec_tail = (Q_SIZE'(1) << tail) - 1'b1;
        prec_j = (Q_SIZE'(1) << j) - 1'b1;
        // map(j) returns bit vector of 1 at position j and 0s elsewhere
        map_tail = Q_SIZE'(1) << tail;
        map_j = Q_SIZE'(1) << j;

        // before(j) logic 
        if (j >= head) 
            raw_before = ~prec_head & prec_j;
        else
            raw_before = ~prec_head | prec_j;

        // after(j) logic 
        if (j <= tail) 
            raw_after = ~prec_j & ~map_j & (prec_tail | map_tail);
        else
            raw_after = (~prec_j | prec_tail | map_tail) & ~map_j;

        // Combine calculated masks with the valid bits of the entries
        before_matches = raw_before & valid_bits;
        after_matches  = raw_after  & valid_bits;
    end
    
endmodule
