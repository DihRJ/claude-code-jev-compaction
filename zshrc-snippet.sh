#!/usr/bin/env bash
# Funcoes de conveniencia para o proxy LiteLLM + Jev.
# Acrescente ao final do seu ~/.zshrc (ou ~/.bashrc):
#
#   cat zshrc-snippet.sh >> ~/.zshrc && source ~/.zshrc
#
# ATENCAO: sao dois sinais de maior. Com um so, voce apaga o arquivo inteiro.

# Sobe o proxy em segundo plano. Sobrevive ao fechamento do terminal.
jevup() {
  nohup ~/litellm-jev/.venv/bin/litellm \
    --config ~/litellm-jev/config.yaml \
    > ~/litellm-jev/proxy.log 2>&1 &
  echo "proxy subindo"
}

# Derruba o proxy.
jevdown() {
  pkill -f "litellm --config"
  echo "proxy derrubado"
}

# Acompanha o log em tempo real. Saia com Ctrl+C.
jevlog() {
  tail -f ~/litellm-jev/proxy.log
}

# Confirma que o guardrail esta ativo nesta execucao do proxy.
# Faz uma chamada real a API com max_tokens 5, entao tem custo minimo.
jevcheck() {
  curl -i -s http://0.0.0.0:4000/v1/messages \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"sonnet","max_tokens":5,"messages":[{"role":"user","content":"oi"}]}' \
    | grep -qi "jev-compaction" && echo "Jev ativo" || echo "Jev INATIVO"
}

# Abre o Claude Code SEM o proxy, para quando precisar dos conectores
# do claude.ai naquele projeto especifico.
claudeoff() {
  env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN claude "$@"
}
