// ======================================================================
// tb_scan_reg.v — Self-checking testbench for fp8_scan_reg.
//
// Demonstrates the two things scan buys you on a manufacturing tester:
//   TEST 1 (controllability + observability): scan an arbitrary pattern IN,
//           then scan it back OUT bit-by-bit and check it matches.
//   TEST 2 (functional transparency): with scan_enable=0 the register behaves
//           exactly like a normal load register.
//
// Run:  iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb
// ======================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_scan_reg;
    localparam WIDTH = 8;

    reg              clk = 0, rst = 1;
    reg              load = 0, scan_enable = 0, scan_in = 0;
    reg  [WIDTH-1:0] d = 0;
    wire [WIDTH-1:0] q;
    wire             scan_out;

    integer errors = 0;

    fp8_scan_reg #(.WIDTH(WIDTH)) dut (
        .clk(clk), .rst(rst),
        .load(load), .d(d), .q(q),
        .scan_enable(scan_enable), .scan_in(scan_in), .scan_out(scan_out)
    );

    always #5 clk = ~clk;

    // Shift one bit into the chain head.
    task scan_bit(input bit b);
        begin
            scan_enable = 1;
            scan_in     = b;
            @(posedge clk); #1;
        end
    endtask

    reg [WIDTH-1:0] pattern, captured;
    integer i;

    initial begin
        // Release reset.
        repeat (2) @(posedge clk);
        rst = 0;
        @(posedge clk); #1;

        // ---------------- TEST 1: scan a pattern in, then out. ----------
        pattern = 8'b1011_0010;
        // Scan MSB-first so that after WIDTH shifts ff == pattern.
        for (i = WIDTH-1; i >= 0; i = i - 1)
            scan_bit(pattern[i]);
        if (q !== pattern) begin
            $display("FAIL: scanned-in state q=%b expected %b", q, pattern);
            errors = errors + 1;
        end else
            $display("PASS: scan-in loaded internal state = %b", q);

        // Now scan it back out; scan_out presents MSB first each shift.
        captured = 0;
        for (i = 0; i < WIDTH; i = i + 1) begin
            captured[WIDTH-1-i] = scan_out;   // sample tail
            scan_bit(1'b0);                   // shift
        end
        if (captured !== pattern) begin
            $display("FAIL: scanned-out %b expected %b", captured, pattern);
            errors = errors + 1;
        end else
            $display("PASS: scan-out observed state = %b", captured);

        // ---------------- TEST 2: functional mode unaffected. -----------
        scan_enable = 0;
        d = 8'hA5; load = 1; @(posedge clk); #1; load = 0;
        if (q !== 8'hA5) begin
            $display("FAIL: functional load q=%h expected A5", q);
            errors = errors + 1;
        end else
            $display("PASS: functional load works with scan disabled (q=%h)", q);

        // hold check
        d = 8'hFF; @(posedge clk); #1;   // load=0 -> must hold A5
        if (q !== 8'hA5) begin
            $display("FAIL: hold broken q=%h expected A5", q);
            errors = errors + 1;
        end else
            $display("PASS: hold with load=0 (q=%h)", q);

        if (errors == 0) $display("\nALL SCAN TESTS PASSED");
        else             $display("\n%0d SCAN TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
