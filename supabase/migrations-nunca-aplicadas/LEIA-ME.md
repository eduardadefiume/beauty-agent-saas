# Migrations que existem no repositorio e NUNCA foram aplicadas no banco

Descoberto em 18/09/2026, ao reconciliar `supabase/migrations` com
`supabase_migrations.schema_migrations` do projeto `hjghwryhphgusefyivbl`.

Estes 15 arquivos estavam em `supabase/migrations` mas nao constam no historico
do banco. Foram movidos para ca para que a pasta `migrations` passe a ser um
espelho exato do que o banco realmente aplicou.

Duas categorias:

1. **Renomeados** — o mesmo trabalho foi aplicado no banco com outro nome.
   O arquivo com o nome do banco esta em `supabase/migrations`.
   - harden_public_function_privileges
   - enable_pg_net
   - agente_pergunta_ao_dono_e_contexto_cacheavel
   - conhecimento_rpcs_de_leitura_e_gravacao
   - cliente_nova_tambem_tem_lista
   - o_custo_de_cada_resposta_vira_linha_no_banco
   - rls_ligada_por_padrao_em_todas_as_tabelas

2. **Nunca aplicados de fato** — funcionalidade escrita que nao esta no ar.
   Decidir caso a caso se entra ou se e descartada.
   - crm_inbox_campaigns_base
   - technical_service_catalog
   - g2_add_pending_signal_status
   - g2_appointment_deposit
   - g2_expire_due_deposits      <- o SINAL nunca foi para o banco
   - g3_whatsapp_inbox_consent
   - g3_inbox_integrity
   - agente_enxerga_a_agenda

Nao apagar sem decisao explicita.
