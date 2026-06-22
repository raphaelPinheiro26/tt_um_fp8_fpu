// ======================================================================
// fp8_handshake_reg.v  —  Skid buffer CORRIGIDO (drop-in)
//
// Mesmos ports do fp8_handshake_reg original. Difere em UMA decisao:
//
//   No RTL atual, quando a saida esta VAZIA (valid_out=0) e o downstream
//   esta travado (ready_in=0) e chega um dado (valid_in=1), o dado vai
//   para o SKID em vez da saida. Isso deixa um item "orfao" no skid; num
//   ciclo seguinte, com a saida ainda vazia, o "Caso 3" carrega um dado
//   NOVO direto na saida, que e' emitido ANTES do item preso no skid
//   -> PERDA / REORDENACAO sob back-pressure.
//
// Correcao: a saida pode aceitar dado SEMPRE que estiver vazia
// (ready_in || !valid_out). O skid so e' usado quando a saida esta
// ocupada E travada. Verificado por skid_model.py: 0 falhas em 5000
// sementes (vs 4976/5000 do original).
// ======================================================================
`include "header_fp8.v"

module fp8_handshake_reg #(
    parameter DATA_WIDTH = 1
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    flush,
    input  wire                    valid_in,
    output wire                    ready_out,
    input  wire [DATA_WIDTH-1:0]   data_in,
    output reg                     valid_out,
    output reg  [DATA_WIDTH-1:0]   data_out,
    input  wire                    ready_in
);

    reg [DATA_WIDTH-1:0] skid_data;
    reg                  skid_valid;

    // Aceita entrada enquanto o skid estiver livre
    assign ready_out = !skid_valid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_out  <= 1'b0;
            data_out   <= {DATA_WIDTH{1'b0}};
            skid_valid <= 1'b0;
            skid_data  <= {DATA_WIDTH{1'b0}};
        end else if (flush) begin
            valid_out  <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            // A saida pode receber dado novo se:
            //   - o downstream consumiu (valid_out && ready_in), OU
            //   - a saida ja esta vazia (!valid_out)
            if ((valid_out && ready_in) || !valid_out) begin
                if (skid_valid) begin
                    // promove o item mais antigo (skid) para a saida
                    data_out   <= skid_data;
                    valid_out  <= 1'b1;
                    skid_valid <= 1'b0;
                end else if (valid_in) begin
                    // carrega dado novo direto na saida (preserva ordem)
                    data_out  <= data_in;
                    valid_out <= 1'b1;
                end else begin
                    valid_out <= 1'b0;
                end
            end else begin
                // saida ocupada E travada: guarda 1 item no skid
                if (valid_in && ready_out) begin
                    skid_data  <= data_in;
                    skid_valid <= 1'b1;
                end
            end
        end
    end

endmodule
