# Setup de ponta a ponta (WSL2) — simulação → verificação → LibreLane → métricas

Guia único para levantar **todo** o fluxo deste projeto dentro de **um só
ambiente Linux (WSL2 Ubuntu)**: simulação (cocotb/Icarus), as trilhas de
verificação (`verification/`: formal, UVM, DFT), o hardening RTL→GDS
(LibreLane) e a **extração de métricas** (área, timing/Fmax, potência) para
caracterização — pensado para gerar números reprodutíveis para o doutorado.

> **Por que tudo no WSL2 e não no Windows nativo?** O OSS CAD Suite para Windows
> costuma dar dor de cabeça (PATH, permissões, GUIs). O LibreLane só roda em
> Linux+Docker de qualquer jeito. Manter **um** toolchain Linux elimina o
> "funciona na minha máquina" e é **exatamente** o que o CI (`.github/workflows`)
> executa. Você edita no VS Code (Windows) conectado ao WSL via Remote-WSL — a
> experiência é igual à nativa.
>
> Os dois guias antigos continuam válidos como referência: o
> [DEV_SETUP_WINDOWS.md](DEV_SETUP_WINDOWS.md) (simulação nativa no Windows, se um
> dia precisar) e o [LIBRELANE_LOCAL_WINDOWS.md](LIBRELANE_LOCAL_WINDOWS.md)
> (detalhe fino do hardening). Este documento é o caminho **recomendado** e os
> amarra em uma sequência só.

---

## Mapa mental para quem vem do Quartus

Você vinha do Quartus (FPGA Intel, GUI). Aqui o fluxo é **ASIC open-source, por
linha de comando**, mas os conceitos são os mesmos:

| Etapa | Quartus (FPGA) | Aqui (ASIC sky130, open-source) |
|-------|----------------|----------------------------------|
| Simulação | ModelSim/Questa | **Icarus Verilog + cocotb** (Python) |
| Síntese | Analysis & Synthesis | **Yosys** |
| Place & Route | Fitter | **OpenROAD** (floorplan/place/CTS/route) |
| Timing (STA) | TimeQuest | **OpenSTA** (mesmo conceito de *slack*) |
| Assinatura física | — | **Magic/KLayout** (GDS, DRC, LVS) |
| Orquestrador | GUI do Quartus | **LibreLane** (`tt_tool.py --harden`) |
| Saída | bitstream `.sof` | **GDSII** (`.gds`) |

Existe também um caminho de **protótipo em FPGA** neste repo
(`.github/workflows/fpga.yaml`), mas mirando um **Lattice iCE40UP5K** com
ferramentas open-source (Yosys + nextpnr) — não é o Quartus/Intel, mas serve se
quiser validar em silício programável antes.

---

## 1. WSL2 + Ubuntu

No **PowerShell como Administrador**:

```powershell
wsl --install -d Ubuntu-24.04
```

Reinicie, abra "Ubuntu" pelo menu Iniciar, crie usuário/senha. Confirme que é
WSL **2**:

```powershell
wsl -l -v
```

> Recomendo **Ubuntu 24.04**: traz um `yosys` mais novo no apt (o do 22.04 é a
> versão 0.9, de 2019, velha demais para as asserções SVA da trilha formal).

## 2. VS Code conectado ao WSL

Instale o VS Code no Windows e a extensão **WSL** (Remote - WSL). Dentro do
Ubuntu, na pasta do projeto, rode `code .` — o VS Code abre "preso" ao Linux,
com terminal, extensões e depuração todos no ambiente Linux.

## 3. Clonar o projeto DENTRO do WSL

Trabalhe no home do Linux (`~`), **não** em `/mnt/c/...` (é lento e dá problema
de permissão com o Docker):

```sh
cd ~
git clone https://github.com/<seu-usuario>/tt_um_fp8_fpu.git
cd tt_um_fp8_fpu
```

## 4. Toolchain base (simulação + UVM + DFT)

```sh
sudo apt update
sudo apt install -y iverilog gtkwave verilator make git python3 python3-pip python3-venv

# venv do projeto (isola as libs Python)
python3 -m venv ~/.venvs/fp8
source ~/.venvs/fp8/bin/activate

# dependências de simulação e de UVM
pip install -r test/requirements.txt              # cocotb, pytest
pip install -r verification/uvm/requirements.txt  # cocotb, pyuvm
```

Confirme:

```sh
iverilog -V | head -1
python3 -c "import cocotb, pyuvm; print('cocotb', cocotb.__version__, '| pyuvm', pyuvm.__version__)"
```

## 5. Rodar as simulações

**Suíte oficial (a que o Tiny Tapeout roda):**

```sh
cd test && make -B          # esperado: TESTS=6 PASS=6 FAIL=0
cd ..
```

**Testes de bloco (cocotb):**

```sh
cd sim/cocotb/pipeline && make      # replay dos golden vectors + back-pressure
cd ../unit && make                  # tiny_fp8_unit
cd ../../..
```

**UVM (pyuvm) — o testbench constrained-random do wrapper streaming:**

```sh
cd verification/uvm/pyuvm
make                        # Fp8SmokeTest (rápido)
make TEST=Fp8ArithTest      # ADD/SUB/MUL/DIV, todos os modos de arredondamento
make TEST=Fp8FullRandomTest # todos os 14 opcodes
cd ../../..
```

**DFT — demo de scan (iverilog):**

```sh
cd verification/dft
iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb
cd ../..
```

Formas de onda: os testes geram `.fst`/`.vcd`; abra com `gtkwave arquivo.fst`.

## 6. Verificação formal (Yosys + SymbiYosys)

O formal precisa de um Yosys recente + `sby` + um solver SMT. A forma mais
estável no WSL2 é o **OSS CAD Suite para Linux** (o bundle Linux é sólido — o
problemático é o do Windows):

```sh
cd ~
# baixe o release Linux x64 em:
#   https://github.com/YosysHQ/oss-cad-suite-build/releases
tar xzf oss-cad-suite-linux-x64-*.tgz
# ative quando for usar formal (ajusta o PATH da sessão):
source ~/oss-cad-suite/environment

cd ~/tt_um_fp8_fpu/verification/formal
./run.sh                    # roda todas as provas (.sby)
```

> Alternativa sem o bundle: no Ubuntu 24.04 dá para `sudo apt install -y yosys`
> (versão nova o suficiente) e instalar o `sby` a partir do repositório
> `YosysHQ/sby`. O OSS CAD Suite é o caminho mais direto porque já traz
> `yosys`, `sby` e os solvers (`yices`, `boolector`) juntos.

Detalhes de cada prova estão em [`verification/formal/README.md`](../verification/formal/README.md).

## 7. Hardening RTL→GDS (LibreLane) + Docker

Esta é a parte "Fitter + TimeQuest + GDS" do fluxo. O passo a passo detalhado
já está em [LIBRELANE_LOCAL_WINDOWS.md](LIBRELANE_LOCAL_WINDOWS.md); em resumo:

```sh
# Docker: instale o Docker Desktop (Windows) com integração WSL2 para a distro
# Ubuntu, OU o docker engine dentro do WSL. Teste:  docker run --rm hello-world

cd ~/tt_um_fp8_fpu
git clone https://github.com/TinyTapeout/tt-support-tools tt

source ~/.venvs/fp8/bin/activate
pip install -r tt/requirements.txt
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A LIBRELANE_TAG=3.0.3
pip install librelane==$LIBRELANE_TAG

./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden          # lint (Verilator) + Yosys + OpenROAD + OpenSTA
```

Resultados em `runs/wokwi/` (GDS em `final/gds/`, netlist em `final/pnl/`, e os
`metrics.json`/relatórios de STA nas pastas de step). O primeiro `--harden`
baixa o PDK (alguns GB); os próximos são rápidos.

## 8. Métricas para o doutorado

Depois de um `--harden`, dois scripts (só stdlib do Python, sem dependências)
em [`flow/`](../flow/) consolidam os números:

**Tabela de um run (área + células + timing + potência + Fmax estimado):**

```sh
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8
# imprime a tabela e grava flow/reports/fp8.csv e .md
```

Ele mescla os `metrics.json` cumulativos, extrai os campos que interessam
(instâncias, área de célula/die/core, utilização, *setup/hold slack*, potência
dinâmica/leakage, DRC/LVS) e **estima o Fmax** = 1000 / (período − *setup
slack*) MHz.

**Fmax real (varredura de CLOCK_PERIOD):**

```sh
# cada ponto re-roda o --harden (minutos); mantenha a lista curta
python3 flow/sweep_clock.py --periods 40,30,25,20,16,13 --out flow/reports/sweep
```

Ele varia o `CLOCK_PERIOD` no `src/config.json` (fazendo backup e **sempre**
restaurando o original), re-hardeniza em cada período e reporta o menor período
que ainda fecha timing → o Fmax caracterizado, com CSV para a tese.

> **Sobre potência:** o `power__total` do STA usa taxas de chaveamento padrão.
> Para potência dinâmica realista, gere um VCD/SAIF de uma simulação
> representativa (p.ex. o `test/` com dump ligado) e alimente o STA — veja o
> `flow/README.md`.

Guia detalhado dos scripts e das chaves do `metrics.json`:
[`flow/README.md`](../flow/README.md).

---

## Resumo dos comandos

| Objetivo | Comando |
|----------|---------|
| Suíte oficial | `cd test && make -B` |
| UVM (constrained-random) | `cd verification/uvm/pyuvm && make TEST=Fp8FullRandomTest` |
| Formal | `source ~/oss-cad-suite/environment && cd verification/formal && ./run.sh` |
| DFT (scan) | `cd verification/dft && iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb` |
| Inventário de flops (DFT) | `cd verification/dft && yosys scan_insert.ys` |
| Hardening RTL→GDS | `./tt/tt_tool.py --harden` |
| Tabela de métricas | `python3 flow/collect_metrics.py --out flow/reports/fp8` |
| Varredura de Fmax | `python3 flow/sweep_clock.py --periods 40,30,20,15` |

Tudo isso é o que o CI (`.github/workflows/{test,formal,uvm,gds}.yaml`) roda na
nuvem — localmente você tem o mesmo, com iteração rápida.
