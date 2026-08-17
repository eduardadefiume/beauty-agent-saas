# Política de Retenção de Dados

**Status:** decidida pela proprietária em 17/08/2026. Ainda **não implementada** — não existe rotina de retenção, anonimização ou eliminação no banco.
**Item do plano:** trilha D, `D2` (LGPD executável).
**Referência:** `docs/plano-estrategico-ponta-a-ponta.md`, seções 9.7 e 13.

## 1. Prazos decididos

| Dado | Retenção | Gatilho de contagem | Ação ao vencer |
|---|---|---|---|
| **Fotos de cliente** | 12 meses | último atendimento executado | eliminar arquivo do storage e a referência |
| **Histórico técnico e químico** | 5 anos | data da execução | eliminar |
| **Mensagens de WhatsApp — conteúdo** | 12 meses | data da mensagem | eliminar o conteúdo, preservar metadados |
| **Mensagens de WhatsApp — metadados** | 24 meses | data da mensagem | eliminar |
| **Áudio original recebido** | 30 dias | data do recebimento | eliminar o arquivo; a transcrição segue a regra de mensagem |
| **Auditoria** | 5 anos | data do evento | eliminar; imutável enquanto viva |

**Revogação de consentimento tem precedência sobre qualquer prazo.** Se a titular revoga o consentimento de imagem, as fotos são eliminadas imediatamente, sem esperar os 12 meses.

## 2. Justificativa de cada prazo

**Fotos — 12 meses.** São dado pessoal e servem a um propósito operacional de curto prazo: comparar antes/depois e orientar a próxima sessão. Depois de um ano sem retorno, o valor operacional some e só resta o risco. Minimização é o princípio que manda aqui.

**Histórico técnico e químico — 5 anos.** É o único item com prazo longo, e por um motivo específico: procedimento químico tem risco associado, e o registro do que foi aplicado protege tanto a cliente quanto o estabelecimento em caso de reação ou disputa. Não é dado de marketing; é registro de segurança.

**Mensagens — 12 meses de conteúdo, 24 de metadados.** O conteúdo da conversa é o dado mais sensível e o de menor valor após o atendimento acontecer. Os metadados (quando, direção, status de entrega) sustentam auditoria e conciliação de campanha sem guardar o que foi dito — por isso vivem mais e custam menos em risco.

**Áudio — 30 dias.** Decisão da proprietária, ampliando os 7 dias inicialmente propostos. O prazo maior dá margem para reprocessar uma transcrição que saiu ruim e para investigar uma reclamação sobre o que foi entendido. Passado isso, a transcrição basta.

**Auditoria — 5 anos.** Alinhado ao histórico técnico, para que sempre exista o registro de quem aprovou o quê no mesmo horizonte em que o procedimento pode ser questionado.

## 3. O que precisa existir para isto sair do papel

Nenhum destes controles existe hoje. Todos são pré-requisito de `D2`.

| # | Entrega | Evidência de conclusão |
|---|---|---|
| R1 | Coluna de classificação e data-base de retenção em cada tabela com dado pessoal | Toda tabela com PII declara sua classe |
| R2 | Rotina agendada de eliminação por classe, idempotente e auditada | Execução registra o que apagou, quando e por qual regra |
| R3 | Eliminação de arquivo em storage, não só da referência | Arquivo comprovadamente inacessível após a rotina |
| R4 | Revogação de consentimento dispara eliminação imediata de fotos | Teste: revogar consentimento remove as fotos na mesma transação ou fila |
| R5 | Exportação de dados do titular | Titular recebe o próprio dado em formato legível |
| R6 | Eliminação a pedido do titular, preservando o legalmente exigido | O que sobrevive à eliminação é justificado por regra explícita |

## 4. Complicação conhecida a resolver antes

O mesmo telefone está duplicado hoje em **quatro tabelas**: `crm_contact_channels.address_normalized`, `contacts.phone_number`, `channel_allowlist.normalized_contact` e `client_schedule_exceptions.client_phone_digits`.

Enquanto a convergência de schema da trilha A (`A1`) não acontecer, qualquer rotina de eliminação vai apagar o dado em um lugar e deixá-lo vivo em outro — o que é pior do que não ter rotina, porque cria a **aparência** de conformidade sem a substância.

Por isso `A1` precede `R2`. Não é preferência de ordem; é condição para a eliminação ser verdadeira.

## 5. Limite honesto deste documento

Isto é uma decisão de produto registrada, não uma conformidade alcançada. Nada aqui deve ser apresentado a um cliente como "o sistema aplica retenção" até que R1 a R6 tenham evidência. A política de privacidade publicada em `supabase/functions/privacy-policy` descreve intenção; o banco ainda não a executa.
