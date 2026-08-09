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
# 1) BAIXE primeiro o release Linux x64 (o passo que faltava!). Abra
#    https://github.com/YosysHQ/oss-cad-suite-build/releases e copie o link do
#    asset mais novo "oss-cad-suite-linux-x64-AAAAMMDD.tgz", ex.:
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2025-08-01/oss-cad-suite-linux-x64-20250801.tgz
#    (troque a data pela do release atual; se o wget der 404, o link mudou —
#     pegue o nome exato na página de Releases.)

# 2) extraia (agora o arquivo existe, então o tar funciona):
tar xzf oss-cad-suite-linux-x64-*.tgz

# 3) ative (ajusta o PATH da sessão; rode toda vez que for usar formal):
source ~/oss-cad-suite/environment

# 4) rode as provas:
cd ~/tt_um_fp8_fpu/verification/formal
./run.sh                    # roda todas as provas (.sby)
```

> **O erro `tar: Cannot open: No such file or directory`** que você viu é só
> isto: o `tar xzf oss-cad-suite-*.tgz` foi rodado **antes** de baixar o
> arquivo. Faça o passo 1 (wget/download) primeiro.

> Alternativa sem o bundle: no Ubuntu 24.04 dá para `sudo apt install -y yosys`
> (versão nova o suficiente) e instalar o `sby` a partir do repositório
> `YosysHQ/sby`. O OSS CAD Suite é o caminho mais direto porque já traz
> `yosys`, `sby` e os solvers (`yices`, `boolector`) juntos.

Detalhes de cada prova estão em [`verification/formal/README.md`](../verification/formal/README.md).

## 7. Hardening RTL→GDS (LibreLane) + Docker

Esta é a parte "Fitter + TimeQuest + GDS" do fluxo: transformar o Verilog em um
layout físico (GDSII) e medir timing/área. As ferramentas (Yosys, OpenROAD,
OpenSTA…) rodam dentro de **contêineres Docker**, então o LibreLane baixa e
executa essas imagens pra você — você não instala cada ferramenta na mão.

> Reserve **10–15 GB** de disco e uma boa conexão: o primeiro run baixa o PDK
> (o "kit" do processo sky130, alguns GB) e as imagens Docker. Os runs seguintes
> reaproveitam tudo e são rápidos.

### 7.1 Instalar o Docker Engine dentro do WSL (sem Docker Desktop)

**O que é Docker?** Um jeito de rodar programas dentro de "caixas" isoladas
(contêineres) já com tudo que eles precisam. O LibreLane usa isso pra garantir
que as ferramentas rodem igualzinho na sua máquina e no CI.

Aqui vamos instalar o Docker **direto no Ubuntu do WSL** (não precisa do Docker
Desktop no Windows). Tudo roda dentro do terminal do Ubuntu.

**1) Instalar o pacote** (a versão do Ubuntu já serve):

```sh
sudo apt update
sudo apt install -y docker.io
```

**2) Rodar sem `sudo`** — adicione seu usuário ao grupo `docker` uma vez:

```sh
sudo usermod -aG docker $USER
```

**3) Ligar o serviço do Docker.** O WSL não liga serviços sozinho por padrão.
Duas opções — escolha **uma**:

- **A (recomendada, fica ligado sempre): ativar o systemd no WSL.** Edite/crie
  o arquivo `/etc/wsl.conf`:

  ```sh
  sudo tee /etc/wsl.conf > /dev/null <<'EOF'
  [boot]
  systemd=true
  EOF
  ```

  Depois, **no PowerShell do Windows**, reinicie o WSL:

  ```powershell
  wsl --shutdown
  ```

  Reabra o Ubuntu e habilite o Docker de vez:

  ```sh
  sudo systemctl enable --now docker
  ```

- **B (simples, sem systemd): ligar na mão a cada sessão.** Sempre que abrir o
  WSL e for usar o Docker, rode:

  ```sh
  sudo service docker start
  ```

**4) Reabra o terminal** (pra valer a mudança do grupo `docker` do passo 2) e
**teste**:

```sh
docker run --rm hello-world
```

Deu certo se aparecer **"Hello from Docker!"**.

> **Erros comuns:**
> - `Cannot connect to the Docker daemon` → o serviço não está ligado: rode
>   `sudo service docker start` (ou confira o passo 3A).
> - `permission denied ... /var/run/docker.sock` → você não reabriu o terminal
>   depois do `usermod` (passo 2). Feche e reabra o WSL, ou rode `newgrp docker`.

### 7.2 Baixar o tt-support-tools e instalar o LibreLane

O `tt-support-tools` é o script oficial do Tiny Tapeout que monta a configuração
certa (tamanho da tile, pinos de power, wrapper `tt_um_*`, PDK) e chama o
LibreLane. **Não** commite ele — já está no `.gitignore` (a `tt-gds-action` do
CI clona sozinha).

```sh
cd ~/tt_um_fp8_fpu

# 1) clona a ferramenta do TT dentro da pasta tt/
git clone https://github.com/TinyTapeout/tt-support-tools tt

# 2) ativa o mesmo venv da seção 4 e instala as dependências dela
source ~/.venvs/fp8/bin/activate
pip install -r tt/requirements.txt

# 3) define o PDK e a versão do LibreLane (valores do shuttle ttsky26c)
export PDK_ROOT=~/ttsetup/pdk
export PDK=sky130A
export LIBRELANE_TAG=3.0.3
pip install librelane==$LIBRELANE_TAG
```

> Guarde esses 3 `export` — você precisa deles **toda vez** que abrir um terminal
> novo pra hardenizar. (Dá pra colar no `~/.bashrc` se quiser que fiquem fixos.)

### 7.3 Rodar o hardening

```sh
./tt/tt_tool.py --create-user-config   # gera a config a partir do info.yaml
./tt/tt_tool.py --harden               # roda o fluxo completo (usa o Docker)
```

O `--harden` faz, em sequência: **lint** (Verilator, compila o RTL), **síntese**
(Yosys), floorplan → placement → CTS → rota (OpenROAD) e o **STA** (OpenSTA).
Se o Verilog não compilar ou tiver violação de timing, ele reclama aqui. O
primeiro run demora (baixa PDK + imagens); os próximos são rápidos.

Depois, um resumo rápido:

```sh
./tt/tt_tool.py --print-warnings
./tt/tt_tool.py --print-stats
```

### 7.4 Onde ficam os resultados

Tudo cai em `runs/wokwi/` (pasta ignorada pelo git):

- **GDS final:** `runs/wokwi/final/gds/`
- **Netlist pós-PnR:** `runs/wokwi/final/pnl/tt_um_fp8_fpu.pnl.v`
- **Lint do Verilog:** `runs/wokwi/*-verilator-lint/verilator-lint.log`
- **STA / timing + `metrics.json`:** nas pastas de step (ex.: `*-openroad-*sta*`)

A seção 8 mostra como transformar esses `metrics.json` numa tabela pronta.

### 7.5 Trocar de PDK (leia o aviso!)

> ⚠️ **Para submeter ao Tiny Tapeout, o PDK é FIXO pelo shuttle** — o `ttsky26c`
> exige `sky130A`. Não troque o PDK do fluxo do TT, senão a submissão não vale.
> A troca abaixo é só para **experimentos seus** (ex.: comparar processos na
> tese), rodando o LibreLane fora do fluxo do TT.

O PDK é escolhido pela variável de ambiente `PDK` (e baixado para `PDK_ROOT`
pela ferramenta `ciel`). PDKs open-source comuns:

| PDK | Processo | Uso |
|-----|----------|-----|
| `sky130A` | SkyWater 130 nm (1.8 V) | **o do TT (ttsky26c)** |
| `sky130B` | SkyWater 130 nm (variante) | experimentos |
| `gf180mcuD` | GlobalFoundries 180 nm | experimentos |

Para um experimento próprio (LibreLane direto, sem o `tt_tool.py`), você aponta
o PDK na config do LibreLane ou via env e roda o `librelane` com o
`src/config.json` adaptado. Como isso sai do fluxo oficial do TT, deixei como
tópico avançado — se quiser seguir por aí para a tese, me chama que a gente monta
uma config de comparação de PDKs separada, sem mexer no que vai pro TT.

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