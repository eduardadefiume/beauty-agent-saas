# O modelo do lembrete de véspera

**23/09/2026.** Isto é a única parte do lembrete que não dá para automatizar:
criar o modelo é na conta Meta da Eduarda, e nenhum script meu entra lá.

Leva minutos, e é **uma vez por salão** (o nome do modelo é por WABA).

## Antes: o que não é necessário

Eu afirmei ontem que isso dependia de App Review e de CNPJ. **Não depende.**
Conferido na documentação da Meta em 23/09:

- portfólio não verificado: **250 modelos por WABA** — você precisa de um;
- **250 destinatários únicos por 24h** — um salão manda entre 20 e 40;
- _"standard access does not require app review"_.

O que exige CNPJ é outra coisa: Embedded Signup (o fluxo do QR), coexistência,
migrar número entre portfólios, selo verde. Nada disso entra aqui.

## Passo 1 — criar o modelo no WhatsApp Manager

`business.facebook.com` → WhatsApp Manager → **Modelos de mensagem** → Criar modelo

| campo     | valor                                                               |
| --------- | ------------------------------------------------------------------- |
| Categoria | **Utilidade** (não Marketing — muda o preço e a régua de aprovação) |
| Nome      | `lembrete_vespera`                                                  |
| Idioma    | Português (BR)                                                      |

**Corpo** (cole exatamente assim, com as chaves duplas):

```
Oi {{1}}! Passando pra lembrar do seu horário amanhã, dia {{2}}, às {{3}}, aqui no {{4}}.

Se precisar remarcar ou cancelar, é só me responder por aqui.
```

A Meta pede um exemplo para cada variável antes de deixar enviar:

| variável | exemplo          |
| -------- | ---------------- |
| {{1}}    | Rayana           |
| {{2}}    | 24/09            |
| {{3}}    | 14:00            |
| {{4}}    | Salão do William |

**Não coloque botão.** Botão de "cancelar" vira categoria Marketing em algumas
revisões, e Marketing custa nove vezes mais (US$ 0,0625 contra US$ 0,0068).

A aprovação costuma sair em minutos. Enquanto não sair, o agendador **pula e
anota o motivo** — não falha em silêncio.

## Passo 2 — registrar o nome aprovado no banco

O código fala por código interno (`LEMBRETE_VESPERA`) e a tabela traduz para o
nome real. Sem esta linha, o lembrete é pulado com motivo `MODELO_NAO_REGISTRADO`.

```sql
select app.registrar_modelo_aprovado(
  p_tenant_id     => 'COLE_O_TENANT_ID',
  p_code          => 'LEMBRETE_VESPERA',
  p_template_name => 'lembrete_vespera',
  p_param_count   => 4,
  p_language      => 'pt_BR',
  p_category      => 'UTILITY',
  p_preview       => 'Oi {1}! Lembrando do seu horario amanha, {2}, as {3}, no {4}.'
);
```

## Passo 3 — ligar para o salão

O lembrete é **opt-in**: nasce desligado. Quem liga é o dono, respondendo a
primeira pergunta do Eddy — ou, na mão:

```sql
insert into app.agent_scope (tenant_id, marca_horario, lembra_da_vespera, lembrete_hora_local)
values ('COLE_O_TENANT_ID', true, true, 18)
on conflict (tenant_id) do update
   set lembra_da_vespera = true, lembrete_hora_local = 18;
```

`lembrete_hora_local` é a hora da véspera em que sai, no fuso da unidade.
18h é o padrão: a cliente já saiu do trabalho e ainda dá tempo de remarcar.

## Como conferir que funcionou

O agendador grava uma linha por agendamento decidido, **inclusive os que pulou**:

```sql
select r.decided_at, r.status, r.skip_reason, a.customer_label, a.starts_at
  from app.appointment_reminders r
  join app.appointments a on a.id = r.appointment_id
 order by r.decided_at desc
 limit 20;
```

Os motivos que você vai ver, e o que cada um quer dizer:

| skip_reason                 | o que fazer                                                   |
| --------------------------- | ------------------------------------------------------------- |
| `MODELO_NAO_REGISTRADO`     | falta o passo 2                                               |
| `MODELO_NAO_APROVADO`       | a Meta ainda está revisando, ou pausou por qualidade          |
| `SEM_TELEFONE`              | o agendamento foi criado sem `external_contact_ref`           |
| `SEM_CONVERSA`              | o telefone não bate com nenhuma conversa de WhatsApp do salão |
| `AGENT_AUTOMATION_DISABLED` | o freio de emergência está puxado                             |

## O que custa

Utility no Brasil: **US$ 0,0068 ≈ R$ 0,04** por lembrete. Trinta por dia dá
**cerca de R$ 33 por mês**.

**A partir de 01/10/2026** a Meta passa a cobrar também os utility mandados
_dentro_ da janela de 24h, que até então eram grátis. O lembrete de véspera
quase sempre cai **fora** da janela, então já era pago — essa mudança não
altera a conta acima.
