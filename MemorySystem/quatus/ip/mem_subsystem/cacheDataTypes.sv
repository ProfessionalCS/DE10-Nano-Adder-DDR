`timescale 1ns/1ps

package cacheDataTypes;
	localparam int VADDR_WIDTH = 48; // 256 TB address space (virtual)
	localparam int PADDR_WIDTH = 30; // 1 GB address space (physical)
	// Common info for all cache levels
	localparam int BLOCK_SIZE = 64;
	localparam int DATA_WIDTH = 512;
	localparam int OFFSET_WIDTH = $clog2(BLOCK_SIZE);

	// Info for L1 goes here:

	// Info for L2
	// localparam int L2_CAPACITY = 4096;
	localparam int L2_WAYS = 4;
	localparam int L2_SETS = 16;
	localparam int L2_MSHR_COUNT = 4;
	localparam int L2_WAY_WIDTH = $clog2(L2_WAYS);
	localparam int L2_INDEX_WIDTH = $clog2(L2_SETS);
	localparam int L2_TAG_WIDTH = PADDR_WIDTH - OFFSET_WIDTH - L2_INDEX_WIDTH;
	localparam int L2_MSHR_QUEUE_SIZE = 1;
	localparam int L2_MSHR_TAIL_WIDTH = (L2_MSHR_QUEUE_SIZE <= 1) ? 1 : $clog2(L2_MSHR_QUEUE_SIZE + 1);



	/** L2 structures and stuff **/

	typedef struct packed {
		logic isWrite;
		logic [BLOCK_SIZE-1:0] writeData; // Data to write for store, don't care for load
	} l2_mshr_miss_t;

	typedef struct packed {
		logic valid; // This MSHR is active and tracking misses
		logic [PADDR_WIDTH-1:0] addr; // Address of the miss being tracked (block-aligned)
		logic [L2_MSHR_TAIL_WIDTH-1:0] tail; // Number of queued ops for this miss
	} l2_mshr_t;

	typedef struct packed {
		logic [L2_TAG_WIDTH-1:0] tag;
		logic valid;
		logic dirty;
	} l2LineMetadata; // Metadata for each cache line

endpackage: cacheDataTypes
