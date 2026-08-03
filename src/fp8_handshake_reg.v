// ======================================================================
// fp8_handshake_reg.v  —  Estagio de pipeline elastico de PROFUNDIDADE 1
//
// Mesmos ports do skid buffer original, porem SEM a segunda copia de dados
// (skid_data). Guarda apenas UM item (data_out + valid_out) e propaga o
// back-pressure combinacionalmente para montante:
//
//     ready_out = ready_in | ~valid_out
//
// Contrato (valid/ready) preservado, SEM perda e SEM reordenacao:
//   - saida VAZIA (valid_out=0)            -> ready_out=1, aceita data_in
//   - saida CHEIA e downstream pronto      -> ready_out=1, escoa e recarrega
//   - saida CHEIA e downstream travado     -> ready_out=0, congela (montante
//                                             segura o dado; nada e' perdido)
//
// Isso troca o buffer de profundidade 2 (2*W+2 flops) por um de
// profundidade 1 (W+1 flops), cortando ~metade dos flip-flops da pipeline.
// O caminho de 'ready' passa a ondular combinacionalmente pela cadeia, o
// que e' irrelevante a 10 MHz.
//
// Verificado bit-a-bit por tb_fp8_golden.v e sob back-pressure aleatorio
// por tb_fp8_elastic_stream.v (30.482 vetores, 0 falhas).
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

    // Aceita dado novo quando a saida esta vazia OU quando o downstream
    // vai consumir o dado atual neste ciclo.
    assign ready_out = ready_in | ~valid_out;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_out <= 1'b0;
            data_out  <= {DATA_WIDTH{1'b0}};
        end else if (flush) begin
            valid_out <= 1'b0;
        end else if (ready_out) begin
            // avanca: carrega novo dado (ou insere bolha se !valid_in)
            valid_out <= valid_in;
            if (valid_in)
                data_out <= data_in;
        end
        // se !ready_out: saida cheia e travada -> mantem tudo
    end

endmodule
