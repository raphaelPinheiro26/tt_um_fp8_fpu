# Subir o projeto no GitHub

O repositório git local já está inicializado, com `.gitignore` revisado e o
commit inicial feito na branch **`main`**. Falta só criar o repositório remoto
e dar push — isso precisa da sua conta/autenticação, então rode você mesmo.

## Opção A — GitHub CLI (mais rápido)

Se você tem o [GitHub CLI](https://cli.github.com/) instalado:

```powershell
gh auth login          # só na primeira vez
gh repo create tt_um_fp8_fpu --public --source=. --remote=origin --push
```

Isso cria o repositório `tt_um_fp8_fpu` na sua conta e já envia a branch `main`.
Troque `--public` por `--private` se preferir privado.

## Opção B — Manual (pelo site)

1. Crie um repositório **vazio** em <https://github.com/new>:
   - nome: `tt_um_fp8_fpu`
   - **não** marque "Add a README", `.gitignore` nem license (o projeto já tem).
2. Ligue o remoto e envie (troque `SEU-USUARIO`):

```powershell
git remote add origin https://github.com/SEU-USUARIO/tt_um_fp8_fpu.git
git push -u origin main
```

## Depois do push

Este é um projeto Tiny Tapeout: os workflows em `.github/workflows/`
(`test`, `gds`, `fpga`, `docs`) rodam automaticamente no GitHub Actions a cada
push. Confira a aba **Actions** do repositório para ver a simulação e o
hardening rodando na nuvem.

## Fluxo contínuo daqui pra frente

```powershell
git add -A
git commit -m "mensagem descritiva"
git push
```
