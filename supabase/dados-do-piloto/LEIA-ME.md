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

| arquivo | o que faz |
|---|---|
| `move_whatsapp_channel_to_pilot_tenant` | move o canal de WhatsApp para o tenant do piloto |
| `catalogo_salao_piloto` | os 26 servicos, a equipe e o horario do salao do William |
| `publicar_catalogo_salao_piloto` | publica esse catalogo |
| `o_agendamento_tem_nome` | conserta o nome de UM agendamento |

A propria `catalogo_salao_piloto` ja dizia, no comentario: *"Nao e o cadastro
definitivo do cliente -- quando o William sentar para cadastrar o dele, este
aqui sai."*

## O que isso significa para a producao

Nada muda. As quatro ja foram aplicadas la e continuam registradas em
`supabase_migrations.schema_migrations`. O CLI nao tenta reaplicar o que ja
esta no historico remoto; ele so deixa de ter o arquivo local correspondente.

Efeito colateral aceito: `supabase migration list` passa a mostrar quatro
versoes so no remoto. E cosmetico, e o preco de poder reconstruir o banco.

## Se precisar rodar de novo

Nao rode. O catalogo do piloto hoje e mantido pelo configurador e pelo Eddy,
nao por arquivo. Estes ficam como registro historico de como o piloto foi
semeado em agosto.

Para semear um salao NOVO, o caminho e o produto: o dono conversa com o Eddy,
ou preenche o configurador. Era esse o ponto desde o comeco.
