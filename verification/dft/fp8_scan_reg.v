// ======================================================================
// fp8_scan_reg.v — What SCAN INSERTION produces, made explicit.
//
// A DFT tool takes an ordinary register and, for each flip-flop, inserts a
// 2:1 mux in front of the D input:
//
//        functional_d --0\
//                        | mux --> D --> [FF] --> Q
//        scan_in ------1/          ^
//                        scan_enable
//
// In FUNCTIONAL mode (scan_enable=0) the flop behaves exactly as before.
// In SHIFT mode (scan_enable=1) every flop takes its neighbour's Q, so the
// whole register becomes a shift register: the tester can SCAN IN any state
// through `scan_in`, run one functional (capture) cycle, then SCAN OUT the
// captured state through `scan_out`. That is how a manufacturing tester gets
// full controllability and observability of internal state.
//
// This mirrors the data register inside fp8_handshake_reg (the buffer proven
// in ../formal). It is illustrative — the real chip's scan chain is threaded
// by the tool across all ~161 flops (see scan_insert.ys) — but it is a
// complete, synthesizable, and simulable example.
//
// Run the self-checking testbench:  see tb_scan_reg.v (iverilog).
// ======================================================================
`default_nettype none

module fp8_scan_reg #(
    parameter WIDTH = 8
) (
    input  wire              clk,
    input  wire              rst,          // active-high, matches the core

    // ---- Functional interface (unchanged from a normal register) ----
    input  wire              load,         // functional write enable
    input  wire [WIDTH-1:0]  d,            // functional data
    output wire [WIDTH-1:0]  q,

    // ---- DFT / scan interface (added by insertion) ----
    input  wire              scan_enable,  // 1 = shift mode
    input  wire              scan_in,      // serial input  (chain head)
    output wire              scan_out       // serial output (chain tail)
);
    reg [WIDTH-1:0] ff;

    // Per-bit next value: in shift mode bit i takes bit i-1 (bit 0 takes
    // scan_in); in functional mode it takes the functional next-state.
    // This is exactly the inserted mux, written behaviourally.
    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ff <= {WIDTH{1'b0}};
        end else if (scan_enable) begin
            // Shift from LSB->MSB: scan_in enters bit 0, MSB leaves at scan_out.
            ff <= {ff[WIDTH-2:0], scan_in};
        end else if (load) begin
            ff <= d;                        // normal functional behaviour
        end
        // else: hold (functional path with load=0)
    end

    assign q        = ff;
    assign scan_out = ff[WIDTH-1];          // chain tail = MSB

endmodule

`default_nettype wire
