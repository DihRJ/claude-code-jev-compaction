# Claude Code + Jev: compactação de contexto por relevância

**Português** · [English](README.md)

Tutorial prático para colocar um gateway LiteLLM entre o Claude Code e a API da
Anthropic, usando o modelo **Jev** (TypeSafe AI) para apagar resultados de
ferramenta que já não servem para a tarefa atual, antes que eles cheguem ao
modelo caro.

Escrito em português porque praticamente não existe material sobre isso em PT-BR.

---

## O problema

Em sessão longa de agente, o histórico acumula resultados de ferramenta que já
não servem para nada: um arquivo lido há dez turnos, uma busca que não deu em
nada, um grep de um caminho abandonado.

Esse lixo continua sendo enviado como tokens de entrada em **toda** requisição
seguinte. Você paga de novo, a cada turno, por informação morta.

## A solução

O Jev é um modelo que lê texto mas nunca escreve texto de volta. Ele recebe um
estado e devolve decisões tipadas com probabilidade calibrada.

Como guardrail do LiteLLM, ele avalia cada tool exchange concluído e responde uma
pergunta binária: **isso ainda é necessário para completar a tarefa atual?**

O que fica abaixo do limiar é substituído por um aviso de remoção. O corte é
tudo ou nada por bloco: um resultado é mantido na íntegra ou apagado. Nada é
resumido nem parafraseado, então o que sobrevive continua auditável.

```
Claude Code  ->  LiteLLM (localhost:4000)  ->  API da Anthropic
                       |
                       v
                  API do Jev
            (decide o que cortar)
```

---

## Pré-requisitos

- macOS ou Linux com Python 3.10 ou superior
- Chave da API da Anthropic
- Chave da TypeSafe AI (acesso ao Jev)
- Claude Code instalado

---

## Passo 1: instalar o LiteLLM

> **Atenção:** o guardrail `typesafe` ainda não existe na versão estável.
> O `--pre` é obrigatório.

```bash
mkdir -p ~/litellm-jev && cd ~/litellm-jev
python3 -m venv .venv
source .venv/bin/activate
pip install --pre -U 'litellm[proxy]'
```

Confirme que o guardrail veio junto:

```bash
ls .venv/lib/python3.*/site-packages/litellm/proxy/guardrails/guardrail_hooks/ | grep -i typesafe
```

Se não imprimir `typesafe`, tente o código mais recente do repositório:

```bash
pip install -U 'litellm[proxy] @ git+https://github.com/BerriAI/litellm.git@main'
```

## Passo 2: variáveis de ambiente

Acrescente ao `~/.zshrc` (ou `~/.bashrc`):

```bash
export TYPESAFE_API_KEY="sua-chave-typesafe"
export ANTHROPIC_API_KEY="sua-chave-anthropic"
export LITELLM_MASTER_KEY="sk-gerada-abaixo"
```

Para gerar a master key:

```bash
echo "sk-$(openssl rand -hex 24)"
```

Depois:

```bash
source ~/.zshrc
chmod 600 ~/.zshrc
```

## Passo 3: config.yaml

Copie o `config.yaml.example` deste repositório para `~/litellm-jev/config.yaml`.

> **Não use editores que convertem aspas retas em curvas** (TextEdit do macOS,
> por exemplo). Isso quebra o YAML de forma silenciosa. Prefira `cat > arquivo`
> com heredoc, VS Code ou nano.

Pontos do arquivo que importam:

- `mode: pre_call` é obrigatório, porque o guardrail só transforma a entrada
- `default_on: true` compacta toda requisição, sem opt-in
- O bloco `model_name: "*"` captura qualquer modelo Anthropic, inclusive o
  modelo de fundo do Claude Code e lançamentos futuros
- `relevance_threshold: 0.2` é a nota de corte, ajustável depois

## Passo 4: subir o proxy

Primeira vez, em primeiro plano, para ver erros:

```bash
litellm --config ~/litellm-jev/config.yaml
```

Procure na saída os modelos carregados e a linha
`Uvicorn running on http://0.0.0.0:4000`.

Para uso diário, copie as funções do `zshrc-snippet.sh` deste repositório.
Depois, basta `jevup`.

## Passo 5: apontar o Claude Code para o proxy

O `settings.json` global vale para todos os projetos, atuais e futuros.

> **Se o arquivo já existir, faça backup e mescle.** Sobrescrever apaga
> `permissions`, `hooks`, `enabledPlugins` e o resto da sua configuração.

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null

python3 - << 'PY'
import json, pathlib, os
p = pathlib.Path.home() / ".claude"
bak = p / "settings.json.bak"
data = json.loads(bak.read_text()) if bak.exists() else {}
data["env"] = {
    "ANTHROPIC_BASE_URL": "http://0.0.0.0:4000",
    "ANTHROPIC_AUTH_TOKEN": os.environ["LITELLM_MASTER_KEY"],
}
(p / "settings.json").write_text(json.dumps(data, indent=2, ensure_ascii=False))
print("chaves preservadas:", list(data.keys()))
PY

chmod 600 ~/.claude/settings.json
```

## Passo 6: verificar

```bash
curl -i -s http://0.0.0.0:4000/v1/messages \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"sonnet","max_tokens":5,"messages":[{"role":"user","content":"oi"}]}' \
  | grep -i "guardrail\|HTTP/"
```

Esperado:

```
HTTP/1.1 200 OK
x-litellm-applied-guardrails: jev-compaction
```

O `/v1/messages` é o endpoint que o Claude Code usa. Validar só o
`/v1/chat/completions` não prova que funciona no fluxo real.

## Passo 7: usar

```bash
cd ~/qualquer-projeto
claude
```

Nada muda no seu fluxo. A compactação é invisível.

---

## Armadilhas que custam tempo

**`API Error: 400 No connected db.`**
A mensagem é enganosa. Sem banco de dados, a master key é a única credencial
aceita, e qualquer outra chave produz esse erro. Traduzindo: a chave que o
cliente mandou não bate com a master key do proxy. Já existe PR no LiteLLM para
trocar isso por um 401.

**Rotacionou a master key e continua dando erro**
O proxy lê a master key apenas na inicialização. Reinicie depois de trocar.

**`Detected a custom API key in your environment`**
O Claude Code pergunta se deve usar o `ANTHROPIC_API_KEY` do ambiente. Responda
**No**, senão ele pode falar direto com a Anthropic e ignorar o proxy. Se ainda
assim ignorar:

```bash
env -u ANTHROPIC_API_KEY claude
```

**Conectores do claude.ai desabilitados**
Esperado. Com `ANTHROPIC_BASE_URL` apontando para um gateway, a sessão opera em
modo API Usage Billing e os conectores da conta claude.ai ficam indisponíveis.
Para um projeto que precise deles:

```bash
env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN claude
```

**Modelo com sufixo, como `opus[1m]`**
O bloco curinga `model_name: "*"` do config resolve. Sem ele, qualquer modelo
não declarado quebra.

**A Admin UI em `/ui` abre vazia**
Ela depende de banco de dados. Sem Postgres, não há spend logs nem métricas de
guardrail. Para medir a economia com números, rode com `DATABASE_URL` apontando
para um Postgres.

**Atualização futura quebra tudo em silêncio**
Um `pip install -U litellm` sem `--pre` reinstala a versão estável, que não tem
o guardrail. O proxy sobe normalmente e a compactação simplesmente não acontece.

---

## Limitações honestas

- **Só age sobre tool exchanges concluídos.** Mensagens de sistema, a última
  mensagem do usuário e o exchange mais recente nunca são tocados. Conversa
  curta sem ferramentas não tem o que compactar.
- **Não mede sozinho.** Sem banco de dados, não há como quantificar a economia.
- **Falha aberta por padrão.** Se a TypeSafe estiver fora do ar, a requisição
  passa sem compactar, com aviso no log. Para falhar fechado, use
  `unreachable_fallback: fail_closed`.
- **Versão pre-release.** A integração ainda não chegou ao canal estável.

---

## Referências

- [Guardrail TypeSafe no LiteLLM](https://docs.litellm.ai/docs/proxy/guardrails/typesafe)
- [TypeSafe AI](https://typesafe.ai)

## Licença

MIT
