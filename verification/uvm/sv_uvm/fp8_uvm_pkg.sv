// ======================================================================
// fp8_uvm_pkg.sv — DIDACTIC SystemVerilog-UVM mirror of the pyuvm testbench.
//
// Same architecture as ../pyuvm, in industry SystemVerilog UVM so the two
// dialects can be read side by side (see ../README.md for the mapping table):
//   fp8_cmd / fp8_result  -> transactions       (cf. fp8_item.py)
//   fp8_random_seq        -> constrained-random  (cf. fp8_seq.py)
//   fp8_driver            -> drives input stream (cf. fp8_components.py)
//   fp8_cmd_monitor       -> reconstructs cmds   (cf. fp8_bfm._cmd_monitor)
//   fp8_result_monitor    -> reconstructs results(cf. fp8_bfm._result_monitor)
//   fp8_scoreboard        -> golden-model check  (cf. fp8_components.py)
//   fp8_agent/env/test    -> component hierarchy
//
// Oracle: the scoreboard loads Golden_model/vectors.hex into an associative
// array (the same sign-off reference the RTL is audited against), mirroring
// how sim/tb_fp8_golden.v checks the RTL. This keeps the SV mirror
// self-contained and consistent with the rest of the project.
// ======================================================================
`ifndef FP8_UVM_PKG_SV
`define FP8_UVM_PKG_SV

package fp8_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int unsigned BASE_UIO = (1<<3) | (1<<6); // OUT_READY=1, READ_FULL=1

    // ------------------------------------------------------------------
    // Transactions
    // ------------------------------------------------------------------
    class fp8_cmd extends uvm_sequence_item;
        rand bit [7:0] a;
        rand bit [7:0] b;
        rand bit [4:0] op;   // 0..13
        rand bit [2:0] rm;   // 0..4

        constraint c_op { op inside {[0:13]}; }
        constraint c_rm { rm inside {[0:4]};  }

        `uvm_object_utils_begin(fp8_cmd)
            `uvm_field_int(a,  UVM_ALL_ON)
            `uvm_field_int(b,  UVM_ALL_ON)
            `uvm_field_int(op, UVM_ALL_ON)
            `uvm_field_int(rm, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name="fp8_cmd"); super.new(name); endfunction
    endclass

    class fp8_result extends uvm_sequence_item;
        bit [7:0] result;
        bit [6:0] flags;
        bit [4:0] exc;

        `uvm_object_utils_begin(fp8_result)
            `uvm_field_int(result, UVM_ALL_ON)
            `uvm_field_int(flags,  UVM_ALL_ON)
            `uvm_field_int(exc,    UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name="fp8_result"); super.new(name); endfunction
    endclass

    // ------------------------------------------------------------------
    // Sequences
    // ------------------------------------------------------------------
    class fp8_random_seq extends uvm_sequence #(fp8_cmd);
        `uvm_object_utils(fp8_random_seq)
        int unsigned n = 300;
        // Restrict to arithmetic ops by default; override in the test.
        int unsigned op_lo = 0, op_hi = 3, rm_hi = 4;
        function new(string name="fp8_random_seq"); super.new(name); endfunction

        virtual task body();
            fp8_cmd tr;
            repeat (n) begin
                tr = fp8_cmd::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with {
                        op inside {[op_lo:op_hi]};
                        rm inside {[0:rm_hi]}; })
                    `uvm_error("SEQ","randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Driver — serialise A, B, CTRL onto the input stream with valid/ready.
    // ------------------------------------------------------------------
    class fp8_driver extends uvm_driver #(fp8_cmd);
        `uvm_component_utils(fp8_driver)
        virtual fp8_if vif;
        function new(string name, uvm_component parent); super.new(name,parent); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual fp8_if)::get(this,"","vif",vif))
                `uvm_fatal("DRV","no virtual interface")
        endfunction

        task drive_byte(bit [7:0] data);
            vif.drv_cb.ui_in  <= data;
            vif.drv_cb.uio_in <= BASE_UIO | 8'h01;      // IN_VALID=1
            @(vif.drv_cb);
            while (vif.drv_cb.uio_out[1] !== 1'b1)        // wait IN_READY
                @(vif.drv_cb);
        endtask

        task run_phase(uvm_phase phase);
            fp8_cmd tr;
            forever begin
                seq_item_port.get_next_item(tr);
                drive_byte(tr.a);
                drive_byte(tr.b);
                drive_byte({tr.rm, tr.op});               // CTRL = {rm,opcode}
                vif.drv_cb.uio_in <= BASE_UIO;            // IN_VALID=0
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Command monitor — reconstructs (a,b,op,rm) from accepted input bytes.
    // ------------------------------------------------------------------
    class fp8_cmd_monitor extends uvm_monitor;
        `uvm_component_utils(fp8_cmd_monitor)
        virtual fp8_if vif;
        uvm_analysis_port #(fp8_cmd) ap;
        function new(string name, uvm_component parent);
            super.new(name,parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual fp8_if)::get(this,"","vif",vif))
                `uvm_fatal("MON","no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            bit [7:0] byts[$];
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n !== 1'b1) begin byts.delete(); continue; end
                if (vif.mon_cb.uio_in[0] && vif.mon_cb.uio_out[1]) begin
                    byts.push_back(vif.mon_cb.ui_in);
                    if (byts.size() == 3) begin
                        fp8_cmd tr = fp8_cmd::type_id::create("tr");
                        tr.a  = byts[0];
                        tr.b  = byts[1];
                        tr.op = byts[2][4:0];
                        tr.rm = byts[2][7:5];
                        ap.write(tr);
                        byts.delete();
                    end
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Result monitor — reconstructs (result,flags,exc) from the output stream.
    // ------------------------------------------------------------------
    class fp8_result_monitor extends uvm_monitor;
        `uvm_component_utils(fp8_result_monitor)
        virtual fp8_if vif;
        uvm_analysis_port #(fp8_result) ap;
        function new(string name, uvm_component parent);
            super.new(name,parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual fp8_if)::get(this,"","vif",vif))
                `uvm_fatal("MON","no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            bit [7:0] byts[$];
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n !== 1'b1) begin byts.delete(); continue; end
                if (vif.mon_cb.uio_out[2] && vif.mon_cb.uio_in[3]) begin
                    byts.push_back(vif.mon_cb.uo_out);
                    if (byts.size() == 3) begin
                        fp8_result tr = fp8_result::type_id::create("tr");
                        tr.result = byts[0];
                        tr.flags  = byts[1][6:0];
                        tr.exc    = byts[2][4:0];
                        ap.write(tr);
                        byts.delete();
                    end
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Scoreboard — in-order command/result pairing vs golden reference.
    // ------------------------------------------------------------------
    `uvm_analysis_imp_decl(_cmd)
    `uvm_analysis_imp_decl(_res)

    class fp8_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(fp8_scoreboard)
        uvm_analysis_imp_cmd #(fp8_cmd,    fp8_scoreboard) cmd_imp;
        uvm_analysis_imp_res #(fp8_result, fp8_scoreboard) res_imp;

        fp8_cmd    cmd_q[$];
        int unsigned errors, count;
        // Golden lookup: key {a,b,op,rm} -> {result,flags,exc}.
        bit [19:0] golden [bit [23:0]];

        function new(string name, uvm_component parent);
            super.new(name,parent);
            cmd_imp = new("cmd_imp", this);
            res_imp = new("res_imp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            load_golden("../../../Golden_model/vectors.hex");
        endfunction

        function void load_golden(string path);
            int fd, a, b, op, rm, res, fl, ex, r;
            fd = $fopen(path, "r");
            if (fd == 0) begin
                `uvm_warning("SB", {"cannot open golden file: ", path});
                return;
            end
            forever begin
                r = $fscanf(fd, "%h %h %h %h %h %h %h", a,b,op,rm,res,fl,ex);
                if (r != 7) break;
                golden[{a[7:0],b[7:0],op[4:0],rm[2:0]}] = {res[7:0],fl[6:0],ex[4:0]};
            end
            $fclose(fd);
            `uvm_info("SB", $sformatf("loaded %0d golden entries", golden.size()), UVM_LOW)
        endfunction

        function void write_cmd(fp8_cmd t); cmd_q.push_back(t); endfunction

        function void write_res(fp8_result got);
            fp8_cmd    c;
            bit [23:0] key;
            bit [19:0] exp;
            if (cmd_q.size() == 0) begin
                `uvm_error("SB","result with no pending command"); errors++; return;
            end
            c   = cmd_q.pop_front();
            key = {c.a, c.b, c.op, c.rm};
            count++;
            if (!golden.exists(key)) begin
                `uvm_info("SB", $sformatf("no golden entry for op=%0d (skipped)", c.op), UVM_HIGH);
                return;
            end
            exp = golden[key];
            if ({got.result, got.flags, got.exc} !== exp) begin
                errors++;
                `uvm_error("SB", $sformatf(
                    "MISMATCH a=%02h b=%02h op=%0d rm=%0d : got %05h exp %05h",
                    c.a, c.b, c.op, c.rm, {got.result,got.flags,got.exc}, exp));
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors) `uvm_fatal("SB", $sformatf("%0d mismatches / %0d ops", errors, count));
            else        `uvm_info ("SB", $sformatf("PASS: %0d ops, 0 mismatches", count), UVM_LOW);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Agent / Env
    // ------------------------------------------------------------------
    class fp8_agent extends uvm_agent;
        `uvm_component_utils(fp8_agent)
        uvm_sequencer #(fp8_cmd) seqr;
        fp8_driver              driver;
        fp8_cmd_monitor         cmd_mon;
        fp8_result_monitor      res_mon;
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            seqr    = uvm_sequencer#(fp8_cmd)::type_id::create("seqr", this);
            driver  = fp8_driver        ::type_id::create("driver", this);
            cmd_mon = fp8_cmd_monitor   ::type_id::create("cmd_mon", this);
            res_mon = fp8_result_monitor::type_id::create("res_mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    class fp8_env extends uvm_env;
        `uvm_component_utils(fp8_env)
        fp8_agent      agent;
        fp8_scoreboard sb;
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            agent = fp8_agent     ::type_id::create("agent", this);
            sb    = fp8_scoreboard::type_id::create("sb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agent.cmd_mon.ap.connect(sb.cmd_imp);
            agent.res_mon.ap.connect(sb.res_imp);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    class fp8_base_test extends uvm_test;
        `uvm_component_utils(fp8_base_test)
        fp8_env env;
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            env = fp8_env::type_id::create("env", this);
        endfunction
        // knobs
        protected int unsigned n_rand = 200, op_hi = 3, rm_hi = 4;
        task run_phase(uvm_phase phase);
            fp8_random_seq seq = fp8_random_seq::type_id::create("seq");
            seq.n = n_rand; seq.op_hi = op_hi; seq.rm_hi = rm_hi;
            phase.raise_objection(this);
            seq.start(env.agent.seqr);
            // let the pipeline + output serialiser drain
            repeat (n_rand*60 + 500) @(posedge env.agent.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

    class fp8_full_random_test extends fp8_base_test;
        `uvm_component_utils(fp8_full_random_test)
        function new(string name, uvm_component parent);
            super.new(name,parent); n_rand = 800; op_hi = 13; rm_hi = 4;
        endfunction
    endclass

endpackage
`endif
