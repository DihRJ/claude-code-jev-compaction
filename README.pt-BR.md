# Claude Code + Jev: compactação de contexto por relevância

**Português** · [English](README.md)

Tutorial prático para colocar um gateway LiteLLM entre o Claude Code e a API da
Anthropic, usando o modelo **Jev** (TypeSafe AI) para apagar resultados de
ferramenta que já não servem para a tarefa atual, antes que eles cheguem ao
modelo caro.

Escrito em português porque praticamente não existe material sobre isso em PT-BR.

> [!WARNING]
> **Este setup tira a sua sessão da assinatura Pro ou Max e passa a cobrar por
> token na sua conta da API.** Se você usa Claude Code dentro da assinatura, ele
> provavelmente vai **aumentar** o seu custo em vez de reduzir. Leia
> [Quem paga a conta](#quem-paga-a-conta) antes do Passo 1.

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

## Quem paga a conta

O Passo 5 aponta o Claude Code para o gateway com uma credencial própria
(`ANTHROPIC_AUTH_TOKEN`). A partir daí, **a assinatura do claude.ai deixa de ser
usada naquela sessão**: a credencial substitui o login, os limites de uso do
plano não valem mais e o consumo passa a ser cobrado por token de quem é dono da
chave que o gateway encaminha, que aqui é a sua conta do Claude Console.

A documentação da Anthropic diz isso textualmente:

> While a gateway credential variable or `apiKeyHelper` is active, a developer's
> claude.ai subscription isn't used: the credential replaces the subscription
> login for that session, and the subscription's usage limits don't apply. That
> traffic is billed per token to whoever owns the credential the gateway
> forwards.
>
> ([Other LLM gateways](https://code.claude.com/docs/en/llm-gateway))

Em [preço de tabela](https://platform.claude.com/docs/en/about-claude/pricing),
são **US$ 5 / US$ 25 por milhão de tokens** (entrada / saída) no Claude Opus 5 e
**US$ 2 / US$ 10** no Claude Sonnet 5.

**O que isso significa na prática:**

- **A economia cai na conta da API, nunca na assinatura.** Se hoje você roda o
  Claude Code dentro do Pro ou do Max, este setup troca custo marginal zero por
  cobrança por token. Cortar 30% de um número que antes era zero ainda é mais
  que zero.
- **O Jev é um segundo medidor.** Cada requisição que passa pelo guardrail é uma
  chamada cobrada à TypeSafe, e ela lê o histórico inteiro para decidir o corte.
  Some os dois antes de concluir que saiu barato.
- **Ponha um teto antes de subir o proxy.** Defina um spend limit de workspace no
  Claude Console
  ([como](https://platform.claude.com/docs/en/build-with-claude/workspaces#workspace-limits)).
  É a única proteção que não depende de você lembrar de conferir.
- **Sem banco de dados você não mede nada.** Sem `DATABASE_URL` o proxy não grava
  spend logs, então a economia continua no achismo enquanto a fatura não fica.

`ANTHROPIC_BASE_URL` sozinho **não** troca a cobrança. Quem troca é a credencial.

### Dá para manter a assinatura e ainda passar pelo gateway? Aqui, não.

No papel, sim. A documentação da Anthropic diz que definir apenas
`ANTHROPIC_BASE_URL`, sem credencial de gateway, mantém o login salvo do
claude.ai como credencial ativa, então valem os limites e a cobrança dele. O
LiteLLM tem até um tutorial para assinaturas Claude Code Max baseado em
`forward_client_headers_to_llm_api: true`, que deveria encaminhar o token OAuth
do usuário em vez de substituir pela chave do proxy.

**Não funciona na rota que o Claude Code usa de verdade.** Testado no LiteLLM
`1.103.0rc1`:

- O `/status` reporta certo: `Login method: Claude Max account` **e**
  `Anthropic base URL: http://127.0.0.1:4000`. O lado do cliente está correto.
- A requisição falha no proxy. Com `forward_client_headers_to_llm_api: true` e
  sem `api_key` nos modelos, o LiteLLM recusa antes de encaminhar:
  `Missing Anthropic API Key`.
- Colocando um `api_key` falso para passar dessa validação, o LiteLLM envia a
  chave falsa em vez do token OAuth do cliente: `invalid x-api-key`, da
  Anthropic.

O Claude Code fala com `/v1/messages`, que o LiteLLM serve pelo handler
`experimental_pass_through` da Anthropic. O encaminhamento de headers do cliente
não chega ali. Se uma versão futura corrigir isso, a mudança de config é
pequena: remover todo `api_key` do `model_list`, remover a `master_key`,
acrescentar `forward_client_headers_to_llm_api: true` e definir apenas
`ANTHROPIC_BASE_URL` no cliente.

**Até lá a troca é real: gateway ou assinatura, não os dois.** O que significa
que, se você está no Pro ou no Max e não pagava por uso de API de qualquer
forma, esta compactação economiza tokens de entrada que já não te custavam nada.

Para voltar à assinatura em um projeto específico, use o `claudeoff` do
`zshrc-snippet.sh`.

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

> **Este é o passo que troca a cobrança.** Depois dele, a sessão sai da
> assinatura e passa a consumir créditos da API. Ver
> [Quem paga a conta](#quem-paga-a-conta).

> **Se o arquivo já existir, faça backup e mescle.** Sobrescrever apaga
> `permissions`, `hooks`, `enabledPlugins` e o resto da sua configuração.

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null

python3 - << 'PY'
import json, pathlib, os
p = pathlib.Path.home() / ".claude"
bak = p / "settings.json.bak"
data = json.loads(bak.read_text()) if bak.exists() else {}
env = data.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:4000"
env["ANTHROPIC_AUTH_TOKEN"] = os.environ["LITELLM_MASTER_KEY"]
(p / "settings.json").write_text(json.dumps(data, indent=2, ensure_ascii=False))
print("chaves preservadas:", list(data.keys()), "| env:", list(env))
PY

chmod 600 ~/.claude/settings.json
```

## Passo 6: verificar

```bash
curl -i -s http://127.0.0.1:4000/v1/messages \
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
Esperado, e é o sintoma visível da troca descrita em
[Quem paga a conta](#quem-paga-a-conta): a credencial do gateway substitui o
login do claude.ai, então os conectores da conta ficam indisponíveis e a sessão
passa a ser cobrada por token. Para um projeto que precise deles:

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

**Variáveis de ambiente entram no proxy por uma porta lateral**
Duas delas sobrepõem o seu config sem avisar, porque o LiteLLM as lê direto do
ambiente do processo em que você o iniciou. Se você sobe o proxy de um shell que
carregou o seu `.zshrc`, elas estão lá:

- `LITELLM_MASTER_KEY` reativa a exigência de master key mesmo depois de você
  remover o `master_key` do `config.yaml`. Sintoma: `400 No connected db.`
- `ANTHROPIC_API_KEY` é usada para chamar a Anthropic mesmo sem `api_key` nos
  modelos, cobrando da sua conta de API em silêncio. Sintoma: `Your credit
  balance is too low` enquanto você acreditava estar na assinatura.

Suba o proxy com `env -u VARIAVEL` para a que não deve valer.

---

## Limitações honestas

- **Só age sobre tool exchanges concluídos.** Mensagens de sistema, a última
  mensagem do usuário e o exchange mais recente nunca são tocados. Conversa
  curta sem ferramentas não tem o que compactar.
- **Não mede sozinho.** Sem banco de dados, não há como quantificar a economia.
- **Falha aberta por padrão.** Se a TypeSafe estiver fora do ar, a requisição
  passa sem compactar, com aviso no log. Para falhar fechado, use
  `unreachable_fallback: fail_closed`.
- **Não é de graça.** O setup troca a assinatura por cobrança por token e ainda
  acrescenta a conta da TypeSafe. Ver [Quem paga a conta](#quem-paga-a-conta).
- **Versão pre-release.** A integração ainda não chegou ao canal estável.

---

## Referências

- [Guardrail TypeSafe no LiteLLM](https://docs.litellm.ai/docs/proxy/guardrails/typesafe)
- [TypeSafe AI](https://typesafe.ai)

## Licença

MIT
