# ADR-004 — Dois números: o do salão e o do Eddy

Data: 14/09/2026. Status: **aceito** pela proprietária. Falta só a compra do
chip.

## A decisão

São dois números de WhatsApp, e cada um tem um dono diferente:

| | número | quem fala ali | de quem é |
|---|---|---|---|
| **Agente do salão** | 16 99412-7035 | as clientes do William | do salão (um por cliente do SaaS) |
| **Eddy** | chip novo, a comprar | os donos dos salões | da EDDigital (um só, para sempre) |

O 16 99412-7035 **continua sendo o canal do salão-piloto**. Ele já está
conectado (`phone_number_id 1263097080223211`, 228 eventos no inbox); mexer nele
deixaria o agente das clientes sem canal.

## Por que dois, e por que o do Eddy é um só

A proprietária propôs isto e está certa. Três razões, em ordem de peso:

1. **O dono precisa falar com o Eddy ANTES de ter um número conectado.** O Eddy
   é quem configura o negócio dele por conversa. Se o Eddy morasse no número do
   salão, a configuração só poderia começar depois do onboarding do WhatsApp —
   que é justamente a parte que o Eddy deveria ajudar a fazer. A ordem ficaria
   invertida.
2. **Coexistence: o dono não manda mensagem para si mesmo.** O Business App do
   William é o próprio número do salão. Um agente que morasse ali não teria como
   conversar com ele.
3. **Marca.** Um número só, com nome e foto do Eddy, que todos os clientes do
   SaaS reconhecem. Trinta salões, trinta agentes de cliente, **um** Eddy.

## O que o número do Eddy precisa ser

Requisitos da Cloud API, não meus:

- **receber um SMS ou uma ligação uma vez**, para a verificação da Meta;
- **não estar registrado no WhatsApp** (nem no comum, nem no Business). Chip
  novo resolve; chip usado exige apagar a conta antes;
- **estar no nome da EDDigital** (CPF ou CNPJ da proprietária). É a identidade
  do produto, não de uma pessoa do piloto;
- **não morrer por falta de recarga.** Depois de registrado, o número vive nos
  servidores da Meta e não precisa de aparelho nem de plano de dados — mas se a
  operadora desativar a linha por inatividade, o número volta para o bolo e
  outra pessoa pode recebê-lo. Recarga mínima periódica, ou plano controle
  quando o produto tiver cliente pagante.

Número virtual/VoIP a Meta aceita no papel, e na prática é fonte recorrente de
verificação recusada. Por dez reais de chip, não vale o risco.

## O que isto destrava e o que não destrava

Destrava a etapa 7 inteira (o Agente do Dono): registrar os templates da Meta no
número do Eddy, e o fluxo em que o dono responde por áudio e foto enquanto o
Eddy preenche o painel.

Não destrava o piloto: o agente das clientes já funciona no número do salão e
não depende disto.
