set_false_path -from * -to [get_ports hps_io_hps_io_spim1_inst_CLK]
set_false_path -from * -to [get_ports hps_io_hps_io_spim1_inst_MOSI]
set_false_path -from [get_ports hps_io_hps_io_spim1_inst_MISO] -to *
set_false_path -from * -to [get_ports hps_io_hps_io_spim1_inst_SS0]