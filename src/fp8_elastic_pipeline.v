// ======================================================================
// FP8 Elastic Pipeline — pipeline de 4 estágios com handshake
//
// Latência constante (todos os resultados, especiais e normais, seguem
// o mesmo caminho de 4 registradores).
//
// Estágios:
//   R0 (entrada) → R1 (unpack + pre_exec + execute combinacional, CRU)
//                → R2 (normalize combinacional)
//                → R3 (round combinacional)
//                → R4 (saída)
//
// A normalização agora é um ESTÁGIO PRÓPRIO (fp8_normalize), entre o
// execute (que entrega o resultado cru) e o round. Cada estágio é
// separado por um fp8_handshake_reg elástico (valid/ready).
//
// Larguras dos barramentos internos:
//   FP8 E4M3: 8 bits de dado, exp 4 bits, mant 3 bits
//   execute cru -> normalize -> régua 16 bits (mant_wide) + exp_real(6)
// ======================================================================
`include "header_fp8.v"

module fp8_elastic_pipeline (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    flush,

    input  wire                    valid_in,
    output wire                    ready_out,
    input  wire [7:0]              A,
    input  wire [7:0]              B,
    input  wire [`OP_WIDTH-1:0]    opcode,
    input  wire [`RD_WIDTH-1:0]    rounding_mode,

    output wire                    valid_out,
    input  wire                    ready_in,
    output wire [7:0]              result,
    output wire [`FLAG_WIDTH-1:0]  flags,
    output wire [`EXC_WIDTH-1:0]   exceptions
);

    // ======================================================================
    // Estágio Comb-0: unpack + pre_execute + execute (todos combinacional)
    // ======================================================================

    // Unpack A e B
    wire        s1_signA, s1_signB;
    wire [3:0]  s1_expA,  s1_expB;
    wire [2:0]  s1_mantA, s1_mantB;
    wire [`FLAG_WIDTH-1:0] s1_flagsA, s1_flagsB;

    fp8_unpack unpack_a (
        .fp(A),
        .sign(s1_signA), .exp(s1_expA), .mant(s1_mantA), .flags(s1_flagsA)
    );
    fp8_unpack unpack_b (
        .fp(B),
        .sign(s1_signB), .exp(s1_expB), .mant(s1_mantB), .flags(s1_flagsB)
    );

    // Pre-execute: casos especiais
    wire        use_special;
    wire [7:0]  special_result;
    wire [`FLAG_WIDTH-1:0]  special_flags;
    wire [`EXC_WIDTH-1:0]   special_exceptions;
    wire        signB_eff;

    fp8_pre_execute pre_exec (
        .A(A), .B(B),
        .opcode(opcode), .rounding_mode(rounding_mode),
        .signA(s1_signA), .signB(s1_signB),
        .expA(s1_expA),   .expB(s1_expB),
        .mantA(s1_mantA), .mantB(s1_mantB),
        .flagsA(s1_flagsA), .flagsB(s1_flagsB),
        .use_special(use_special),
        .special_result(special_result),
        .special_flags(special_flags),
        .special_exceptions(special_exceptions),
        .signB_eff(signB_eff)
    );

    // Execute: operação aritmética (saída CRUA, sem normalizar)
    wire               exec_sign;
    wire               exec_is_zero;
    wire [`NRM_ACCW-1:0]  exec_acc;
    wire signed [5:0]  exec_big_e;
    wire [7:0]         exec_prod;
    wire signed [5:0]  exec_e_base;
    wire [`NRM_QDIV+4:0]  exec_quot;
    wire signed [5:0]  exec_e_div0;
    wire               exec_remnz;

    fp8_execute_comb exec_comb (
        .signA(s1_signA), .signB(s1_signB),
        .expA(s1_expA),   .expB(s1_expB),
        .mantA(s1_mantA), .mantB(s1_mantB),
        .flagsA(s1_flagsA), .flagsB(s1_flagsB),
        .opcode(opcode), .signB_eff(signB_eff),
        .exec_sign(exec_sign), .exec_is_zero(exec_is_zero),
        .exec_acc(exec_acc),   .exec_big_e(exec_big_e),
        .exec_prod(exec_prod), .exec_e_base(exec_e_base),
        .exec_quot(exec_quot), .exec_e_div0(exec_e_div0), .exec_remnz(exec_remnz)
    );

    // ======================================================================
    // Registrador R0 → R1
    // Empacota: especial + resultado CRU do execute + opcode + rounding_mode
    // (opcode é necessário para o normalize selecionar o caminho)
    // ======================================================================
    localparam R1_WIDTH = 1 + 8 + `FLAG_WIDTH + `EXC_WIDTH +     // especial
                          1 + 1 +                                 // sign + is_zero
                          `NRM_ACCW + 6 +                         // acc + big_e
                          8 + 6 +                                 // prod + e_base
                          (`NRM_QDIV+5) + 6 + 1 +                 // quot + e_div0 + remnz
                          `OP_WIDTH + `RD_WIDTH;                  // opcode + rounding

    wire [R1_WIDTH-1:0] r1_data_in;
    wire [R1_WIDTH-1:0] r1_data_out;
    wire r1_valid_out, r1_ready_in;

    assign r1_data_in = {use_special, special_result, special_flags, special_exceptions,
                         exec_sign, exec_is_zero,
                         exec_acc, exec_big_e,
                         exec_prod, exec_e_base,
                         exec_quot, exec_e_div0, exec_remnz,
                         opcode, rounding_mode};

    fp8_handshake_reg #(.DATA_WIDTH(R1_WIDTH)) reg_r0_r1 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(valid_in),   .ready_out(ready_out),
        .data_in(r1_data_in),
        .valid_out(r1_valid_out), .data_out(r1_data_out),
        .ready_in(r1_ready_in)
    );

    // Desempacota R1
    wire        r1_use_special;
    wire [7:0]  r1_special_result;
    wire [`FLAG_WIDTH-1:0]  r1_special_flags;
    wire [`EXC_WIDTH-1:0]   r1_special_exc;
    wire               r1_exec_sign;
    wire               r1_exec_is_zero;
    wire [`NRM_ACCW-1:0]  r1_exec_acc;
    wire signed [5:0]  r1_exec_big_e;
    wire [7:0]         r1_exec_prod;
    wire signed [5:0]  r1_exec_e_base;
    wire [`NRM_QDIV+4:0]  r1_exec_quot;
    wire signed [5:0]  r1_exec_e_div0;
    wire               r1_exec_remnz;
    wire [`OP_WIDTH-1:0]  r1_opcode;
    wire [`RD_WIDTH-1:0]  r1_rounding;

    assign {r1_use_special, r1_special_result, r1_special_flags, r1_special_exc,
            r1_exec_sign, r1_exec_is_zero,
            r1_exec_acc, r1_exec_big_e,
            r1_exec_prod, r1_exec_e_base,
            r1_exec_quot, r1_exec_e_div0, r1_exec_remnz,
            r1_opcode, r1_rounding} = r1_data_out;

    // ======================================================================
    // Estágio Comb-1: normalize (resultado cru -> régua de 16 bits)
    // ======================================================================
    wire               norm_sign;
    wire [15:0]        norm_mant_wide;
    wire signed [5:0]  norm_exp_real;
    wire               norm_is_zero;

    fp8_normalize norm_inst (
        .opcode(r1_opcode),
        .in_sign(r1_exec_sign), .in_is_zero(r1_exec_is_zero),
        .in_acc(r1_exec_acc),   .in_big_e(r1_exec_big_e),
        .in_prod(r1_exec_prod), .in_e_base(r1_exec_e_base),
        .in_quot(r1_exec_quot), .in_e_div0(r1_exec_e_div0), .in_remnz(r1_exec_remnz),
        .norm_sign(norm_sign), .norm_mant_wide(norm_mant_wide),
        .norm_exp_real(norm_exp_real), .norm_is_zero(norm_is_zero)
    );

    // ======================================================================
    // Registrador R1 → R2
    // Empacota: especial + régua normalizada (16b) + rounding_mode
    // ======================================================================
    localparam R2_WIDTH = 1 + 8 + `FLAG_WIDTH + `EXC_WIDTH +     // especial
                          1 + 16 + 6 + 1 +                        // norm ruler
                          `RD_WIDTH;                              // rounding

    wire [R2_WIDTH-1:0] r2_data_in;
    wire [R2_WIDTH-1:0] r2_data_out;
    wire r2_valid_out, r2_ready_in;

    assign r2_data_in = {r1_use_special, r1_special_result, r1_special_flags, r1_special_exc,
                         norm_sign, norm_mant_wide, norm_exp_real, norm_is_zero,
                         r1_rounding};

    fp8_handshake_reg #(.DATA_WIDTH(R2_WIDTH)) reg_r1_r2 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(r1_valid_out), .ready_out(r1_ready_in),
        .data_in(r2_data_in),
        .valid_out(r2_valid_out), .data_out(r2_data_out),
        .ready_in(r2_ready_in)
    );

    // Desempacota R2
    wire        r2_use_special;
    wire [7:0]  r2_special_result;
    wire [`FLAG_WIDTH-1:0]  r2_special_flags;
    wire [`EXC_WIDTH-1:0]   r2_special_exc;
    wire               r2_norm_sign;
    wire [15:0]        r2_norm_mant_wide;
    wire signed [5:0]  r2_norm_exp_real;
    wire               r2_norm_is_zero;
    wire [`RD_WIDTH-1:0]  r2_rounding;

    assign {r2_use_special, r2_special_result, r2_special_flags, r2_special_exc,
            r2_norm_sign, r2_norm_mant_wide, r2_norm_exp_real, r2_norm_is_zero,
            r2_rounding} = r2_data_out;

    // ======================================================================
    // Estágio Comb-2: round (régua larga -> FP8 final)
    // ======================================================================
    wire [7:0]             round_result;
    wire [`FLAG_WIDTH-1:0] round_flags;
    wire [`EXC_WIDTH-1:0]  round_exc;

    fp8_round round_inst (
        .sign(r2_norm_sign), .exp_real(r2_norm_exp_real),
        .mant_wide(r2_norm_mant_wide), .is_zero(r2_norm_is_zero),
        .rounding_mode(r2_rounding[2:0]),
        .result(round_result), .flags(round_flags), .exceptions(round_exc)
    );

    // ======================================================================
    // Registrador R2 → R3
    // Empacota: use_special + especial + round
    // ======================================================================
    localparam R3_WIDTH = 1 + 8 + `FLAG_WIDTH + `EXC_WIDTH +
                              8 + `FLAG_WIDTH + `EXC_WIDTH;

    wire [R3_WIDTH-1:0] r3_data_in;
    wire [R3_WIDTH-1:0] r3_data_out;
    wire r3_valid_out, r3_ready_in;

    assign r3_data_in = {r2_use_special, r2_special_result, r2_special_flags, r2_special_exc,
                         round_result,   round_flags,       round_exc};

    fp8_handshake_reg #(.DATA_WIDTH(R3_WIDTH)) reg_r2_r3 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(r2_valid_out), .ready_out(r2_ready_in),
        .data_in(r3_data_in),
        .valid_out(r3_valid_out), .data_out(r3_data_out),
        .ready_in(r3_ready_in)
    );

    // Desempacota R3
    wire        r3_use_special;
    wire [7:0]  r3_special_result;
    wire [`FLAG_WIDTH-1:0]  r3_special_flags;
    wire [`EXC_WIDTH-1:0]   r3_special_exc;
    wire [7:0]  r3_round_result;
    wire [`FLAG_WIDTH-1:0]  r3_round_flags;
    wire [`EXC_WIDTH-1:0]   r3_round_exc;

    assign {r3_use_special, r3_special_result, r3_special_flags, r3_special_exc,
            r3_round_result, r3_round_flags,   r3_round_exc} = r3_data_out;

    // Mux final: especial ou normal
    wire [7:0]             mux_result = r3_use_special ? r3_special_result : r3_round_result;
    wire [`FLAG_WIDTH-1:0] mux_flags  = r3_use_special ? r3_special_flags  : r3_round_flags;
    wire [`EXC_WIDTH-1:0]  mux_exc    = r3_use_special ? r3_special_exc    : r3_round_exc;

    // ======================================================================
    // Registrador R3 → R4 (saída)
    // ======================================================================
    localparam R4_WIDTH = 8 + `FLAG_WIDTH + `EXC_WIDTH;

    wire [R4_WIDTH-1:0] r4_data_in  = {mux_result, mux_flags, mux_exc};
    wire [R4_WIDTH-1:0] r4_data_out;

    fp8_handshake_reg #(.DATA_WIDTH(R4_WIDTH)) reg_r3_r4 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(r3_valid_out), .ready_out(r3_ready_in),
        .data_in(r4_data_in),
        .valid_out(valid_out), .data_out(r4_data_out),
        .ready_in(ready_in)
    );

    assign {result, flags, exceptions} = r4_data_out;

endmodule
