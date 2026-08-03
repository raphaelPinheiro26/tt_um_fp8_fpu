// ======================================================================
// FP8 Elastic Pipeline — LATENCIA VARIAVEL (divisor iterativo)
//
// add/sub/mul e casos especiais: 1 ciclo, totalmente pipelined.
// DIV real (finito/finito): unidade iterativa fp8_div_iter.
//
// MODELO DE UNIDADE FUNCIONAL DESACOPLADA (correto sob back-pressure):
//   - a op de div e' CONSUMIDA da entrada no ciclo de aceitacao (handshake
//     de entrada), com os operandos e campos auxiliares latchados;
//   - a unidade itera ~WN ciclos;
//   - o resultado e' entregue a' RA por um handshake de SAIDA independente
//     de valid_in (um produtor pode baixar valid_in antes do handshake).
//   Durante a iteracao, ready_out=0 (as ops seguintes esperam, in-order).
//
//   C0: unpack+pre+execute+normalize -> RA
//   C1: round                        -> RB
//   MUX especial/normal              -> RC (saida)
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

    // ------------------ C0 comb: unpack + pre + execute --------------------
    wire        s1_signA, s1_signB;
    wire [3:0]  s1_expA,  s1_expB;
    wire [2:0]  s1_mantA, s1_mantB;
    wire [`FLAG_WIDTH-1:0] s1_flagsA, s1_flagsB;

    fp8_unpack unpack_a (.fp(A), .sign(s1_signA), .exp(s1_expA), .mant(s1_mantA), .flags(s1_flagsA));
    fp8_unpack unpack_b (.fp(B), .sign(s1_signB), .exp(s1_expB), .mant(s1_mantB), .flags(s1_flagsB));

    wire        use_special;
    wire [7:0]  special_result;
    wire [`FLAG_WIDTH-1:0]  special_flags;
    wire [`EXC_WIDTH-1:0]   special_exceptions;
    wire        signB_eff;

    fp8_pre_execute pre_exec (
        .A(A), .B(B), .opcode(opcode), .rounding_mode(rounding_mode),
        .signA(s1_signA), .signB(s1_signB), .expA(s1_expA), .expB(s1_expB),
        .mantA(s1_mantA), .mantB(s1_mantB), .flagsA(s1_flagsA), .flagsB(s1_flagsB),
        .use_special(use_special), .special_result(special_result),
        .special_flags(special_flags), .special_exceptions(special_exceptions),
        .signB_eff(signB_eff)
    );

    // Operacoes diretas (MIN/MAX/ABS/CLASSIFY/COMPARE) — combinacionais,
    // entram pelo caminho "especial" com precedencia sobre o pre_execute.
    wire                   do_direct;
    wire [7:0]             dr_result;
    wire [`FLAG_WIDTH-1:0] dr_flags;
    wire [`EXC_WIDTH-1:0]  dr_exc;
    fp8_direct_ops direct_ops (
        .A(A), .B(B), .opcode(opcode), .rounding_mode(rounding_mode[2:0]),
        .signA(s1_signA), .signB(s1_signB),
        .flagsA(s1_flagsA), .flagsB(s1_flagsB),
        .do_direct(do_direct), .dr_result(dr_result),
        .dr_flags(dr_flags), .dr_exc(dr_exc)
    );
    wire                   dd_use_special = use_special | do_direct;
    wire [7:0]             dd_special_result = do_direct ? dr_result : special_result;
    wire [`FLAG_WIDTH-1:0] dd_special_flags  = do_direct ? dr_flags  : special_flags;
    wire [`EXC_WIDTH-1:0]  dd_special_exc    = do_direct ? dr_exc    : special_exceptions;

    wire               exec_sign, exec_is_zero;
    wire [`NRM_ACCW-1:0]  exec_acc;
    wire signed [5:0]  exec_big_e;
    wire [7:0]         exec_prod;
    wire signed [5:0]  exec_e_base;
    wire [3:0]         exec_mA4, exec_mB4;
    wire signed [5:0]  exec_e_div0;
    wire               exec_parity;
    wire signed [5:0]  exec_eA_r;

    fp8_execute_comb exec_comb (
        .signA(s1_signA), .signB(s1_signB), .expA(s1_expA), .expB(s1_expB),
        .mantA(s1_mantA), .mantB(s1_mantB), .flagsA(s1_flagsA), .flagsB(s1_flagsB),
        .opcode(opcode), .signB_eff(signB_eff),
        .exec_sign(exec_sign), .exec_is_zero(exec_is_zero),
        .exec_acc(exec_acc), .exec_big_e(exec_big_e),
        .exec_prod(exec_prod), .exec_e_base(exec_e_base),
        .exec_mA4(exec_mA4), .exec_mB4(exec_mB4), .exec_e_div0(exec_e_div0),
        .exec_parity(exec_parity), .exec_eA_r(exec_eA_r)
    );

    // ---------------- FSM de latencia variavel + div iterativo -------------
    localparam ST_FAST = 1'b0, ST_BUSY = 1'b1;
    reg  st;
    reg  div_done_reg;
    // campos auxiliares do token de div, latchados na aceitacao
    reg  div_sign_r;
    reg  signed [5:0] div_e_div0_r;
    reg  [`RD_WIDTH-1:0] div_rm_r;

    // DIV e SQRT usam a unidade iterativa (latencia variavel)
    wire real_div = valid_in & ((opcode == `OPCODE_DIV) | (opcode == `OPCODE_SQRT)) & ~use_special;

    wire        div_busy, div_done;    // div_busy nao e' usado (sink abaixo)
    wire [`NRM_QDIV+4:0] div_quot;
    wire        div_remnz;

    // aceita (consome) a div da entrada
    wire div_accept = (st == ST_FAST) & real_div;
    wire div_start  = div_accept;

    fp8_div_iter #(.QDIV(`NRM_QDIV)) u_div (
        .clk(clk), .rst(rst), .flush(flush), .start(div_start),
        .mode(opcode == `OPCODE_SQRT), .parity(exec_parity),
        .mA4(exec_mA4), .mB4(exec_mB4),
        .busy(div_busy), .done(div_done), .quot(div_quot), .remnz(div_remnz)
    );

    wire div_ready = div_done | div_done_reg;
    wire n_busy    = (st == ST_BUSY);

    // ---------------- Normalize (comb) — inputs muxados por estado ----------
    wire [`OP_WIDTH-1:0] n_opcode = n_busy ? `OPCODE_DIV : opcode;
    wire                 n_sign   = n_busy ? div_sign_r  : exec_sign;
    wire                 n_zero   = n_busy ? 1'b0        : exec_is_zero;
    wire signed [5:0]    n_ediv0  = n_busy ? div_e_div0_r: exec_e_div0;

    wire               norm_sign, norm_is_zero;
    wire [15:0]        norm_mant_wide;
    wire signed [5:0]  norm_exp_real;

    fp8_normalize norm_inst (
        .opcode(n_opcode), .in_sign(n_sign), .in_is_zero(n_zero),
        .in_acc(exec_acc), .in_big_e(exec_big_e),
        .in_prod(exec_prod), .in_e_base(exec_e_base),
        .in_quot(div_quot), .in_e_div0(n_ediv0), .in_remnz(div_remnz),
        .norm_sign(norm_sign), .norm_mant_wide(norm_mant_wide),
        .norm_exp_real(norm_exp_real), .norm_is_zero(norm_is_zero)
    );

    // ---------------- SCALB: regua direta (A * 2^n) -> round ---------------
    wire is_scalb = (opcode == `OPCODE_SCALB);
    wire signed [9:0] scalb_ew = $signed({{4{exec_eA_r[5]}}, exec_eA_r})
                               + $signed({{2{B[7]}}, B});          // n = B (int8)
    wire signed [5:0] scalb_exp = (scalb_ew >  10'sd31) ?  6'sd31 :
                                  (scalb_ew < -10'sd32) ? -6'sd32 : scalb_ew[5:0];
    wire [15:0]       scalb_mw  = {exec_mA4, 12'b0};               // MSB (bit3) -> bit15
    // Regua final que entra na RA: SCALB injeta direto; senao vem do normalize
    wire               fin_sign = is_scalb ? s1_signA  : norm_sign;
    wire [15:0]        fin_mw   = is_scalb ? scalb_mw   : norm_mant_wide;
    wire signed [5:0]  fin_er   = is_scalb ? scalb_exp  : norm_exp_real;
    wire               fin_zero = is_scalb ? 1'b0       : norm_is_zero;

    // ---------------- RA (C0 -> C1) ----------------------------------------
    localparam RA_WIDTH = 1 + 8 + `FLAG_WIDTH + `EXC_WIDTH + 1 + 16 + 6 + 1 + `RD_WIDTH;
    wire [RA_WIDTH-1:0] ra_data_in, ra_data_out;
    wire ra_valid_out, ra_ready_in, ra_ready_w;

    // token: no BUSY (div) forcamos use_special=0 e rm=div_rm_r
    wire                 tok_use_special = n_busy ? 1'b0 : dd_use_special;
    wire [7:0]           tok_special_res = n_busy ? 8'b0 : dd_special_result;
    wire [`FLAG_WIDTH-1:0] tok_special_fl = n_busy ? {`FLAG_WIDTH{1'b0}} : dd_special_flags;
    wire [`EXC_WIDTH-1:0]  tok_special_ex = n_busy ? {`EXC_WIDTH{1'b0}}  : dd_special_exc;
    wire [`RD_WIDTH-1:0]   tok_rm         = n_busy ? div_rm_r : rounding_mode;

    assign ra_data_in = {tok_use_special, tok_special_res, tok_special_fl, tok_special_ex,
                         fin_sign, fin_mw, fin_er, fin_zero, tok_rm};

    // Handshakes:
    //   FAST: op rapida -> RA (valid_in & ~real_div); div -> consome ja (ready_out=1)
    //   BUSY: entrega o resultado do div a' RA quando pronto (independe de valid_in)
    wire f_valid   = n_busy ? div_ready : (valid_in & ~real_div);
    assign ready_out = n_busy ? 1'b0 : (real_div ? 1'b1 : ra_ready_w);
    wire div_consume = n_busy & div_ready & ra_ready_w;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= ST_FAST; div_done_reg <= 1'b0;
            div_sign_r <= 1'b0; div_e_div0_r <= 6'sd0; div_rm_r <= {`RD_WIDTH{1'b0}};
        end else if (flush) begin
            st <= ST_FAST; div_done_reg <= 1'b0;
        end else begin
            div_done_reg <= (div_done_reg | div_done) & ~div_consume;
            if (div_accept) begin
                div_sign_r   <= exec_sign;
                div_e_div0_r <= exec_e_div0;
                div_rm_r     <= rounding_mode;
            end
            case (st)
                ST_FAST: if (div_accept)  st <= ST_BUSY;
                ST_BUSY: if (div_consume) st <= ST_FAST;
            endcase
        end
    end

    fp8_handshake_reg #(.DATA_WIDTH(RA_WIDTH)) reg_r0_r1 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(f_valid), .ready_out(ra_ready_w),
        .data_in(ra_data_in), .valid_out(ra_valid_out), .data_out(ra_data_out),
        .ready_in(ra_ready_in)
    );

    wire        ra_use_special;
    wire [7:0]  ra_special_result;
    wire [`FLAG_WIDTH-1:0]  ra_special_flags;
    wire [`EXC_WIDTH-1:0]   ra_special_exc;
    wire               ra_norm_sign, ra_norm_is_zero;
    wire [15:0]        ra_norm_mant_wide;
    wire signed [5:0]  ra_norm_exp_real;
    wire [`RD_WIDTH-1:0]  ra_rounding;

    assign {ra_use_special, ra_special_result, ra_special_flags, ra_special_exc,
            ra_norm_sign, ra_norm_mant_wide, ra_norm_exp_real, ra_norm_is_zero,
            ra_rounding} = ra_data_out;

    // rm carregado em 4 bits (usa 3); div_busy nao e' consumido. Sink p/ linter.
    wire _unused_ep = &{1'b0, ra_rounding[3], div_busy};

    // ---------------- C1 comb: round ---------------------------------------
    wire [7:0]             round_result;
    wire [`FLAG_WIDTH-1:0] round_flags;
    wire [`EXC_WIDTH-1:0]  round_exc;

    fp8_round round_inst (
        .sign(ra_norm_sign), .exp_real(ra_norm_exp_real),
        .mant_wide(ra_norm_mant_wide), .is_zero(ra_norm_is_zero),
        .rounding_mode(ra_rounding[2:0]),
        .result(round_result), .flags(round_flags), .exceptions(round_exc)
    );

    // ---------------- RB (C1 -> MUX) ---------------------------------------
    localparam RB_WIDTH = 1 + 8 + `FLAG_WIDTH + `EXC_WIDTH + 8 + `FLAG_WIDTH + `EXC_WIDTH;
    wire [RB_WIDTH-1:0] rb_data_in, rb_data_out;
    wire rb_valid_out, rb_ready_in;

    assign rb_data_in = {ra_use_special, ra_special_result, ra_special_flags, ra_special_exc,
                         round_result, round_flags, round_exc};

    fp8_handshake_reg #(.DATA_WIDTH(RB_WIDTH)) reg_r1_r2 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(ra_valid_out), .ready_out(ra_ready_in),
        .data_in(rb_data_in), .valid_out(rb_valid_out), .data_out(rb_data_out),
        .ready_in(rb_ready_in)
    );

    wire        rb_use_special;
    wire [7:0]  rb_special_result;
    wire [`FLAG_WIDTH-1:0]  rb_special_flags;
    wire [`EXC_WIDTH-1:0]   rb_special_exc;
    wire [7:0]  rb_round_result;
    wire [`FLAG_WIDTH-1:0]  rb_round_flags;
    wire [`EXC_WIDTH-1:0]   rb_round_exc;

    assign {rb_use_special, rb_special_result, rb_special_flags, rb_special_exc,
            rb_round_result, rb_round_flags, rb_round_exc} = rb_data_out;

    wire [7:0]             mux_result = rb_use_special ? rb_special_result : rb_round_result;
    wire [`FLAG_WIDTH-1:0] mux_flags  = rb_use_special ? rb_special_flags  : rb_round_flags;
    wire [`EXC_WIDTH-1:0]  mux_exc    = rb_use_special ? rb_special_exc    : rb_round_exc;

    // ---------------- RC (saida) -------------------------------------------
    localparam RC_WIDTH = 8 + `FLAG_WIDTH + `EXC_WIDTH;
    wire [RC_WIDTH-1:0] rc_data_in  = {mux_result, mux_flags, mux_exc};
    wire [RC_WIDTH-1:0] rc_data_out;

    fp8_handshake_reg #(.DATA_WIDTH(RC_WIDTH)) reg_r2_r3 (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(rb_valid_out), .ready_out(rb_ready_in),
        .data_in(rc_data_in), .valid_out(valid_out), .data_out(rc_data_out),
        .ready_in(ready_in)
    );

    assign {result, flags, exceptions} = rc_data_out;

endmodule
