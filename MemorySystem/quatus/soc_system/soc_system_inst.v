	soc_system u0 (
		.adder_a_export          (<connected-to-adder_a_export>),          //         adder_a.export
		.adder_b_export          (<connected-to-adder_b_export>),          //         adder_b.export
		.adder_sum_export        (<connected-to-adder_sum_export>),        //       adder_sum.export
		.clk_clk                 (<connected-to-clk_clk>),                 //             clk.clk
		.fpga_mem_waitrequest    (<connected-to-fpga_mem_waitrequest>),    //        fpga_mem.waitrequest
		.fpga_mem_readdata       (<connected-to-fpga_mem_readdata>),       //                .readdata
		.fpga_mem_readdatavalid  (<connected-to-fpga_mem_readdatavalid>),  //                .readdatavalid
		.fpga_mem_burstcount     (<connected-to-fpga_mem_burstcount>),     //                .burstcount
		.fpga_mem_writedata      (<connected-to-fpga_mem_writedata>),      //                .writedata
		.fpga_mem_address        (<connected-to-fpga_mem_address>),        //                .address
		.fpga_mem_write          (<connected-to-fpga_mem_write>),          //                .write
		.fpga_mem_read           (<connected-to-fpga_mem_read>),           //                .read
		.fpga_mem_byteenable     (<connected-to-fpga_mem_byteenable>),     //                .byteenable
		.fpga_mem_debugaccess    (<connected-to-fpga_mem_debugaccess>),    //                .debugaccess
		.hps_0_h2f_reset_reset_n (<connected-to-hps_0_h2f_reset_reset_n>), // hps_0_h2f_reset.reset_n
		.memory_mem_a            (<connected-to-memory_mem_a>),            //          memory.mem_a
		.memory_mem_ba           (<connected-to-memory_mem_ba>),           //                .mem_ba
		.memory_mem_ck           (<connected-to-memory_mem_ck>),           //                .mem_ck
		.memory_mem_ck_n         (<connected-to-memory_mem_ck_n>),         //                .mem_ck_n
		.memory_mem_cke          (<connected-to-memory_mem_cke>),          //                .mem_cke
		.memory_mem_cs_n         (<connected-to-memory_mem_cs_n>),         //                .mem_cs_n
		.memory_mem_ras_n        (<connected-to-memory_mem_ras_n>),        //                .mem_ras_n
		.memory_mem_cas_n        (<connected-to-memory_mem_cas_n>),        //                .mem_cas_n
		.memory_mem_we_n         (<connected-to-memory_mem_we_n>),         //                .mem_we_n
		.memory_mem_reset_n      (<connected-to-memory_mem_reset_n>),      //                .mem_reset_n
		.memory_mem_dq           (<connected-to-memory_mem_dq>),           //                .mem_dq
		.memory_mem_dqs          (<connected-to-memory_mem_dqs>),          //                .mem_dqs
		.memory_mem_dqs_n        (<connected-to-memory_mem_dqs_n>),        //                .mem_dqs_n
		.memory_mem_odt          (<connected-to-memory_mem_odt>),          //                .mem_odt
		.memory_mem_dm           (<connected-to-memory_mem_dm>),           //                .mem_dm
		.memory_oct_rzqin        (<connected-to-memory_oct_rzqin>),        //                .oct_rzqin
		.reset_reset_n           (<connected-to-reset_reset_n>)            //           reset.reset_n
	);

