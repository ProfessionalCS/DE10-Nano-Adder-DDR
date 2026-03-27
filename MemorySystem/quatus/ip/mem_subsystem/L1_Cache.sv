/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off SYNCASYNCNET */
`timescale 1ns/1ps

typedef struct packed {
    logic is_store;      // 1 = queued op is a store, 0 = queued op is a load
    logic[63:0] data;    // Store data to merge into the refill line (ignored for loads)
    logic[7:0] mask;     // Byte-enable mask for store merge (currently always 8'hFF)
    logic[5:0] offset;   // Byte offset inside the 64B cache line
} miss_reg_t;

typedef struct packed {
    logic valid;             // Entry allocated and active
    logic [23:0] block_addr; // Line address = req_addr[29:6] for this miss
    logic mem_sent;          // L2 read request already issued for this entry
    logic done;              // Refill handled (debug/status flag)
    logic[1:0] tail;         // Number of queued merged ops (queue write index)
} mshr_entry_t;

module L1(
input  logic        clk,                      
input  logic        rst_n,                    

// TLB
input  logic        lookup_req_i,             // Trigger: address translation request incoming
input  logic [47:0] lookup_vaddr_i,           // Virtual address needing translation
input  logic [29:0] lookup_paddr_i,           // Physical address result from TLB
output logic        lookup_hit_o,             // 1=Hit (valid+match), 0=Miss (goes L2)

//  response 
input  logic         req_valid,               // memory operation request arriving
input  logic [29:0]  req_addr,                // Physical address for read/write
input  logic         req_write,               // 1=Store, 0=Load operation
input  logic [63:0]  req_wdata,               // Eight bytes of data to write
output logic         resp_valid,              // Data ready: read response or write ack
output logic [63:0]  resp_rdata,              // Eight-byte result from read hit
output logic         resp_is_load,            // 1 = resp_valid is for a load (data valid in resp_rdata)

//L2 
output logic         l2_req_valid,            // Signal: requesting cache line from L2
output logic [29:0]  l2_req_addr,             // Address of line needed from L2
input  logic         l2_resp_valid,           // L2 response ready with cache line
input  logic [511:0] l2_resp_data,            // Full 64-byte cache line from L2

// Write-back port (dirty evictions)
output logic         wb_valid,                // L1 is writing back a dirty evicted line
output logic [29:0]  wb_addr,                 // Byte address of evicted line (line-aligned)
output logic [511:0] wb_data                  // Full 64-byte dirty line content

);
localparam bit L1_VERBOSE = 1'b0;
// [511:0] data line 64B, [0:1] way and [0:3] set
logic [511:0]   data_array  [0:1][0:3]; 
logic [21:0]    tag_array   [0:1][0:3];
logic           valid_array [0:1][0:3];
logic           dirty_array [0:1][0:3];
logic           lru_array   [0:3];
mshr_entry_t mshr0, mshr1;         // Two in-flight miss trackers (2-entry MSHR)
logic           mshrq_is_store [0:1][0:3]; // [mshr_id][slot] op type for merged misses
logic [63:0]    mshrq_data     [0:1][0:3]; // [mshr_id][slot] store payload
logic [7:0]     mshrq_mask     [0:1][0:3]; // [mshr_id][slot] byte mask
logic [5:0]     mshrq_offset   [0:1][0:3]; // [mshr_id][slot] line-local byte offset


// Tag comparison assume we got a tag fromt he TLB and are waiting so we can just brab the data


logic[47:0] grabbedTag;

logic[63:0] grabbedData;
logic [63:0] refill_resp_data;
logic        refill_resp_valid;
assign resp_rdata = refill_resp_valid ? refill_resp_data : grabbedData;
logic resp_valid_read_hit, resp_valid_write;
logic read_hit_pending, write_ack_pending;
assign resp_valid = resp_valid_read_hit | refill_resp_valid | resp_valid_write;
assign resp_is_load = resp_valid_read_hit | refill_resp_valid;


// We are doing the index nits 
logic [1:0] index; // set 
assign index = lookup_vaddr_i[7:6]; 

// Tag bits is the 22 bits 
logic [21:0] tag;
assign tag = lookup_paddr_i[29:8];

logic [5:0] offset;
assign offset = req_addr[5:0];


// we need to have 2 way associetive 
logic hit_way0, hit_way1;
assign hit_way0 = valid_array[0][index] && (tag_array[0][index] == tag); // this is 2 way associete 
assign hit_way1 = valid_array[1][index] && (tag_array[1][index] == tag);

logic hit0, hit1, free0, free1;
assign hit0 = mshr0.valid && (mshr0.block_addr == req_addr[29:6]); // check if the adress is already in the miss queue 
assign hit1 = mshr1.valid && (mshr1.block_addr == req_addr[29:6]);
assign free0 = !mshr0.valid;
assign free1 = !mshr1.valid;

assign lookup_hit_o = hit_way0|hit_way1;

logic tag_match;


// The MSHR we need to get the data and we need to handle the misses maybe we need to add this

// lets talk to this guy

always_ff @(posedge clk) begin: MSHR
    if (!rst_n) begin 
        l2_req_valid <= 1'b0; 
        l2_req_addr  <= '0;
        wb_valid <= 1'b0;
        wb_addr  <= '0;
        wb_data  <= '0;
        refill_resp_valid <= 1'b0;
        refill_resp_data <= '0;
        mshr0.valid <= 1'b0;
        mshr0.mem_sent <= 1'b0;
        mshr0.done <= 1'b0;
        mshr0.tail <= '0;
        mshr0.block_addr <= '0;
        mshr1.valid <= 1'b0;
        mshr1.mem_sent <= 1'b0;
        mshr1.done <= 1'b0;
        mshr1.tail <= '0;
        mshr1.block_addr <= '0;
        grabbedData <= '0;
        tag_match <= 1'b0;
        resp_valid_read_hit <= 1'b0;
        read_hit_pending <= 1'b0;
        write_ack_pending <= 1'b0;
        // initialize deterministic state
        for (int way = 0; way < 2; way++) begin // clean slate on reset, no valid data, no dirty data, tags cleared
            for (int sets = 0; sets < 4; sets++) begin
                valid_array[way][sets] <= 1'b0;
                dirty_array[way][sets] <= 1'b0;
                tag_array[way][sets] <= '0;
                data_array[way][sets] <= '0;
            end
      end
    
    for (int sets = 0; sets < 4; sets++) begin
        lru_array[sets] <= 1'b0;
      end
      resp_valid_write <= 1'b0;
      

    end else begin
        // Default: no new request unless we pick an MSHR below.
        l2_req_valid <= 1'b0; // we are putting zero 
        wb_valid <= 1'b0;
        refill_resp_valid <= 1'b0;
        resp_valid_read_hit <= read_hit_pending;
        resp_valid_write <= write_ack_pending;
        read_hit_pending <= 1'b0;
        write_ack_pending <= 1'b0;

        // Issue exactly one miss request per cycle (simple fixed priority: 0 then 1). we assume 1 cycle 
        if (!free0 && !mshr0.mem_sent) begin
            l2_req_valid <= 1'b1;
            l2_req_addr <= {mshr0.block_addr, 6'b0};
            mshr0.mem_sent <= 1'b1;
        end else if (!free1 && !mshr1.mem_sent) begin
            l2_req_valid <= 1'b1;
            l2_req_addr <= {mshr1.block_addr, 6'b0};
            mshr1.mem_sent <= 1'b1;
        end

        // Consume one returning fill and retire the corresponding in-flight MSHR.
        if (l2_resp_valid) begin // we are getting data back from L2 we need to put it somewhere and we need to update the MSHR and we need to update the cache
            
            logic [1:0] set_idx; // the set indec
            logic [21:0] refill_tag;
            logic refill_way;
            logic [511:0] refill_line;
            logic refill_dirty;
            logic have_load;
            logic [5:0] load_offset;
            if (!free0 && mshr0.mem_sent) begin
               
                set_idx = mshr0.block_addr[1:0];
                refill_tag = mshr0.block_addr[23:2];
                if (!valid_array[0][set_idx]) begin
                    refill_way = 1'b0;
                end else if (!valid_array[1][set_idx]) begin
                    refill_way = 1'b1;
                end else begin
                    refill_way = lru_array[set_idx];
                end
                refill_line = l2_resp_data;
                refill_dirty = 1'b0;
                have_load = 1'b0;
                load_offset = '0;

                // Replay queued stores into the returning line before install.
                for (int q = 0; q < 4; q++) begin
                    if ((q < mshr0.tail) && mshrq_is_store[0][q]) begin
                        refill_line[mshrq_offset[0][q]*8 +: 64] = mshrq_data[0][q];
                        refill_dirty = 1'b1;
                    end else if ((q < mshr0.tail) && !mshrq_is_store[0][q] && !have_load) begin
                        have_load = 1'b1;
                        load_offset = mshrq_offset[0][q];
                    end
                end

                if (have_load) begin
                    refill_resp_valid <= 1'b1;
                    refill_resp_data <= refill_line[load_offset*8 +: 64];
                end else if (refill_dirty) begin
                    // Store-only MSHR: ack now that the store is committed to the line
                    write_ack_pending <= 1'b1;
                end

                // Write back dirty victim before overwriting
                if (valid_array[refill_way][set_idx] && dirty_array[refill_way][set_idx]) begin
                    wb_valid <= 1'b1;
                    wb_addr  <= {tag_array[refill_way][set_idx], set_idx, 6'b0};
                    wb_data  <= data_array[refill_way][set_idx];
                end

                data_array[refill_way][set_idx] <= refill_line;
                tag_array[refill_way][set_idx] <= refill_tag;
                valid_array[refill_way][set_idx] <= 1'b1;
                dirty_array[refill_way][set_idx] <= refill_dirty;
                lru_array[set_idx] <= ~refill_way;
                mshr0.done <= 1'b1;
                mshr0.valid <= 1'b0;
                mshr0.mem_sent <= 1'b0;
                mshr0.tail <= '0;
            end else if (!free1 && mshr1.mem_sent) begin
                set_idx = mshr1.block_addr[1:0];
                refill_tag = mshr1.block_addr[23:2];
                if (!valid_array[0][set_idx]) begin
                    refill_way = 1'b0;
                end else if (!valid_array[1][set_idx]) begin
                    refill_way = 1'b1;
                end else begin
                    refill_way = lru_array[set_idx];
                end
                refill_line = l2_resp_data;
                refill_dirty = 1'b0;
                have_load = 1'b0;
                load_offset = '0;

                // Replay queued stores into the returning line before install.
                for (int q = 0; q < 4; q++) begin
                    if ((q < mshr1.tail) && mshrq_is_store[1][q]) begin
                        refill_line[mshrq_offset[1][q]*8 +: 64] = mshrq_data[1][q];
                        refill_dirty = 1'b1;
                    end else if ((q < mshr1.tail) && !mshrq_is_store[1][q] && !have_load) begin
                        have_load = 1'b1;
                        load_offset = mshrq_offset[1][q];
                    end
                end

                if (have_load) begin
                    refill_resp_valid <= 1'b1;
                    refill_resp_data <= refill_line[load_offset*8 +: 64];
                end else if (refill_dirty) begin
                    // Store-only MSHR: ack now that the store is committed to the line
                    write_ack_pending <= 1'b1;
                end

                // Write back dirty victim before overwriting
                if (valid_array[refill_way][set_idx] && dirty_array[refill_way][set_idx]) begin
                    wb_valid <= 1'b1;
                    wb_addr  <= {tag_array[refill_way][set_idx], set_idx, 6'b0};
                    wb_data  <= data_array[refill_way][set_idx];
                end

                data_array[refill_way][set_idx] <= refill_line;
                tag_array[refill_way][set_idx] <= refill_tag;
                valid_array[refill_way][set_idx] <= 1'b1;
                dirty_array[refill_way][set_idx] <= refill_dirty;
                lru_array[set_idx] <= ~refill_way;
                mshr1.done <= 1'b1;
                mshr1.valid <= 1'b0;
                mshr1.mem_sent <= 1'b0;
                mshr1.tail <= '0;
            end
        end
    






//read logc 

// we have 2 mux if the tag matches the way 1 or way two 
    if (lookup_req_i && !req_write) begin // we got a request and its not a write thus its a read 
        // It should be valid if its a read if its a write we have abother ff for it 
        if (lookup_hit_o) begin // we have a hit
            if (hit_way0 == 1) begin 
                    if (valid_array[0][index] && tag_array[0][index] == tag) begin
                        grabbedData <= data_array[0][index][offset*8 +: 64]; // depends on offset logic
                        tag_match <= tag_array[0][index] == tag;
                        lru_array[index] <= 1'b1;  // way 1 is now LRU victim 
                        read_hit_pending <= 1'b1;
                    end
            end 
            else if (hit_way1 == 1) begin
                    if (valid_array[1][index] && tag_array[1][index] == tag) begin
                        grabbedData <= data_array[1][index][offset*8 +: 64]; // depends on offset logic assume for rn that its the first 64 bits
                        tag_match <= tag_array[1][index] == tag; 
                        lru_array[index] <= 1'b0;  // way 0 is now LRU victim 
                        read_hit_pending <= 1'b1;
                    end
            end 
        end else begin  // Read miss — allocate MSHR
                if (hit0) begin
                    mshrq_is_store[0][mshr0.tail] <= 1'b0;
                    mshrq_data[0][mshr0.tail] <= 64'b0;
                    mshrq_mask[0][mshr0.tail] <= 8'hFF;
                    mshrq_offset[0][mshr0.tail] <= req_addr[5:0];
                    mshr0.tail <= mshr0.tail + 1;
                end
                else if (hit1) begin
                    mshrq_is_store[1][mshr1.tail] <= 1'b0;
                    mshrq_data[1][mshr1.tail] <= 64'b0;
                    mshrq_mask[1][mshr1.tail] <= 8'hFF;
                    mshrq_offset[1][mshr1.tail] <= req_addr[5:0];
                    mshr1.tail <= mshr1.tail + 1;
                end
                else if (free0) begin
                    mshr0.valid      <= 1;
                    mshr0.block_addr <= req_addr[29:6];
                    mshr0.mem_sent   <= 0;
                    mshr0.done       <= 0;
                    mshrq_is_store[0][0] <= 1'b0;
                    mshrq_data[0][0] <= 64'b0;
                    mshrq_mask[0][0] <= 8'hFF;
                    mshrq_offset[0][0] <= req_addr[5:0];
                    mshr0.tail       <= 1;
                end
                else if (free1) begin
                    mshr1.valid      <= 1;
                    mshr1.block_addr <= req_addr[29:6];
                    mshr1.mem_sent   <= 0;
                    mshr1.done       <= 0;
                    mshrq_is_store[1][0] <= 1'b0;
                    mshrq_data[1][0] <= 64'b0;
                    mshrq_mask[1][0] <= 8'hFF;
                    mshrq_offset[1][0] <= req_addr[5:0];
                    mshr1.tail       <= 1;
                end
            end
    end
    
    // the plan is to add write logic to the L1 we can assume that we have already done all the cleaning 
    // assume no hazards and life is good // we just have to write data nothing big here we are given a adress and will follow the same way as the thing 
    if (lookup_req_i && req_write) begin: write // we have a write request and its valid 
        //we need to write to a spot on data, write the dirty bit and and update the valid
        // nothing is there we just want something
        
        // Hit and we can just change the data or nothings in it
        if (lookup_hit_o) begin // We got a hit its real and we need to write to that spot
            if ((valid_array[0][index] && tag_array[0][index] == tag)) begin
                valid_array[0][index] <= 1;
                dirty_array[0][index] <= 1;
                data_array[0][index][offset*8 +: 64] <= req_wdata;
                lru_array[index] <= 1'b1;  // way 1 is now LRU victim
                
                // send data to L2 and make sure they write it
                write_ack_pending <= 1'b1;  // Write finished

            end
            else if (valid_array[1][index] && tag_array[1][index] == tag) begin
                valid_array[1][index] <= 1;
                dirty_array[1][index] <= 1;
                data_array[1][index][offset*8 +: 64] <= req_wdata;
                lru_array[index] <= 1'b0;  // way 0 is now LRU victim
                
                write_ack_pending <= 1'b1;
            end 
            else begin
                // This should never happen because we have a hit but no match 
                // we should scream and die if this happens because it means we have a bug in our hit logic
                // add debug print statement here in case this ever happens


            end
        end

        else begin  // okay so we fucked up and need to get from L2 
            if (hit0) begin
                mshrq_is_store[0][mshr0.tail] <= 1'b1;
                mshrq_data[0][mshr0.tail] <= req_wdata;
                mshrq_mask[0][mshr0.tail] <= 8'hFF;
                mshrq_offset[0][mshr0.tail] <= req_addr[5:0];
                mshr0.tail <= mshr0.tail + 1;
            end
            else if (hit1) begin
                mshrq_is_store[1][mshr1.tail] <= 1'b1;
                mshrq_data[1][mshr1.tail] <= req_wdata;
                mshrq_mask[1][mshr1.tail] <= 8'hFF;
                mshrq_offset[1][mshr1.tail] <= req_addr[5:0];
                mshr1.tail <= mshr1.tail + 1;
            end
            // Primary miss: allocate a free entry
            else if (free0) begin
                mshr0.valid      <= 1;
                mshr0.block_addr <= req_addr[29:6];
                mshr0.mem_sent   <= 0;
                mshr0.done       <= 0;
                mshrq_is_store[0][0] <= 1'b1;
                mshrq_data[0][0] <= req_wdata;
                mshrq_mask[0][0] <= 8'hFF;
                mshrq_offset[0][0] <= req_addr[5:0];
                mshr0.tail       <= 1;
            end
            else if (free1) begin
                mshr1.valid      <= 1;
                mshr1.block_addr <= req_addr[29:6];
                mshr1.mem_sent   <= 0;
                mshr1.done       <= 0;
                mshrq_is_store[1][0] <= 1'b1;
                mshrq_data[1][0] <= req_wdata;
                mshrq_mask[1][0] <= 8'hFF;
                mshrq_offset[1][0] <= req_addr[5:0];
                mshr1.tail       <= 1;
            end
            // else: both MSHRs full, stall 
            // resp_valid <= 1'b0; // stall, backpressure to core until we can accept this write miss

            end
        end
    end

    end
endmodule 
