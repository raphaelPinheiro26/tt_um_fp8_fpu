// ======================================================================
// fp8_unpack_fv.sv — Beginner-friendly COMBINATIONAL formal example.
//
// fp8_unpack classifies an 8-bit FP8 word into {NaN, Inf, Zero, Subnormal,
// Normal}. A correct classifier must be BOTH mutually exclusive (no word is
// two classes at once) AND complete (every word is exactly one class). That
// "exactly one" property is a one-line formal statement that a solver checks
// across all 256 inputs at once — whereas a directed test would enumerate
// them by hand.
//
// There is no clock and no state here: this is pure combinational formal
// (BMC depth 1 is enough; the SMT solver reasons over every input symbolically).
//
// Tooling: Yosys + SymbiYosys.  Run: sby -f fp8_unpack.sby
// ======================================================================
`default_nettype none
`include "header_fp8.v"

module fp8_unpack_fv (
    input wire [7:0] fp   // free (symbolic) FP8 input — covers all 256 words
);
    wire                   sign;
    wire [3:0]             exp;
    wire [2:0]             mant;
    wire [`FLAG_WIDTH-1:0] flags;

    fp8_unpack dut (.fp(fp), .sign(sign), .exp(exp), .mant(mant), .flags(flags));

    // Named class bits straight from the DUT.
    wire c_nan    = flags[`FLAG_NAN];
    wire c_inf    = flags[`FLAG_INF];
    wire c_zero   = flags[`FLAG_ZERO];
    wire c_sub    = flags[`FLAG_SUBNORMAL];
    wire c_normal = flags[`FLAG_NORMAL];

    always @(*) begin
        // ---- Field extraction is a plain wiring of the input word. ----
        a_sign : assert (sign == fp[7]);
        a_exp  : assert (exp  == fp[6:3]);
        a_mant : assert (mant == fp[2:0]);

        // ---- Exactly-one classification (mutual exclusion + completeness). ----
        // Sum of the five class bits must be exactly 1 (avoid $countones so the
        // native Yosys Verilog frontend accepts it without Verific).
        a_onehot : assert ((c_nan + c_inf + c_zero + c_sub + c_normal) == 3'd1);

        // ---- Each class matches its E4M3 definition. ----
        a_nan  : assert (c_nan  == ((fp[6:3] == 4'hF) && (fp[2:0] != 3'b000)));
        a_inf  : assert (c_inf  == ((fp[6:3] == 4'hF) && (fp[2:0] == 3'b000)));
        a_zero : assert (c_zero == ((fp[6:3] == 4'h0) && (fp[2:0] == 3'b000)));
        a_sub  : assert (c_sub  == ((fp[6:3] == 4'h0) && (fp[2:0] != 3'b000)));

        // ---- E4M3 has no separate signalling NaN; qNaN mirrors the NaN flag. ----
        a_no_snan  : assert (flags[`FLAG_SNAN] == 1'b0);
        a_qnan_eq  : assert (flags[`FLAG_QNAN] == c_nan);
    end

    // Prove each class is actually reachable (assertions are not vacuous).
    always @(*) begin
        c_reach_nan    : cover (c_nan);
        c_reach_inf    : cover (c_inf);
        c_reach_zero   : cover (c_zero);
        c_reach_sub    : cover (c_sub);
        c_reach_normal : cover (c_normal);
    end

endmodule

`default_nettype wire
