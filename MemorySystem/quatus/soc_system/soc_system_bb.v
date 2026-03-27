
module soc_system (
	adder_a_export,
	adder_b_export,
	adder_sum_export,
	clk_clk,
	fpga_mem_waitrequest,
	fpga_mem_readdata,
	fpga_mem_readdatavalid,
	fpga_mem_burstcount,
	fpga_mem_writedata,
	fpga_mem_address,
	fpga_mem_write,
	fpga_mem_read,
	fpga_mem_byteenable,
	fpga_mem_debugaccess,
	hps_0_h2f_reset_reset_n,
	memory_mem_a,
	memory_mem_ba,
	memory_mem_ck,
	memory_mem_ck_n,
	memory_mem_cke,
	memory_mem_cs_n,
	memory_mem_ras_n,
	memory_mem_cas_n,
	memory_mem_we_n,
	memory_mem_reset_n,
	memory_mem_dq,
	memory_mem_dqs,
	memory_mem_dqs_n,
	memory_mem_odt,
	memory_mem_dm,
	memory_oct_rzqin,
	reset_reset_n);	

	output	[63:0]	adder_a_export;
	output	[63:0]	adder_b_export;
	input	[63:0]	adder_sum_export;
	input		clk_clk;
	output		fpga_mem_waitrequest;
	output	[63:0]	fpga_mem_readdata;
	output		fpga_mem_readdatavalid;
	input	[0:0]	fpga_mem_burstcount;
	input	[63:0]	fpga_mem_writedata;
	input	[31:0]	fpga_mem_address;
	input		fpga_mem_write;
	input		fpga_mem_read;
	input	[7:0]	fpga_mem_byteenable;
	input		fpga_mem_debugaccess;
	output		hps_0_h2f_reset_reset_n;
	output	[14:0]	memory_mem_a;
	output	[2:0]	memory_mem_ba;
	output		memory_mem_ck;
	output		memory_mem_ck_n;
	output		memory_mem_cke;
	output		memory_mem_cs_n;
	output		memory_mem_ras_n;
	output		memory_mem_cas_n;
	output		memory_mem_we_n;
	output		memory_mem_reset_n;
	inout	[31:0]	memory_mem_dq;
	inout	[3:0]	memory_mem_dqs;
	inout	[3:0]	memory_mem_dqs_n;
	output		memory_mem_odt;
	output	[3:0]	memory_mem_dm;
	input		memory_oct_rzqin;
	input		reset_reset_n;
endmodule
