// ======================================================================
// MÓDULO 5: fp8_round  (CAMINHO 2 — régua larga, normalize+round fundidos)
// ======================================================================
// Consome a saída larga do execute:
//   sign        – sinal do resultado
//   mant_wide   – 16 bits: [15]=hidden, [14:12]=mant3, [11:0]=GRS amplo
//   exp_real    – expoente REAL sinalizado (E_field = exp_real + bias)
//   is_zero     – resultado exatamente zero
//   rounding_mode – 3 bits
//
// Decide NORMAL vs SUBNORMAL com base em E_field = exp_real + bias:
//   E_field >= 1 : normal
//   E_field <  1 : subnormal -> shift-right adicional d = EMIN - exp_real,
//                  preservando sticky; mant fica na régua subnormal.
//
// Arredondamento nos 5 modos sobre (mant3, guard, round, sticky):
//   NEAREST (ties-even), ZERO, UP(+inf), DOWN(-inf), ODD(round-to-odd).
//
// Overflow (E_field final > 14) segue IEEE-like, com regra por modo.
// ======================================================================
`include "header_fp8.v"

module fp8_round (
    input  wire              sign,
    input  wire signed [5:0] exp_real,
    input  wire [15:0]       mant_wide,
    input  wire              is_zero,
    input  wire [2:0]        rounding_mode,
    output reg  [7:0]              result,
    output reg  [`FLAG_WIDTH-1:0]  flags,
    output reg  [`EXC_WIDTH-1:0]   exceptions
);
    localparam signed [6:0] BIAS_S = 7'sd7;
    localparam signed [6:0] EMIN_S = -7'sd6;

    reg signed [6:0] e_field;     // exp_real + bias
    reg [2:0]  mant3;
    reg        g, r, s;
    reg        inexact;
    reg        do_inc;
    reg [3:0]  m_inc;             // {carry, mant3} + inc
    reg [6:0]  d_sub;             // shift subnormal
    reg [15:0] wsr;               // mant_wide deslocada (subnormal)
    reg        lost;

    // decisão de incremento por modo
    function do_round;
        input [2:0] rm;
        input       sgn;
        input       lsb, gg, rr, ss;
        reg         inx;
        begin
            inx = gg | rr | ss;
            case (rm)
                3'b000: do_round = gg & (rr | ss | lsb);
                3'b001:    do_round = 1'b0;
                3'b010:      do_round = (~sgn) & inx;
                3'b011:    do_round = ( sgn) & inx;
                3'b100:     do_round = inx & (~lsb);
                default:             do_round = 1'b0;
            endcase
        end
    endfunction

    always @(*) begin
        result     = 8'h00;
        flags      = 7'b0;
        exceptions = 5'b0;
        mant3 = 3'b0; g=1'b0; r=1'b0; s=1'b0; inexact=1'b0; do_inc=1'b0;
        m_inc = 4'b0; d_sub = 7'b0; wsr = 16'b0; lost=1'b0;
        e_field = exp_real + BIAS_S;

        // ---------------- ZERO ----------------
        if (is_zero || mant_wide == 16'b0) begin
            result = {(rounding_mode == 3'b011) ? 1'b1 : 1'b0, 7'b0};
            flags[`FLAG_ZERO] = 1'b1;

        // ---------------- NORMAL ----------------
        end else if (e_field >= 7'sd1) begin
            mant3 = mant_wide[14:12];
            g     = mant_wide[11];
            r     = mant_wide[10];
            s     = |mant_wide[9:0];
            inexact = g | r | s;
            do_inc  = do_round(rounding_mode, sign, mant3[0], g, r, s);
            m_inc   = {1'b0, mant3} + do_inc;

            if (m_inc[3]) begin
                // carry -> mant volta a 000, expoente +1
                e_field = e_field + 7'sd1;
                mant3   = 3'b000;
            end else begin
                mant3 = m_inc[2:0];
            end

            if (inexact) exceptions[`EXC_INEXACT] = 1'b1;

            if (e_field > 7'sd14) begin
                // overflow IEEE por modo
                case (rounding_mode)
                    3'b001: begin
                        result = {sign, 4'b1110, 3'b111};  // maior finito
                        flags[`FLAG_NORMAL] = 1'b1;
                    end
                    3'b010: begin
                        if (sign) begin result = {sign,4'b1110,3'b111}; flags[`FLAG_NORMAL]=1'b1; end
                        else       begin result = {sign,4'b1111,3'b000}; flags[`FLAG_INF]=1'b1; exceptions[`EXC_OVERFLOW]=1'b1; end
                    end
                    3'b011: begin
                        if (sign) begin result = {sign,4'b1111,3'b000}; flags[`FLAG_INF]=1'b1; exceptions[`EXC_OVERFLOW]=1'b1; end
                        else       begin result = {sign,4'b1110,3'b111}; flags[`FLAG_NORMAL]=1'b1; end
                    end
                    3'b100: begin
                        result = {sign, 4'b1110, 3'b111};
                        flags[`FLAG_NORMAL] = 1'b1;
                    end
                    default: begin // NEAREST
                        result = {sign, 4'b1111, 3'b000};
                        flags[`FLAG_INF] = 1'b1;
                        exceptions[`EXC_OVERFLOW] = 1'b1;
                    end
                endcase
                exceptions[`EXC_INEXACT] = 1'b1;
            end else begin
                result = {sign, e_field[3:0], mant3};
                flags[`FLAG_NORMAL] = 1'b1;
            end

        // ---------------- SUBNORMAL ----------------
        end else begin
            // d = EMIN - exp_real  (>0). Desloca a régua p/ a direita.
            d_sub = EMIN_S - {exp_real[5], exp_real};   // sign-extend p/ 7 bits
            if (d_sub >= 7'd16) begin
                // tudo descartado -> sticky decide arredondamento p/ menor sub
                lost = |mant_wide;
                wsr  = 16'b0;
                if (lost) wsr[0] = 1'b1;
            end else begin
                lost = |(mant_wide & ((16'b1 << d_sub) - 16'b1));
                wsr  = mant_wide >> d_sub;
                if (lost) wsr[0] = wsr[0] | 1'b1;
            end

            mant3 = wsr[14:12];
            g     = wsr[11];
            r     = wsr[10];
            s     = |wsr[9:0];
            inexact = g | r | s;
            do_inc  = do_round(rounding_mode, sign, mant3[0], g, r, s);
            m_inc   = {1'b0, mant3} + do_inc;

            if (m_inc[3]) begin
                // promove a menor normal (E=1)
                result = {sign, 4'b0001, m_inc[2:0]};
                flags[`FLAG_NORMAL] = 1'b1;
            end else begin
                result = {sign, 4'b0000, m_inc[2:0]};
                if (m_inc[2:0] != 3'b000)
                    flags[`FLAG_SUBNORMAL] = 1'b1;
                else
                    flags[`FLAG_ZERO] = 1'b1;
            end

            if (inexact) begin
                exceptions[`EXC_INEXACT] = 1'b1;
                if (m_inc[2:0] == 3'b000 && !m_inc[3])
                    exceptions[`EXC_UNDERFLOW] = 1'b1;
            end
        end
    end
endmodule
