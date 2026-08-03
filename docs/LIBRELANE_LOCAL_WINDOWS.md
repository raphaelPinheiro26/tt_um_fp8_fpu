# Hardening local com LibreLane no Windows (WSL2 + Docker)

Guia para rodar o fluxo RTL→GDS do Tiny Tapeout **localmente**, incluindo o que
você pediu: **lint/compilação do Verilog** (Verilator), **síntese** (Yosys) e
**STA / análise de timing** (OpenSTA). Tudo isso faz parte de um único comando
`tt_tool.py --harden`.

O fluxo do LibreLane roda em Linux + Docker, então no Windows a gente usa o
**WSL2** (Ubuntu). Isso espelha exatamente o que o workflow `gds.yaml` faz na
nuvem — mesma versão de LibreLane (**3.0.3**) e mesmo PDK (**sky130A**), do
shuttle **ttsky26c**.

> Só faça isso se quiser iterar timing/síntese localmente. Para submeter, o
> push no GitHub já roda tudo na aba **Actions** sem instalar nada.

---

## 0. Pré-requisitos de espaço/tempo

O primeiro `--harden` baixa o PDK sky130 (alguns GB) e imagens Docker. Reserve
uns **10–15 GB** livres e uma boa conexão. As execuções seguintes são rápidas.

## 1. Instalar o WSL2 + Ubuntu

No **PowerShell como Administrador**:

```powershell
wsl --install
```

Isso instala o WSL2 com o Ubuntu. **Reinicie** o Windows, abra o "Ubuntu" pelo
menu Iniciar e crie seu usuário/senha do Linux na primeira vez.

Confira a versão (tem que ser WSL **2**):

```powershell
wsl -l -v
```

## 2. Instalar o Docker

Mais simples: **Docker Desktop para Windows** (https://www.docker.com/products/docker-desktop/).
Na instalação, deixe marcado o backend **WSL2**; depois, em
*Settings → Resources → WSL integration*, ative a integração para a distro
**Ubuntu**.

Teste dentro do Ubuntu (WSL):

```sh
docker run --rm hello-world
```

Se imprimir a mensagem de boas-vindas do Docker, está pronto.

## 3. Trabalhar dentro do sistema de arquivos do WSL

**Importante:** trabalhe no home do Linux (`~`), **não** em `/mnt/c/...`. O
Docker fica muito mais rápido e evita problemas de permissão. Como o projeto já
vai estar no GitHub, clone-o para dentro do WSL (troque a URL pela sua):

```sh
cd ~
git clone https://github.com/raphaelPinheiro26/tt_um_fp8_fpu.git
cd tt_um_fp8_fpu
```

## 4. Clonar o tt-support-tools

Ele monta a config completa do LibreLane (die da tile, power pins, wrapper
`tt_um_*`, PDK). Clone dentro da pasta `tt/` do projeto:

```sh
git clone https://github.com/TinyTapeout/tt-support-tools tt
```

## 5. Ambiente Python (venv) e dependências

```sh
sudo apt update && sudo apt install -y python3-venv python3-pip
mkdir -p ~/ttsetup
python3 -m venv ~/ttsetup/venv
source ~/ttsetup/venv/bin/activate
pip install -r tt/requirements.txt
```

## 6. Variáveis de ambiente + LibreLane

```sh
export PDK_ROOT=~/ttsetup/pdk
export PDK=sky130A
export LIBRELANE_TAG=3.0.3
pip install librelane==$LIBRELANE_TAG
```

(Esses valores são os do shuttle ttsky26c. Se um dia mudar, o valor oficial está
no `librelane-version` do `tt-gds-action`.)

## 7. Hardening (síntese + PnR + STA)

Gere a config e rode o fluxo (precisa do Docker rodando):

```sh
./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden
```

Esse `--harden` faz, em sequência: **lint com Verilator** (compila o RTL),
**síntese com Yosys**, floorplan, placement, CTS, rota (OpenROAD) e o **STA**
com OpenSTA. Se o Verilog não compilar ou tiver violação de timing, ele
reclama aqui.

Depois, veja os avisos e o resumo (timing/rota):

```sh
./tt/tt_tool.py --print-warnings
./tt/tt_tool.py --print-stats
```

## 8. Onde estão os resultados (incluindo o STA)

Tudo cai em `runs/wokwi/`:

- **Lint do Verilog:** `runs/wokwi/*-verilator-lint/verilator-lint.log`
- **STA / timing:** procure as pastas de step `*-openroad-*sta*` e o signoff em
  `runs/wokwi/`; os `.rpt`/`.log` de lá trazem *setup/hold slack*. O resumo
  rápido sai no `--print-stats`.
- **Netlist gate-level:** `runs/wokwi/final/pnl/tt_um_fp8_fpu.pnl.v`
- **GDS final:** `runs/wokwi/final/gds/`

### Só quer o "compila o Verilog + STA", sem GDS completo?

O `--harden` é o caminho oficial e já cobre lint + síntese + STA. Não há um
sub-passo isolado no `tt_tool.py`, mas os artefatos acima (log do Verilator e
relatórios de STA) são gerados no meio do processo — mesmo que você interrompa
depois do timing, eles já estarão em `runs/wokwi/`.

## 9. Teste gate-level (opcional, valida o netlist pós-síntese)

Depois de hardenizar, dá pra rodar os mesmos testes cocotb contra o netlist
já sintetizado:

```sh
cd test
pip install -r requirements.txt
TOP_MODULE=$(cd .. && ./tt/tt_tool.py --print-top-module)
cp ../runs/wokwi/final/pnl/$TOP_MODULE.pnl.v gate_level_netlist.v
make -B GATES=yes
cd ..
```

Se reclamar de um `primitives.v` do PDK faltando, rode `ciel ls`, copie o hash
listado e faça `ciel enable <hash>`; depois repita o comando acima.

## Rehardening (depois de mexer no RTL)

Sempre reative o ambiente antes:

```sh
source ~/ttsetup/venv/bin/activate
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A LIBRELANE_TAG=3.0.3
./tt/tt_tool.py --harden
```

## Ver o layout (opcional)

```sh
./tt/tt_tool.py --open-in-openroad     # GUI do OpenROAD
./tt/tt_tool.py --open-in-klayout      # KLayout
```

Se der erro de display (`could not connect to display`), rode antes
`xhost +local:docker` (WSL recente já traz suporte a GUI via WSLg).

---

### Resumo

- Compila o Verilog e os TBs → o setup Icarus/cocotb que você já tem
  (`test/runner.py`) já faz. O `--harden` adiciona o lint do **Verilator**.
- Síntese + **STA** + GDS → `./tt/tt_tool.py --harden` (aqui, no WSL) **ou** o
  push no GitHub (aba Actions), que roda idêntico na nuvem.
