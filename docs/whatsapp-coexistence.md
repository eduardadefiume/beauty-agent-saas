# WhatsApp Coexistence — o número do William não perde o aplicativo

Decisão de migração. Substitui o plano anterior, que estava errado.

## O que eu tinha dito, e por que estava errado

Eu afirmei que um número registrado na Cloud API **sai** do aplicativo do
WhatsApp Business — uma coisa ou outra, nunca as duas. Isso foi verdade até
maio de 2025.

Em maio de 2025 a Meta liberou o **Coexistence** (nome oficial: _API Solutions
for Business App Users_). O aplicativo e a Cloud API rodam no **mesmo número**,
com sincronização nos dois sentidos em tempo real por webhook.

Consequência prática: o William continua com o aplicativo no celular dele,
usando tudo o que já usa, e o nosso agente lê e responde pelo mesmo número.

## O que isso resolve

- **Status.** Continua funcionando normalmente pelo aplicativo. Ele posta, as
  clientes veem e respondem, exatamente como hoje.
- **Reabrir conversa a qualquer momento.** Duas vias: modelo aprovado pela API,
  ou simplesmente responder pelo aplicativo.
- **Chamadas e grupos.** Continuam funcionando pelo aplicativo.
- **O histórico.** Até **6 meses de conversas 1:1 e os contatos** entram na
  sincronização inicial. Isto resolve sozinho o problema de extração de
  conversas que a gente tinha abandonado por falta de caminho.

## O que o Coexistence NÃO faz

Lista honesta, para ninguém descobrir na operação:

- **Status não passa pela API.** Postar e ver status é só pelo aplicativo. A
  nossa tela não vai publicar status — e não precisa, porque o aplicativo dele
  continua de pé.
- **Grupos funcionam no aplicativo mas não sincronizam** para a API. O agente
  não enxerga grupo.
- **Chamadas de voz e vídeo só pelo aplicativo.** A Cloud API não faz chamada.
- **Alguns recursos são desligados nas conversas 1:1** depois de ativar:
  mensagens temporárias, ver uma vez, editar ou apagar mensagem enviada,
  localização ao vivo, e criar listas de transmissão novas (as que já existem
  ficam somente leitura).
- **O aplicativo tem que continuar instalado e ser aberto a cada 13 dias**, ou
  a sincronização cai.
- **Vazão fixa de 20 mensagens por segundo**, independente do limite normal da
  conta. Para um salão isso é folgado.
- **Histórico:** só 1:1, só 6 meses. Grupos e o que for mais antigo que 180
  dias não vêm.

## Sobre a janela de 24 horas

Eu passei a impressão de que fora das 24h ele fica preso esperando a cliente
falar primeiro. Está errado.

A janela de 24h limita **texto livre**, não o contato. Fora dela, o negócio
inicia conversa com **modelo aprovado** — quantas vezes quiser. É exatamente
assim que todo software de WhatsApp do mercado faz.

Duas regras reais que valem registrar:

- Modelo de **marketing** exige aceite da cliente e a Meta limita quantos
  modelos de marketing uma mesma pessoa recebe por dia, somando todos os
  negócios (na ordem de 2 por dia).
- Modelo de **utilidade** (confirmação, lembrete, remarcação) não tem esse
  teto e é o que cobre a operação do salão.

A janela de texto livre reabre quando a cliente **responde** — enviar o modelo
sozinho não reabre.

## Sobre "como os outros entregam status por API"

Entregam por fora dos Termos. Os provedores que oferecem API de status
(Wassenger, Whapi, Maytapi, WAHA) e as bibliotecas (Baileys,
whatsapp-web.js, Evolution) fazem engenharia reversa do WhatsApp Web.

O risco não é teórico:

- Ferramentas de engenharia reversa duram tipicamente **2 a 8 semanas** antes
  da detecção.
- Numa análise de mais de 600 contas de pequenos negócios na Índia, **68%**
  dos que usaram automação não oficial reportaram ao menos um banimento em 12
  meses.
- Em abril de 2026, um pacote "anti-ban" com 56 mil downloads foi confirmado
  exfiltrando credenciais de sessão e roubando mensagens.

Perder o número do salão é perder a agenda inteira do William. Não vale, e
não é preciso: o Coexistence entrega o que a gente queria, oficialmente.

## O que muda no plano

O plano antigo era pegar o número do William e registrar na Cloud API — o que
teria **matado o aplicativo dele**. O plano novo é ativar Coexistence sobre o
aplicativo que ele já usa.

O número de teste atual (+55 16 99412-7035) está registrado direto na Cloud
API, fora de Coexistence. Ele continua servindo para teste. A ativação de
Coexistence é um caminho de onboarding diferente e acontece no número dele.
