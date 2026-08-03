# Ambiente de desenvolvimento — VS Code no Windows

Guia para simular e desenvolver a FPU FP8 E4M3 direto no VS Code (Windows nativo,
sem WSL). O fluxo usa **Icarus Verilog** (simulador), **cocotb** (testbench em
Python) e **GTKWave** (formas de onda).

## 1. Python

Instale o Python 3.10+ de <https://www.python.org/downloads/windows/>.
Na primeira tela do instalador, marque **"Add python.exe to PATH"**.

Confirme no PowerShell:

```powershell
python --version
```

## 2. Toolchain de HDL (Icarus + GTKWave + make)

A forma mais simples de ter tudo de uma vez no Windows é o **OSS CAD Suite**
(YosysHQ), que já traz `iverilog`, `vvp`, `gtkwave` e `make`:

1. Baixe o pacote Windows em
   <https://github.com/YosysHQ/oss-cad-suite-build/releases> (arquivo
   `oss-cad-suite-windows-x64-*.exe` ou `.tgz`).
2. Extraia para uma pasta sem espaços, por ex. `C:\tools\oss-cad-suite`.
3. Adicione `C:\tools\oss-cad-suite\bin` ao **PATH** do usuário
   (Configurações → "Editar variáveis de ambiente" → Path → Novo).

Alternativa mínima (só Icarus + GTKWave, sem `make`): instalador do Icarus em
<https://bleyer.org/icarus/> e o GTKWave. Nesse caso use o `runner.py`
(passo 5), que **não** precisa do `make`.

Confirme (abra um terminal novo para o PATH atualizar):

```powershell
iverilog -V
gtkwave --version
```

## 3. Dependências Python (cocotb)

Na raiz do projeto:

```powershell
pip install -r test/requirements.txt
```

Isso instala `cocotb==2.0.1` e `pytest==8.4.2`.

## 4. Extensões do VS Code

Abra a pasta do projeto no VS Code. Ele vai sugerir as extensões listadas em
`.vscode/extensions.json` (Verilog HDL, Python, Pylance, WaveTrace) — clique em
**Instalar**. O realce, o lint por Icarus e o IntelliSense de Python já vêm
configurados em `.vscode/settings.json`.

## 5. Rodar a simulação

Duas opções (as duas rodam a suíte cocotb completa em `test/test.py`):

**a) Pela paleta de tarefas (recomendado)** — `Ctrl+Shift+P` →
*Tasks: Run Task* → **"FP8: rodar simulacao (runner.py)"**.
Essa tarefa é a padrão de teste, então `Ctrl+Shift+B` também dispara.

**b) Pelo terminal:**

```powershell
cd test
python runner.py          # não precisa de make (ideal no Windows)
# ou, se você instalou make:
make -B
```

Saída esperada ao final: `TESTS=6 PASS=6 FAIL=0`.

## 6. Ver as formas de onda

Depois de simular, a tarefa **"FP8: ver waveform (GTKWave)"** abre
`test/tb.fst` com o layout salvo (`tb.gtkw`). Pelo terminal:

```powershell
cd test
gtkwave tb.fst tb.gtkw
```

## 7. Regenerar os vetores golden (opcional)

O `test/test.py` confere o RTL contra `Golden_model/vectors.hex`. Para
regenerar um subconjunto rápido use a tarefa
**"FP8: gerar vetores golden (quick)"** ou:

```powershell
cd Golden_model
python gen_vectors_math.py --quick
```

## Fluxo de desenvolvimento contínuo

1. Edite o RTL em `src/` ou o modelo em `Golden_model/`.
2. `Ctrl+Shift+B` para rodar a simulação.
3. Inspecione falhas no terminal e as formas de onda no GTKWave.
4. Commit + push (veja `docs/GITHUB_SETUP.md`).

> Dica: o `runner.py` espelha exatamente o `test/Makefile` (mesmas fontes,
> mesmo `-I src` para achar `header_fp8.v`, mesmo toplevel `tb`). Use o que for
> mais conveniente.
