`timescale 1ns / 1ps

module multiplier_easy (
    input   logic[7:0]  A,
    input   logic[7:0]  B,
    input   logic       clk_in,
    input   logic       start_mult,
    input   logic       reset_n,
    output  logic[15:0] y_out,
    output  logic       ready
);
logic[15:0] temp;
logic[3:0] counter;
assign y_out = temp;
logic [7:0]  A_reg, B_reg;
logic running;

always_ff @(posedge clk_in) begin
    if (!reset_n) begin
        temp <= 0;
        counter <= 0;
        ready <= 0;
        running <= 0; 
        A_reg <= 0;
        B_reg <= 0;
    end else begin
        ready <= 1'b0;
        if (start_mult && !running) begin 
            temp <= 0;
            counter <= 0;
            ready <= 0;
            running <= 1;
            A_reg <= A; 
            B_reg <= B;
        end else if (running) begin
            // Explicit 16-bit cast to avoid WIDTHTRUNC on shift result
            if (B_reg[counter]) temp <= temp + 16'(({8'b0, A_reg} << counter));
            if (counter == 4'd7) begin
                running <= 0;
                ready <= 1;
                counter <= 0;
            end else begin
                counter <= counter + 4'd1;
            end
        end
    end
end
endmodule

module inputHandle(
    input  logic[15:0] x_in,
    input  logic[15:0] y_in,
    output logic       Sx,
    output logic[6:0]  Fx,
    output logic[7:0]  Ex,
    output logic       Sy,
    output logic[6:0]  Fy,
    output logic[7:0]  Ey
);
    assign Sx = x_in[15];
    assign Fx = x_in[6:0];
    assign Ex = x_in[14:7];
    assign Sy = y_in[15];
    assign Fy = y_in[6:0];
    assign Ey = y_in[14:7];
endmodule

module basicExpo(
    input   logic[7:0] e1,
    input   logic[7:0] e2,
    output  logic[7:0] out_e,
    output  logic      overflow,
    output  logic      zero
);

logic signed [9:0] temp;
assign temp = {2'b0, e1} + {2'b0, e2} - 10'd127;
assign zero = (temp <= 0);
assign overflow = (temp > 254);
assign out_e = temp[7:0];
endmodule

module normalize(
    input   logic[15:0] x_in,
    input   logic       reset_n,
    input   logic       clk_in,
    input   logic       start,
    output  logic[15:0] y_out,
    output  logic[3:0]  expo_increase,
    output  logic       done
);
    logic[15:0] temp;
    logic[3:0]  shift_count;
    logic busy;
    
    assign y_out = temp;
    assign expo_increase = shift_count;
    
    always_ff @(posedge clk_in) begin
        if (!reset_n) begin
            temp <= 0;
            shift_count <= 0;
            done <= 1'b0;
            busy <= 0;
        end else begin 
            if (start && !busy) begin
                temp <= x_in;
                shift_count <= 0;
                done <= 0;
                busy <= 1;
            end else if (busy) begin
                if (temp == 0) begin
                    done <= 1;
                    busy <= 0;
                end else if (!temp[15] && shift_count != 4'd15) begin
                    temp <= temp << 1;
                    shift_count <= shift_count + 4'd1;
                end else begin
                    done <= 1;
                    busy <= 0;
                end
            end
        end
    end
endmodule

module fpmult #(parameter int P = 8, parameter int Q = 8) (
    input  logic rst_in_N,
    input  logic clk_in,
    input  logic [P+Q-1:0] x_in,
    input  logic [P+Q-1:0] y_in,
    input  logic [1:0] round_in,
    input  logic start_in,
    output logic [P+Q-1:0] p_out,
    output logic [3:0] oor_out,
    output logic valid_out,
    output logic ready_out
);

    typedef enum logic[2:0] {
        IDLE,
        MULTIPLY,
        NORMALIZE,
        ROUND,
        DONE
    } state_t;
    
    state_t state, next_state;
    logic [15:0] x_lat, y_lat;

    always_ff @(posedge clk_in) begin
        if (!rst_in_N) begin
            x_lat <= 16'h0;
            y_lat <= 16'h0;
        end else if (state == IDLE && start_in) begin
            x_lat <= x_in;
            y_lat <= y_in;
        end
    end
    
    // Input decomposition
    logic       Sx, Sy;
    logic [6:0] Fx, Fy;
    logic [7:0] Ex, Ey;
    inputHandle input_handle(x_lat, y_lat, Sx, Fx, Ex, Sy, Fy, Ey);  
    
    // Exponent calculation   
    logic [7:0] base_exponent;
    logic overflow_exp, zero_exp;
    basicExpo expo_handle(Ex, Ey, base_exponent, overflow_exp, zero_exp);
    
    // Multiplier
    logic [15:0] mult_result;
    logic mult_ready;
    logic mult_start;
    multiplier_easy mult({1'b1, x_in[6:0]}, {1'b1, y_in[6:0]}, clk_in, mult_start, rst_in_N, mult_result, mult_ready);
    
    // Normalizer
    logic [15:0] norm_result;
    logic [3:0]  expo_decrease;
    logic norm_done;
    logic norm_start;
    normalize normalizer(mult_result, rst_in_N, clk_in, norm_start, norm_result, expo_decrease, norm_done);
    
    // Final values
    logic [6:0] final_mantissa;
    logic [7:0] final_exponent;
    
    // State register
    always_ff @(posedge clk_in) begin
        if (!rst_in_N) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        norm_start = 1'b0;
        valid_out  = 1'b0;
        ready_out  = 1'b0;
        mult_start = (state == IDLE) && start_in;
        case (state)
            IDLE: begin
                ready_out = 1'b1;
                if (start_in) next_state = MULTIPLY;
            end
            MULTIPLY: begin
                if (mult_ready) begin
                    next_state = NORMALIZE;
                    norm_start = 1'b1;
                end
            end
            NORMALIZE: begin 
                if (norm_done) next_state = ROUND;
            end
            ROUND: begin
                next_state = DONE;
            end
            DONE: begin
                valid_out  = 1'b1;
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end
    
    // Rounding intermediates — all declared at module scope (not inside always_ff)
    logic [6:0] mantissa_bits;
    logic       guard, round_bit, sticky;
    logic       round_up;
    logic [7:0] mantissa_rounded;
    logic [8:0] adjusted_exponent;
    logic       sign_v;
    logic [8:0] exp_v;

    always_ff @(posedge clk_in) begin
        if (!rst_in_N) begin
            p_out             <= '0;
            oor_out           <= '0;
            mantissa_bits     <= '0;
            guard             <= '0;
            round_bit         <= '0;
            sticky            <= '0;
            adjusted_exponent <= '0;
            sign_v            <= '0;
            exp_v             <= '0;
            round_up          <= '0;
            mantissa_rounded  <= '0;
            final_mantissa    <= '0;
            final_exponent    <= '0;
        end else if (state == ROUND) begin
            exp_v  = {1'b0, base_exponent};
            sign_v = Sx ^ Sy;
            
            if (norm_result[15]) begin
                mantissa_bits     = norm_result[14:8];
                guard             = norm_result[7];
                round_bit         = norm_result[6];
                sticky            = |norm_result[5:0];
                adjusted_exponent = exp_v + 9'd1 - {5'b0, expo_decrease};
            end else begin
                mantissa_bits     = norm_result[13:7];
                guard             = norm_result[6];
                round_bit         = norm_result[5];
                sticky            = |norm_result[4:0];
                adjusted_exponent = exp_v - {5'b0, expo_decrease};
            end
            
            round_up         = guard & (round_bit | sticky | mantissa_bits[0]);
            // Explicit widths on both sides: 8-bit result, no truncation warning
            mantissa_rounded = {1'b0, mantissa_bits} + {7'b0, round_up};
            
            if (mantissa_rounded[7]) begin
                final_mantissa = mantissa_rounded[6:0];
                final_exponent = adjusted_exponent[7:0] + 8'd1;
            end else begin
                final_mantissa = mantissa_rounded[6:0];
                final_exponent = adjusted_exponent[7:0];
            end
            
            if (adjusted_exponent >= 9'd255) begin
                oor_out <= 4'b0100;
                p_out   <= {sign_v, 8'hFF, 7'b0};
            end else if (adjusted_exponent[8] || adjusted_exponent == 9'd0) begin
                oor_out <= 4'b1000;
                p_out   <= {sign_v, 15'b0};
            end else begin
                oor_out <= 4'b0000;
                p_out   <= {sign_v, final_exponent, final_mantissa};
            end
        end
    end

    // Consume unused signals to prevent UNUSEDSIGNAL warnings
    logic unused;
    assign unused = &{round_in, Fx, Fy, overflow_exp, zero_exp, 1'b0};

endmodule