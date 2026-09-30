# Sinal para agendar — proposta para decisão (30/09/2026)

## O que já existe no banco (revisado)

- `service_deposit_policies`: sinal por serviço (valor fixo em centavos OU % do preço) e prazo em minutos.
- `schedule_confirm_hold`: com sinal, o agendamento nasce **PENDING_SIGNAL** e **ocupa o horário** até `due_at`.
- `appointment_deposits` + eventos imutáveis; `schedule_register_deposit_confirmation`; `schedule_expire_due_deposits` (vence e libera).
- G4: evento no Google só aparece quando o sinal é pago (PENDING_SIGNAL não vai para a agenda).

## Provedor recomendado: Asaas (cada dono com a PRÓPRIA conta)

- Dinheiro cai direto na conta do salão; nós nunca tocamos no dinheiro (sem risco regulatório).
- Dono abre conta Asaas (CPF ou CNPJ, documento + selfie), gera a chave de API e cola no Eddy.
- Asaas Checkout: Pix + cartão de crédito, **expiração configurável (10 a 1440 min)**, webhook de pago/expirado/cancelado,
  estorno por API, cancelar cobrança por API, sandbox.
- Taxas (site Asaas, 09/2026): Pix R$ 1,99; crédito R$ 0,49 + 2,99%; débito R$ 0,35 + 1,89% (débito só na fatura, não no Checkout).
- NÃO usar subconta agora: a análise regulatória da 1ª subconta pode bloquear cobranças por até 60 dias.
- Alternativa: Mercado Pago via OAuth (onboarding mais fácil), mas Pix com mínimo de 30 min e crédito 4,98%.

## Fluxo (o que a cliente vive)

1. Cliente aceita o horário -> agendamento PENDING_SIGNAL, horário **exclusivo dela por N minutos** (padrão 20; dono escolhe 10/15/20/30).
2. Chega o "cartão" no WhatsApp: serviço, dia, hora, com quem, valor total, **sinal R$ X**, "pague até HH:MM",
   por que existe o sinal (se desmarcar com antecedência, o salão não perde o horário), link Pix/cartão.
3. Pagou (webhook) -> CONFIRMED, entra no Google com "DEU X FICOU Y", confirmação do dono sai.
4. 5 min antes de vencer: lembrete gentil ("seu horário fica reservado até 14:20").
5. Venceu sem pagar -> cobrança cancelada no Asaas, horário liberado, mensagem educada oferecendo novos horários.
6. Pagou depois de vencer (Pix atrasado): se o horário ainda está livre -> confirma; se outra pegou -> **estorno automático**
   - mensagem pedindo desculpas + novos horários (a atendente retoma a conversa sabendo o que houve).
7. Cancelamento pela cliente: regra do dono (devolve se >= X horas antes; senão fica como crédito/perde) — dono define no Eddy.

## Regra "ninguém sobrepõe ninguém"

- Durante a janela, o horário está OCUPADO no banco (constraint de não-sobreposição por profissional): ninguém mais consegue marcar.
- Webhook idempotente (id do evento + id da cobrança); decisão sempre no banco, com lock.

## O que o dono configura no Eddy

- Liga/desliga sinal; por serviço ou geral; valor fixo ou %; a partir de qual valor de serviço; prazo para pagar;
  política de desistência (devolve/não devolve/vira crédito); período (ex.: só em dezembro — caso William).

## Estimativa

- Construção + testes exaustivos em sandbox: ~5 a 7 dias de trabalho.
- Dependência externa (caminho crítico): conta Asaas do William aprovada + chave de API. Iniciar JÁ.
- Pagamento "dentro do WhatsApp" (order_details/Pix da Meta): fase 2; não substitui o provedor.
