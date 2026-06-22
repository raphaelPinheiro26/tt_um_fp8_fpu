# tt_um_fp8_fpu — Protocolo de pinos (streaming)

Este documento descreve, ciclo a ciclo, como conversar com o wrapper
`tt_um_fp8_fpu` pela interface de pinos do Tiny Tapeout. O wrapper expõe o
core elástico `tiny_fp8_unit` (FP8 E4M3: add/sub/mul/div, 5 modos de
arredondamento) como dois canais independentes com handshake `valid/ready`,
permitindo manter **várias operações em voo** (pipeline cheia).

Tudo é síncrono ao `clk`. No Tiny Tapeout o `clk`, o `rst_n` e os pinos são
dirigidos por um host externo (o RP2040 da placa de demonstração, ou um
ESP32/STM32 numa PCB própria).

---

## 1. Mapa de pinos

| Pino        | Dir | Nome        | Função |
|-------------|-----|-------------|--------|
| `ui_in[7:0]`  | in  | DATA_IN     | fluxo de bytes de entrada (A, depois B, depois CTRL) |
| `uo_out[7:0]` | out | DATA_OUT    | fluxo de bytes de saída (result, [flags, exceptions]) |
| `uio_in[0]`   | in  | IN_VALID    | host afirma quando `ui_in` tem um byte válido |
| `uio_out[1]`  | out | IN_READY    | core pode aceitar um byte neste ciclo |
| `uio_out[2]`  | out | OUT_VALID   | `uo_out` tem um byte de resultado válido |
| `uio_in[3]`   | in  | OUT_READY   | host consumiu o byte atual de `uo_out` |
| `uio_in[4]`   | in  | STICKY_CTRL | reusa o último `{rm,opcode}`; NÃO envia o byte CTRL |
| `uio_in[5]`   | in  | STICKY_B    | reusa o último operando B; NÃO envia o byte B |
| `uio_in[6]`   | in  | READ_FULL   | saída de 3 bytes/op (result,flags,exc) em vez de 1 |
| `uio_out[7]`  | out | FPU_BUSY    | flag de ocupado do core (observabilidade) |
| `clk`         | in  | —           | clock (host controla a frequência / passo) |
| `rst_n`       | in  | —           | reset, ativo em BAIXO |
| `ena`         | in  | —           | 1 enquanto o design está energizado (não usado) |

`uio_oe = 8'b1000_0110` → apenas `uio[7]`, `uio[2]` e `uio[1]` são saídas; o
restante são entradas.

**CTRL byte:** `{ rm = ui_in[7:5], opcode = ui_in[4:0] }`.
Opcodes: `ADD=0, SUB=1, MULT=2, DIV=3`. Modos rm: `NEAR=0, ZERO=1, UP=2,
DOWN=3, ODD=4`.

**FP8 E4M3** (ver `header_fp8.v`): bit7 = sinal, bits6:3 = expoente (bias 7),
bits2:0 = mantissa. Ex.: `1.0 = 0x38`, `2.0 = 0x40`.

---

## 2. Handshake valid/ready (regra de ouro)

Uma transferência acontece na **borda de subida do `clk`** em que `valid` e
`ready` estão ambos em 1. É o handshake clássico, à prova de skid:

- **Entrada:** o byte em `ui_in` é aceito quando `IN_VALID & IN_READY`.
- **Saída:** o byte em `uo_out` é consumido quando `OUT_VALID & OUT_READY`.

O host deve amostrar `IN_READY`/`OUT_VALID` (saídas do chip) e só então
decidir. Como o host gera o `clk`, ele tem controle total do ritmo.

---

## 3. Sequência de uma operação

### Entrada (por operação)
A ordem dos bytes é **A → B → CTRL**, mas B e/ou CTRL são pulados conforme os
bits sticky:

```
in_needed = 1 + (STICKY_B ? 0 : 1) + (STICKY_CTRL ? 0 : 1)   // 1..3 bytes
```

- `STICKY_*` ambos 0 → envia 3 bytes: A, B, CTRL.
- `STICKY_CTRL=1` → envia 2 bytes: A, B (reusa rm/opcode anteriores).
- `STICKY_B=1, STICKY_CTRL=1` → envia 1 byte: A (reusa B e rm/opcode).

O **último byte** de cada operação dispara o issue **no mesmo ciclo** em que
chega (o core lê o campo "vivo" direto de `ui_in`). Por isso o II em regime é
igual a `in_needed` (ver §5).

### Saída (por resultado)
```
out_needed = READ_FULL ? 3 : 1
```
- `READ_FULL=0` → 1 byte: result.
- `READ_FULL=1` → 3 bytes: result, depois `{1'b0,flags[6:0]}`, depois
  `{3'b0,exceptions[4:0]}`.

Os resultados saem **na mesma ordem** em que as operações entraram.

---

## 4. Modos sticky — como inicializar

Os registradores de B e de `{rm,opcode}` guardam o último valor enviado.
Para usar sticky:

1. Envie **uma operação completa** com `STICKY_B=0` e `STICKY_CTRL=0`
   (carrega B e CTRL nos registradores).
2. Levante os bits sticky desejados.
3. As próximas operações omitem os bytes sticky e reusam os valores.

**Restrição:** mantenha `STICKY_*` e `READ_FULL` **estáveis durante os bytes
de uma mesma operação**; mude-os apenas entre operações (no limite de op).

Casos de uso:
- `STICKY_CTRL` — benchmark de um único tipo de operação (o normal ao medir).
- `STICKY_B` — "A op constante" (ex.: escalar um stream por um fator fixo).

---

## 5. Throughput e latência (o que medir)

Com o host sempre alimentando (`IN_VALID=1` enquanto `IN_READY=1`) e sempre
drenando (`OUT_READY=1`), o **initiation interval** em regime é:

```
II  ≈ max(in_needed, out_needed)   ciclos/operação
```

Validado no modelo ciclo-a-ciclo do protocolo:

| Modo                              | in/out bytes | II medido |
|-----------------------------------|--------------|-----------|
| full (sem sticky, READ_FULL=1)    | 3 / 3        | 3.0       |
| STICKY_CTRL, result-only          | 2 / 1        | 2.0       |
| STICKY_CTRL + STICKY_B, result-only | 1 / 1      | 1.0       |

**Latência** = ciclos do issue de uma operação até `OUT_VALID` subir para o
resultado dela (profundidade da pipeline). Mede-se enviando 1 operação e
contando bordas de `clk` até `OUT_VALID`.

**Speedup da pipeline** = mesma placa, duas políticas do host:
- *blocking* (insere-e-espera): envia op, espera o resultado, envia a próxima
  → ~ `N × latência` ciclos para N ops.
- *streaming*: alimenta contínuo → ~ `N × II + latência` ciclos.
- speedup ≈ `latência / II`.

**ops/segundo** no silício = `fmax / II`, onde `fmax` vem da assinatura
estática (STA/LibreLane), não da medição com o host.

### Como contar ciclos sem hardware extra
O host **gera** o `clk` (passo a passo ou por timer), então conta as bordas
que produziu — contagem exata, sem contador on-chip. No firmware MicroPython
da placa TT dá pra avançar o clock por software e contar.

---

## 6. Exemplos de temporização

### Operação completa, lendo só o result (`STICKY_CTRL=1`, `READ_FULL=0`)
Pré-condição: uma op completa já carregou rm/opcode.

```
ciclo │ ui_in │ IN_VALID IN_READY │ uo_out  OUT_VALID OUT_READY │ nota
------┼-------┼-------------------┼-----------------------------┼-----------------
  0   │  A0   │    1       1      │   --        0        1      │ aceita A0
  1   │  B0   │    1       1      │   --        0        1      │ B0 = último → issue op0
  2   │  A1   │    1       1      │   --        0        1      │ aceita A1
  3   │  B1   │    1       1      │   --        0        1      │ issue op1
 ...  │       │                   │  res0       1        1      │ result0 sai (após latência)
```
Em regime: 2 bytes de entrada por op (II=2), resultados drenando 1/op em
paralelo no barramento de saída.

### Melhor caso (`STICKY_CTRL=1`, `STICKY_B=1`, `READ_FULL=0`)
1 byte (A) por operação, 1 byte (result) por resultado → **II = 1 op/ciclo**
quando a pipeline está cheia.

---

## 7. Reset e seleção do design (Tiny Tapeout)

1. Selecione o design no multiplexer do TT (pulsar `ctrl_sel_rst_n` e
   `ctrl_sel_inc` até o endereço do projeto) — feito pela API/firmware do TT.
2. Pulse `rst_n` em BAIXO por alguns ciclos, depois solte.
3. Após o reset: `in_count=0`, `out_busy=0`. Mantenha `STICKY_*=0` na primeira
   operação para inicializar B/CTRL.

---

## 8. Resumo das amarrações internas (standalone no chip)

| Sinal do core | Valor no wrapper |
|---------------|------------------|
| `issue_rd`    | `0` (sem banco de registradores no chip) |
| `wb_rd`       | ignorado |
| `flush`       | `0` (nunca) |
| `wb_ready`    | gerado pelo serializer de saída (backpressure real) |

`wb_ready` cair (host lento drenando) propaga backpressure para a pipeline e,
por fim, derruba `IN_READY` — controle de fluxo elástico fim-a-fim.
