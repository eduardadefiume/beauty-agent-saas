# Dado do piloto, que estava na pasta de estrutura

**23/09/2026.** Ao construir o banco DEV do zero, a 69a migration falhou:

```
20260821124318_catalogo_salao_piloto.sql
ERROR: CONFIGURATION_DRAFT_NOT_OPEN
```

As duas primeiras linhas dela explicam tudo:

```sql
v_tenant uuid := '4b2a8e37-1716-41c4-9201-eefce890638d';  -- Piloto Eduarda
v_draft  uuid := '00ba4dc0-4367-4296-a8ce-25f51212cb81';  -- rascunho revisao 12
```

**Sao UUIDs que so existem na producao.** Num banco novo esse salao nao existe,
o `update` nao acha linha nenhuma, e a trava do rascunho estoura.

## Por que elas sairam de `migrations/`

Migration de estrutura tem que rodar em QUALQUER banco vazio. Estas quatro so
rodam num banco que ja e o da producao -- o que as torna, por definicao, outra
coisa: sao operacoes de dado, feitas uma vez, num tenant especifico.

Enquanto elas estiverem em `migrations/`, **nenhum banco novo pode ser criado a
partir do repositorio**. E isso nao e teoria: e o que impedia hoje.

| arquivo                                 | o que faz                                                |
| --------------------------------------- | -------------------------------------------------------- |
| `move_whatsapp_channel_to_pilot_tenant` | move o canal de WhatsApp para o tenant do piloto         |
| `catalogo_salao_piloto`                 | os 26 servicos, a equipe e o horario do salao do William |
| `publicar_catalogo_salao_piloto`        | publica esse catalogo                                    |
| `o_agendamento_tem_nome`                | conserta o nome de UM agendamento                        |

A propria `catalogo_salao_piloto` ja dizia, no comentario: _"Nao e o cadastro
definitivo do cliente -- quando o William sentar para cadastrar o dele, este
aqui sai."_

## O que isso significa para a producao

**ERREI ESTA PARTE, e a correcao vem abaixo.** O que eu escrevi de manha foi:

> Nada muda. (...) Efeito colateral aceito: `supabase migration list` passa a
> mostrar quatro versoes so no remoto. E cosmetico.

**Nao e cosmetico: bloqueia o `db push`.** Na primeira promocao para producao,
23/09 a noite, o CLI recusou antes de aplicar qualquer coisa:

```
Remote migration versions not found in local migrations directory.
```

Ele nao aceita que o historico remoto tenha versao sem arquivo local, e nao
ha flag para ignorar. O caminho e tirar as quatro do historico:

```
npx supabase migration repair --status reverted ^
  20260817194518 20260821124318 20260821125831 20260831183441 ^
  --workdir E:\BeautyAgentSaaS\beauty-agent-saas-oficial
```

**`--status reverted` NAO desfaz nada no banco.** A documentacao do Supabase e
explicita: _"Marking as `reverted` will delete an existing record from the
migration history table"_ -- so a tabela de historico. O catalogo do piloto, os
26 servicos, a equipe e o agendamento renomeado continuam onde estao.

Depois disso o historico da producao passa a espelhar `migrations/`, que e o
mesmo estado do DEV -- que nunca teve estas quatro.

**O preco, e ele e real:** o banco deixa de registrar que estes quatro scripts
rodaram. Se um dia alguem devolver os arquivos para `migrations/`, o CLI vai
tentar aplica-los na producao. Por isso a secao seguinte existe, e por isso
ela diz o que diz.

## Se precisar rodar de novo

Nao rode. O catalogo do piloto hoje e mantido pelo configurador e pelo Eddy,
nao por arquivo. Estes ficam como registro historico de como o piloto foi
semeado em agosto.

Para semear um salao NOVO, o caminho e o produto: o dono conversa com o Eddy,
ou preenche o configurador. Era esse o ponto desde o comeco.
