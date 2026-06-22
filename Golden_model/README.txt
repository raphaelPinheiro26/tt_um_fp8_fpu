MODELO MATEMÁTICO — VERIFICAÇÃO FP8 E4M3 (especificação IEEE-like)
================================================================
Pasta: a referência agora é a ESPECIFICAÇÃO MATEMÁTICA (valor
exato em Fraction + exceções IEEE), não mais o espelho bit-accurate do
RTL. O modelo matemático foi verificado idêntico ao antigo golden do RTL
(fp8_golden_c2) nos 1.310.720 casos — 256 x 256 x 4 ops x 5 modos —
retornando a mesma tripla (result, flags, exc).

ARQUIVOS DO MODELO FP8 (3)
  fp8_common.py        base: codec FP8 E4M3 (unpack, valor exato Fraction).
  fp8_math.py          ESPECIFICAÇÃO: A op B em valor exato + exceções,
                       arredonda p/ FP8 nos 5 modos. (result, flags, exc).
  gen_vectors_math.py  gera vectors.hex de 7 colunas p/ tb_fp8_golden.v.

OUTROS
  vectors.hex          vetores gerados (7 colunas, 1.310.720 linhas).

DEPENDÊNCIAS
  fp8_math         <- fp8_common            (auto-contido)
  gen_vectors_math <- fp8_common, fp8_math
                      (fp8_golden_c2 só se usar --check; não está mais na pasta)

API DO MODELO
  fp8_math(A, B, opcode, rm) -> (result, flags, exc)
    opcode: 0=ADD 1=SUB 2=MULT 3=DIV
    rm    : 0=NEAR 1=ZERO 2=UP 3=DOWN 4=ODD
  Flags  (header_fp8.v): SNAN6 QNAN5 NAN4 INF3 NORMAL2 SUBNORMAL1 ZERO0
  Exceps (header_fp8.v): INVALID4 DIVZERO3 OVERFLOW2 UNDERFLOW1 INEXACT0

EXCEÇÕES TRATADAS (no nível de valor)
  INVALID  : Inf-Inf, 0/0, Inf*0, NaN de entrada (propaga operando, quiet).
  DIVZERO  : x/0 finito -> +-Inf.
  OVERFLOW : acima do maior finito -> Inf, conforme o modo (NEAREST/UP+/DOWN-);
             ZERO/ODD e o lado oposto de UP/DOWN saturam no maior finito.
  UNDERFLOW: valor != 0 que colapsa em zero ao arredondar.
  INEXACT  : resultado arredondado difere do valor exato.

GERAR VETORES (7 colunas: AA BB O R RES FF EE)
  python3 gen_vectors_math.py            # ADD/SUB/MULT/DIV, 5 modos
  python3 gen_vectors_math.py --rne      # só RM_NEAREST
  python3 gen_vectors_math.py --quick    # amostra (smoke test)
  python3 gen_vectors_math.py --no-div   # exclui DIV
  python3 gen_vectors_math.py --out X.hex
  python3 gen_vectors_math.py --check    # confere vs fp8_golden_c2 (se presente)

ESTADO: ADD/SUB/MULT/DIV = 0% de divergência entre a especificação
matemática e o golden do RTL nos 5 modos (1.310.720/1.310.720).
