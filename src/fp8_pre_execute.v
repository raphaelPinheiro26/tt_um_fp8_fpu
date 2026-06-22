// ======================================================================
// MÓDULO 2: fp8_pre_execute
// Trata todos os casos especiais (NaN, Inf, Zero) e decide se o resultado
// pode ser resolvido imediatamente ou se precisa ir para o execute.
//
// Formato FP8 E4M3:
//   - Operandos de 8 bits [sinal|exp(4)|mant(3)]
//   - Inf  : exp=1111, mant=000
//   - NaN  : exp=1111, mant≠000
//   - Zero : exp=0000, mant=000
//   - Sub  : exp=0000, mant≠000
// ======================================================================
`include "header_fp8.v"

module fp8_pre_execute (
    input  wire [7:0]              A,
    input  wire [7:0]              B,
    input  wire [`OP_WIDTH-1:0]    opcode,
    input  wire [`RD_WIDTH-1:0]    rounding_mode,

    // Entradas dos unpackers
    input  wire                    signA, signB,
    input  wire [3:0]              expA,  expB,
    input  wire [2:0]              mantA, mantB,
    input  wire [`FLAG_WIDTH-1:0]  flagsA, flagsB,

    // Saídas de controle
    output reg                     use_special,
    output reg  [7:0]              special_result,
    output reg  [`FLAG_WIDTH-1:0]  special_flags,
    output reg  [`EXC_WIDTH-1:0]   special_exceptions,

    // Sinal efetivo de B (inverte para SUB)
    output wire                    signB_eff
);

    wire a_is_nan       = flagsA[`FLAG_NAN];
    wire b_is_nan       = flagsB[`FLAG_NAN];
    wire a_is_inf       = flagsA[`FLAG_INF];
    wire b_is_inf       = flagsB[`FLAG_INF];
    wire a_is_zero      = flagsA[`FLAG_ZERO];
    wire b_is_zero      = flagsB[`FLAG_ZERO];
    wire a_is_subnormal = flagsA[`FLAG_SUBNORMAL];
    wire b_is_subnormal = flagsB[`FLAG_SUBNORMAL];

    assign signB_eff = (opcode == `OPCODE_SUB) ? ~signB : signB;

    // NaN canônico: exp=1111, mant=001 (quiet NaN mínimo)
    localparam [7:0] CANONICAL_NAN = 8'b0_1111_001;
    // +Inf e -Inf
    // {sign, 4'b1111, 3'b000}

    reg result_sign_zero;

    always @(*) begin
        use_special         = 1'b1;
        special_result      = 8'h00;
        special_flags       = 7'b0;
        special_exceptions  = 5'b0;
        result_sign_zero    = 1'b0;

        // ==============================================================
        // CASO 1: NaN em qualquer operando
        // ==============================================================
        if (a_is_nan || b_is_nan) begin
            special_result = a_is_nan ? {signA, 4'b1111, mantA} :
                                        {signB, 4'b1111, mantB};
            special_flags[`FLAG_NAN]  = 1'b1;
            special_flags[`FLAG_QNAN] = 1'b1;
            special_exceptions[`EXC_INVALID_OP] = 1'b1;
        end

        // ==============================================================
        // CASO 2: Inf op Inf
        // ==============================================================
        else if (a_is_inf && b_is_inf) begin
            if (opcode == `OPCODE_MULT) begin
                // ±Inf × ±Inf = ±Inf (sinal XOR)
                special_result = {signA ^ signB, 4'b1111, 3'b000};
                special_flags[`FLAG_INF] = 1'b1;
            end else if (opcode == `OPCODE_DIV) begin
                // ±Inf / ±Inf = NaN
                special_result = CANONICAL_NAN;
                special_flags[`FLAG_NAN]  = 1'b1;
                special_flags[`FLAG_QNAN] = 1'b1;
                special_exceptions[`EXC_INVALID_OP] = 1'b1;
            end else begin
                // ADD: Inf + (-Inf) = NaN; Inf + Inf = Inf
                // SUB: Inf - Inf = NaN; Inf - (-Inf) = Inf
                if ((opcode == `OPCODE_SUB && signA == signB) ||
                    (opcode == `OPCODE_ADD && signA != signB)) begin
                    special_result = CANONICAL_NAN;
                    special_flags[`FLAG_NAN]  = 1'b1;
                    special_flags[`FLAG_QNAN] = 1'b1;
                    special_exceptions[`EXC_INVALID_OP] = 1'b1;
                end else begin
                    special_result = {signA, 4'b1111, 3'b000};
                    special_flags[`FLAG_INF] = 1'b1;
                end
            end
        end

        // ==============================================================
        // CASO 3: Inf op finito (ou finito op Inf)
        // ==============================================================
        else if (a_is_inf || b_is_inf) begin
            if (opcode == `OPCODE_MULT) begin
                // Inf × 0 = NaN
                if ((a_is_inf && b_is_zero) || (b_is_inf && a_is_zero)) begin
                    special_result = CANONICAL_NAN;
                    special_flags[`FLAG_NAN]  = 1'b1;
                    special_flags[`FLAG_QNAN] = 1'b1;
                    special_exceptions[`EXC_INVALID_OP] = 1'b1;
                end else begin
                    special_result = {signA ^ signB, 4'b1111, 3'b000};
                    special_flags[`FLAG_INF] = 1'b1;
                end
            end else if (opcode == `OPCODE_DIV) begin
                if (a_is_inf) begin
                    // ±Inf / finito = ±Inf
                    special_result = {signA ^ signB, 4'b1111, 3'b000};
                    special_flags[`FLAG_INF] = 1'b1;
                end else begin
                    // finito / ±Inf = ±0
                    special_result = {signA ^ signB, 7'b000_0000};
                    special_flags[`FLAG_ZERO] = 1'b1;
                end
            end else begin
                // ADD/SUB: Inf domina
                if (a_is_inf) begin
                    special_result = {signA, 4'b1111, 3'b000};
                end else begin
                    special_result = {signB_eff, 4'b1111, 3'b000};
                end
                special_flags[`FLAG_INF] = 1'b1;
            end
        end

        // ==============================================================
        // CASO 4: Zero op Zero
        // ==============================================================
        else if (a_is_zero && b_is_zero) begin
            if (opcode == `OPCODE_DIV) begin
                // 0 / 0 = NaN
                special_result = CANONICAL_NAN;
                special_flags[`FLAG_NAN]  = 1'b1;
                special_flags[`FLAG_QNAN] = 1'b1;
                special_exceptions[`EXC_INVALID_OP] = 1'b1;
            end else if (opcode == `OPCODE_MULT) begin
                // ±0 × ±0 = ±0 (sinal XOR)
                special_result = {signA ^ signB, 7'b000_0000};
                special_flags[`FLAG_ZERO] = 1'b1;
            end else begin
                // ADD/SUB: regras IEEE para sinal do zero
                if (opcode == `OPCODE_SUB) begin
                    result_sign_zero = (rounding_mode[2:0] == `ROUND_DOWN) ? 1'b1 : 1'b0;
                end else begin
                    result_sign_zero = signA & signB;
                end
                special_result = {result_sign_zero, 7'b000_0000};
                special_flags[`FLAG_ZERO] = 1'b1;
            end
        end

        // ==============================================================
        // CASO 5: A é zero (B não é)
        // ==============================================================
        else if (a_is_zero) begin
            if (opcode == `OPCODE_MULT) begin
                special_result = {signA ^ signB, 7'b000_0000};
                special_flags[`FLAG_ZERO] = 1'b1;
            end else if (opcode == `OPCODE_DIV) begin
                // 0 / finito = ±0
                special_result = {signA ^ signB, 7'b000_0000};
                special_flags[`FLAG_ZERO] = 1'b1;
            end else begin
                // ADD/SUB: 0 ± B = ±B
                special_result = {signB_eff, expB, mantB};
                if (b_is_subnormal)
                    special_flags[`FLAG_SUBNORMAL] = 1'b1;
                else
                    special_flags[`FLAG_NORMAL] = 1'b1;
            end
        end

        // ==============================================================
        // CASO 6: B é zero (A não é)
        // ==============================================================
        else if (b_is_zero) begin
            if (opcode == `OPCODE_MULT) begin
                special_result = {signA ^ signB, 7'b000_0000};
                special_flags[`FLAG_ZERO] = 1'b1;
            end else if (opcode == `OPCODE_DIV) begin
                // finito / 0 = ±Inf
                special_result = {signA ^ signB, 4'b1111, 3'b000};
                special_flags[`FLAG_INF] = 1'b1;
                special_exceptions[`EXC_DIV_ZERO] = 1'b1;
            end else begin
                // ADD/SUB: A ± 0 = A
                special_result = {signA, expA, mantA};
                if (a_is_subnormal)
                    special_flags[`FLAG_SUBNORMAL] = 1'b1;
                else
                    special_flags[`FLAG_NORMAL] = 1'b1;
            end
        end

        // ==============================================================
        // Nenhum caso especial — vai para execute normal
        // ==============================================================
        else begin
            use_special = 1'b0;
        end
    end
endmodule
