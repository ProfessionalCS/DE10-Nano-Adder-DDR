	component soc_system is
		port (
			adder_a_export          : out   std_logic_vector(63 downto 0);                    -- export
			adder_b_export          : out   std_logic_vector(63 downto 0);                    -- export
			adder_sum_export        : in    std_logic_vector(63 downto 0) := (others => 'X'); -- export
			clk_clk                 : in    std_logic                     := 'X';             -- clk
			fpga_mem_waitrequest    : out   std_logic;                                        -- waitrequest
			fpga_mem_readdata       : out   std_logic_vector(63 downto 0);                    -- readdata
			fpga_mem_readdatavalid  : out   std_logic;                                        -- readdatavalid
			fpga_mem_burstcount     : in    std_logic_vector(0 downto 0)  := (others => 'X'); -- burstcount
			fpga_mem_writedata      : in    std_logic_vector(63 downto 0) := (others => 'X'); -- writedata
			fpga_mem_address        : in    std_logic_vector(31 downto 0) := (others => 'X'); -- address
			fpga_mem_write          : in    std_logic                     := 'X';             -- write
			fpga_mem_read           : in    std_logic                     := 'X';             -- read
			fpga_mem_byteenable     : in    std_logic_vector(7 downto 0)  := (others => 'X'); -- byteenable
			fpga_mem_debugaccess    : in    std_logic                     := 'X';             -- debugaccess
			hps_0_h2f_reset_reset_n : out   std_logic;                                        -- reset_n
			memory_mem_a            : out   std_logic_vector(14 downto 0);                    -- mem_a
			memory_mem_ba           : out   std_logic_vector(2 downto 0);                     -- mem_ba
			memory_mem_ck           : out   std_logic;                                        -- mem_ck
			memory_mem_ck_n         : out   std_logic;                                        -- mem_ck_n
			memory_mem_cke          : out   std_logic;                                        -- mem_cke
			memory_mem_cs_n         : out   std_logic;                                        -- mem_cs_n
			memory_mem_ras_n        : out   std_logic;                                        -- mem_ras_n
			memory_mem_cas_n        : out   std_logic;                                        -- mem_cas_n
			memory_mem_we_n         : out   std_logic;                                        -- mem_we_n
			memory_mem_reset_n      : out   std_logic;                                        -- mem_reset_n
			memory_mem_dq           : inout std_logic_vector(31 downto 0) := (others => 'X'); -- mem_dq
			memory_mem_dqs          : inout std_logic_vector(3 downto 0)  := (others => 'X'); -- mem_dqs
			memory_mem_dqs_n        : inout std_logic_vector(3 downto 0)  := (others => 'X'); -- mem_dqs_n
			memory_mem_odt          : out   std_logic;                                        -- mem_odt
			memory_mem_dm           : out   std_logic_vector(3 downto 0);                     -- mem_dm
			memory_oct_rzqin        : in    std_logic                     := 'X';             -- oct_rzqin
			reset_reset_n           : in    std_logic                     := 'X'              -- reset_n
		);
	end component soc_system;

	u0 : component soc_system
		port map (
			adder_a_export          => CONNECTED_TO_adder_a_export,          --         adder_a.export
			adder_b_export          => CONNECTED_TO_adder_b_export,          --         adder_b.export
			adder_sum_export        => CONNECTED_TO_adder_sum_export,        --       adder_sum.export
			clk_clk                 => CONNECTED_TO_clk_clk,                 --             clk.clk
			fpga_mem_waitrequest    => CONNECTED_TO_fpga_mem_waitrequest,    --        fpga_mem.waitrequest
			fpga_mem_readdata       => CONNECTED_TO_fpga_mem_readdata,       --                .readdata
			fpga_mem_readdatavalid  => CONNECTED_TO_fpga_mem_readdatavalid,  --                .readdatavalid
			fpga_mem_burstcount     => CONNECTED_TO_fpga_mem_burstcount,     --                .burstcount
			fpga_mem_writedata      => CONNECTED_TO_fpga_mem_writedata,      --                .writedata
			fpga_mem_address        => CONNECTED_TO_fpga_mem_address,        --                .address
			fpga_mem_write          => CONNECTED_TO_fpga_mem_write,          --                .write
			fpga_mem_read           => CONNECTED_TO_fpga_mem_read,           --                .read
			fpga_mem_byteenable     => CONNECTED_TO_fpga_mem_byteenable,     --                .byteenable
			fpga_mem_debugaccess    => CONNECTED_TO_fpga_mem_debugaccess,    --                .debugaccess
			hps_0_h2f_reset_reset_n => CONNECTED_TO_hps_0_h2f_reset_reset_n, -- hps_0_h2f_reset.reset_n
			memory_mem_a            => CONNECTED_TO_memory_mem_a,            --          memory.mem_a
			memory_mem_ba           => CONNECTED_TO_memory_mem_ba,           --                .mem_ba
			memory_mem_ck           => CONNECTED_TO_memory_mem_ck,           --                .mem_ck
			memory_mem_ck_n         => CONNECTED_TO_memory_mem_ck_n,         --                .mem_ck_n
			memory_mem_cke          => CONNECTED_TO_memory_mem_cke,          --                .mem_cke
			memory_mem_cs_n         => CONNECTED_TO_memory_mem_cs_n,         --                .mem_cs_n
			memory_mem_ras_n        => CONNECTED_TO_memory_mem_ras_n,        --                .mem_ras_n
			memory_mem_cas_n        => CONNECTED_TO_memory_mem_cas_n,        --                .mem_cas_n
			memory_mem_we_n         => CONNECTED_TO_memory_mem_we_n,         --                .mem_we_n
			memory_mem_reset_n      => CONNECTED_TO_memory_mem_reset_n,      --                .mem_reset_n
			memory_mem_dq           => CONNECTED_TO_memory_mem_dq,           --                .mem_dq
			memory_mem_dqs          => CONNECTED_TO_memory_mem_dqs,          --                .mem_dqs
			memory_mem_dqs_n        => CONNECTED_TO_memory_mem_dqs_n,        --                .mem_dqs_n
			memory_mem_odt          => CONNECTED_TO_memory_mem_odt,          --                .mem_odt
			memory_mem_dm           => CONNECTED_TO_memory_mem_dm,           --                .mem_dm
			memory_oct_rzqin        => CONNECTED_TO_memory_oct_rzqin,        --                .oct_rzqin
			reset_reset_n           => CONNECTED_TO_reset_reset_n            --           reset.reset_n
		);

