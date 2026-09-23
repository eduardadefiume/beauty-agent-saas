# As 7 que sao DUPLICATA, nao as que faltam

**Reescrito em 23/09/2026.** A versao anterior deste arquivo dizia que havia
aqui 15 migrations "nunca aplicadas", em duas categorias. A segunda categoria
estava **errada**, e o erro foi meu.

## O que a reconstrucao do dev provou

Em 23/09 o banco DEV foi criado do zero e as migrations aplicadas em ordem. A
`20260820133000_b3_outbox_envio_whatsapp` falhou:

```
ERROR: relation "app.crm_conversations" does not exist
```

Ninguem em `supabase/migrations/` criava essa tabela. Ela era criada por
`crm_inbox_campaigns_base`, que estava **aqui**, marcada como nunca aplicada --
enquanto na producao ela tinha 293 contatos, 114 mensagens e 7 conversas.

A auditoria seguinte encontrou **18 tabelas da producao sem migration que as
criasse**, e confirmou objeto por objeto que as 8 da "categoria 2" existem no
banco de producao, com dados:

| migration | prova |
|---|---|
| crm_inbox_campaigns_base | crm_contacts existe, 293 linhas |
| technical_service_catalog | service_technical_profiles existe |
| g2_appointment_deposit | **appointment_deposits existe, 4 sinais** |
| g2_expire_due_deposits | schedule_expire_due_deposits existe |
| g3_whatsapp_inbox_consent | whatsapp_channels existe |
| agente_enxerga_a_agenda | build_agent_context existe |

**O sinal nunca foi perdido.** Em 18/09 eu escrevi aqui "o SINAL nunca foi para
o banco" e repeti isso para a Duda como uma funcionalidade perdida. Era falso:
ele esta no ar desde agosto.

## Como o erro aconteceu

Em 18/09 a reconciliacao comparou `supabase/migrations/` com
`supabase_migrations.schema_migrations` e concluiu que o que sobrava no repo
nao tinha sido aplicado. A conclusao certa era a inversa: **foi aplicado e nao
foi registrado** -- que e o que o SQL Editor do painel faz, e foi o que criou
as 37 fantasma que a mesma reconciliacao consertou.

Bater o livro-caixa nao e o mesmo que estar completo. A unica prova de que o
repositorio reconstroi o banco e reconstruir o banco.

## O que sobra aqui, e por que nao entra

Estas 7 sao **o mesmo trabalho que ja esta em `supabase/migrations/`**, com
outro nome -- o nome com que o banco registrou. Move-las para la criaria a
mesma tabela duas vezes e quebraria a reconstrucao:

- harden_public_function_privileges
- enable_pg_net
- agente_pergunta_ao_dono_e_contexto_cacheavel
- conhecimento_rpcs_de_leitura_e_gravacao
- cliente_nova_tambem_tem_lista
- o_custo_de_cada_resposta_vira_linha_no_banco
- rls_ligada_por_padrao_em_todas_as_tabelas

Ficam como registro historico. **Nao mover, nao apagar sem decisao explicita.**

## As 5 tabelas orfas de verdade

`contacts`, `conversations`, `messages`, `customer_consents` e
`whatsapp_channels` existem na producao, **nao tem migration em lugar nenhum**,
e estao **todas com zero linhas**. Sao a versao 1 do CRM, substituida pelas
`crm_*`. O dev nasce sem elas, e isso e correto -- nada no codigo as usa.
