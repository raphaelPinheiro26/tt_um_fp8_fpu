// ======================================================================
// fp8_div_iter.v  —  Unidade ITERATIVA compartilhada: DIVISAO e SQRT
// ======================================================================
// Um unico datapath shift + compare-subtract, 1 digito/ciclo, serve para
// as duas operacoes de latencia variavel:
//
//  DIV  (mode=0): restauradora, 1 bit/ciclo.
//     quot  = floor( (mA4<<QDIV) / mB4 )
//     remnz = ( (mA4<<QDIV) % mB4 ) != 0
//
//  SQRT (mode=1): raiz digit-by-digit, 2 bits de radicando / ciclo.
//     RAD   = parity ? (mA4<<8) : (mA4<<7)      (paridade do expoente real)
//     quot  = floor( sqrt(RAD) )   (significando * 2^QDIV, MSB no bit QDIV)
//     remnz = ( RAD - quot^2 ) != 0
//   O 'quot'/'remnz' do SQRT reusam EXATAMENTE o caminho de divisao do
//   fp8_normalize (in_e_div0 = e_real/2), sem logica de normalizacao nova.
//
//   Compartilham: acc (resto), Q, cnt, FSM e o comparador-subtrator.
//   Handshake de latencia variavel: start / busy / done.
// ======================================================================
`include "header_fp8.v"

module fp8_div_iter #(
    parameter QDIV = `NRM_QDIV
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             flush,
    input  wire             start,
    input  wire             mode,      // 0=DIV, 1=SQRT
    input  wire             parity,    // SQRT: expoente real impar?
    input  wire [3:0]       mA4,
    input  wire [3:0]       mB4,
    output reg              busy,
    output reg              done,
    output reg [QDIV+4:0]   quot,
    output reg              remnz
);
    localparam integer WD  = 4 + QDIV;   // bits do dividendo (DIV)
    localparam integer WSR = 12;         // bits do radicando (SQRT, par)
    localparam integer NDIV  = WD;       // iteracoes DIV
    localparam integer NSQRT = WSR/2;    // iteracoes SQRT (2 bits/passo)

    reg          mode_r;
    reg  [11:0]  src;      // dividendo (esq-alinhado) | radicando
    reg  [3:0]   Dreg;     // divisor (DIV)
    reg  [QDIV+4:0] Q;     // digitos acumulados
    reg  [10:0]  acc;      // resto parcial (bit 11 nunca e' lido)
    reg  [4:0]   cnt;

    // ---- passo combinacional (compartilha o compare-subtract) ----
    // DIV : traz 1 bit (src[11]); subtrai Dreg.
    // SQRT: traz 2 bits (src[11:10]); subtrai trial = (Q<<2)|1.
    wire [11:0] acc_pre = mode_r ? {acc[9:0], src[11:10]}
                                 : {acc[10:0], src[11]};
    wire [11:0] sub_val = mode_r ? ({Q, 2'b00} | 12'd1)   // (Q<<2)|1
                                 : {8'b0, Dreg};
    wire        ge      = (acc_pre >= sub_val);
    wire [11:0] acc_nxt = ge ? (acc_pre - sub_val) : acc_pre;
    wire [QDIV+4:0] Q_nxt = {Q[QDIV+3:0], ge};
    wire [11:0] src_nxt = mode_r ? (src << 2) : (src << 1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy<=1'b0; done<=1'b0; quot<={(QDIV+5){1'b0}}; remnz<=1'b0;
            src<=12'b0; Dreg<=4'b0; Q<={(QDIV+5){1'b0}}; acc<=11'b0; cnt<=5'b0; mode_r<=1'b0;
        end else if (flush) begin
            busy<=1'b0; done<=1'b0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                mode_r <= mode;
                Q      <= {(QDIV+5){1'b0}};
                acc    <= 11'b0;
                Dreg   <= mB4;
                busy   <= 1'b1;
                if (mode) begin                       // SQRT
                    src <= parity ? ({8'b0, mA4} << 8) : ({8'b0, mA4} << 7);
                    cnt <= NSQRT[4:0];
                end else begin                        // DIV: esq-alinha em 12 bits
                    src <= ({8'b0, mA4} << QDIV) << (12 - WD);
                    cnt <= NDIV[4:0];
                end
            end else if (busy) begin
                src <= src_nxt;
                acc <= acc_nxt[10:0];
                Q   <= Q_nxt;
                cnt <= cnt - 5'd1;
                if (cnt == 5'd1) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    quot  <= Q_nxt;
                    remnz <= (acc_nxt != 12'b0);
                end
            end
        end
    end
endmodule
