# Bateria de conversas — 30/09/2026 (DEV, salão do William, modo UM SÓ, Google conectado)

Cada linha: o que a cliente/dono fez, o que aconteceu, a prova e o conserto.

## Eddy (dono)

| Caso                                                 | Resultado                                  | Conserto                                         |
| ---------------------------------------------------- | ------------------------------------------ | ------------------------------------------------ |
| Pergunta de preço sem ligação com cor                | OK, sem lembrete de cor e mechas           | 7fb0326                                          |
| Muda preço do corte com escova                       | OK, sem lembrete                           | —                                                |
| "Pode publicar. O que falta no cadastro?"            | FALHOU: sem resposta (o filtro engoliu)    | f7e4259 — reteste OK: "Só falta cor e mechas..." |
| "Depois vejo isso. Quantas clientes marcaram?"       | OK sem lembrete; **não sabe ver a agenda** | lacuna de produto (abaixo)                       |
| Dono responde desconto pedido pela atendente (#AC07) | OK: repassado às 3 clientes e virou regra  | —                                                |

## Atendente (clientes)

| Caso                                                      | Resultado                                                        | Conserto / reteste                          |
| --------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------- |
| 4 perguntas numa msg (corte, progressiva, cartão, sábado) | FALHOU: "sábado tenho horário! qual desses?" sem consultar       | d86f81b — trava "vaga sem consulta"         |
| idem (reteste)                                            | FALHOU: trava de "irmãos" juntou corte+progressiva; sábado sumiu | 4706f03 — reteste OK (4 respostas + 9h)     |
| "Sou a Paula, quero só o corte" → "Isso"                  | FALHOU GRAVE: marcou sábado 9h que ela nunca viu                 | 57d6e1e — só reserva horário visto/pedido   |
| Paula: "não escolhi 9h, tem 10h30?"                       | OK: pediu desculpa, remarcou, 9h cancelado, Google atualizado    | —                                           |
| Paula: "que horas ficou / com quem?"                      | FALHOU: "com a Karen" (ouviu William ao marcar)                  | 3403b85 + migr. 20260930182819 — reteste OK |
| Bia pede a Karen (modo um só)                             | OK: oferece Karen; "é com a Karen né?" → "Isso"                  | —                                           |
| Carla e Bia no mesmo 9h                                   | OK: Carla com William, Bia com Karen, sem sobreposição           | —                                           |
| Orientação: "cabelo fino, progressiva fica murcho?"       | FALHOU: abre com "deixa eu te explicar melhor" na 1ª msg         | 4706f03 + 410bea7 — reteste OK              |
| Combo corte+progressiva com desconto                      | FALHOU: "muita química" (corte não é química)                    | migr. 20260930183909 — reteste OK           |
| Carla desmarca                                            | OK: CANCELLED e evento apagado do Google                         | —                                           |
| "Sou a Rê, corte dia 10 depois das 15h"                   | FALHOU: "Oi, Rê!" + "Qual o seu nome?"                           | 44a4030 — reteste OK (oferece 10/10 15h)    |
| Rê antiga: "Rê, já falei rs"                              | FALHOU GRAVE: marcou 15h ("depois das 15h" contou como escolha)  | d0d4b80 — reteste OK (oferece, não marca)   |

| Rê antiga: "não confirmei 15h, prefiro 16h" | OK no banco (15h cancelado, 16h marcado); desculpa sumiu no filtro | 44d842b |

## Lacunas de produto (não são defeito de conversa)

- O Eddy não consegue responder "quantas clientes marcaram essa semana" — o dono vai perguntar isso.
- Modo UM SÓ: no Google aparece quem faz de verdade (ex.: "Quem faz: Karen"); para a cliente é sempre o William. Confirmar com a Duda que é isso que ela quer.
- Resposta de orientação técnica ("fica murcho?") é honesta mas rasa: empurra para avaliação.

## Rodada 2 (30/09, noite)

| Caso                                                                | Resultado                                                                | Conserto                                                                                        |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Dono: "quantas clientes marcaram essa semana?"                      | FALHOU: HANDOFF (a função nova dava 404, faltava a ponte no public)      | 631a7ae + migr. 20260930193540 — reteste OK: "6 marcações, vêm 2, R$ 220" (confere com o banco) |
| Dono: "quem vem sábado dia 10?"                                     | OK: Fernanda 11h e Rê 16h; ruído sobre "dias da Duda"                    | 86ae351                                                                                         |
| Dono: "no Google deixa tudo no meu nome"                            | OK: gravado; título virou WILLIAM, descrição continuou "Quem faz: Karen" | migr. 20260930194118 — 6 eventos conferidos no Google                                           |
| Áudio (transcrição simulada) de cliente nova com nome, luzes, preço | OK: nome, "a partir de R$ 420" (do cadastro), pede foto                  | —                                                                                               |
| Cliente some 1h e volta mudando de ideia                            | OK: "só o corte então! quinta 08/10 9h com William, pode ser?"           | —                                                                                               |
| Cliente some e volta: "ainda tem aquele horário?"                   | Marcou direto (horário tinha sido oferecido a ela)                       | decisão da Duda                                                                                 |

Não testado: transcrição de áudio de verdade (o simulador entrega o texto pronto; só com número real).
Reteste da desculpa: não reproduzível naturalmente depois das travas; mudança é um filtro de texto.

## Sinal (01/10) — o dono configura, a cliente recebe o cartão

Configuração feita pelo William-robô no WhatsApp do Eddy, uma pergunta por vez:
valores (luzes/morena R$ 100, progressiva/coloração R$ 50, corte e escova sem sinal), só em dezembro,
48h se marcar no mês anterior / 24h no próprio mês, Pix 16 99999-0000 (William Ferreira), devolve com 48h, ligado.

| Caso                                                                                                                                | Resultado                                                                                                                                   |
| ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Eddy larga o sinal no meio para perguntar de cor                                                                                    | FALHOU, consertado (3e9e9c0) — reteste OK                                                                                                   |
| Conta do prazo (9 casos: nov->dez 48h, dez->dez 24h, corta 2h antes, em cima da hora sem sinal, fora do período, serviço sem sinal) | OK no banco                                                                                                                                 |
| Corte em dezembro (sem sinal)                                                                                                       | CONFIRMED, NOT_REQUIRED, finalização normal                                                                                                 |
| Luzes 01/12 9h marcado em 01/10                                                                                                     | PENDING_SIGNAL, R$ 100, prazo 03/10 13h14 (48h), fora do Google, cartão com Pix                                                             |
| Luzes "sem horário em dezembro inteiro"                                                                                             | causa: William sem a habilidade "Cor e mechas" no DEV; Eddy dizia que "precisava da equipe" — consertado (2ed99e3), dono liga pelo WhatsApp |

Deslizes de conversa (01/10) — consertados e retestados ao vivo:

| Deslize                             | Conserto                                                                                                                                             | Prova                                                              |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| "Já te mando uma foto desse tom"    | `quemMandaAFoto` reescreve antes de enviar (6 casos)                                                                                                 | e379523                                                            |
| Pergunta de novo o que ela já disse | `fichaDita` anota química/tempo/coloração antes do modelo (46 casos); `periodo_para_data` entende "ano passado", "em junho", "ano e meio" (34 casos) | Luana, Gabi, Bruna: nenhuma pergunta repetida; ficha gravada certa |
| Formol para luzes                   | `client_profile_missing` só pergunta formol para alisamento (21 tipos conferidos)                                                                    | Luana: falta só foto e tom                                         |
| Cartão "R$ 420" para "a partir de"  | cartão, título do Google ("A PARTIR DE 420 DEU 100", sem "ficou"), agenda do Eddy e rótulo                                                           | cartão da Marina conferido                                         |

Achados no reteste (também consertados): "quero progressiva, nunca fiz química" virava "tem progressiva";
o modelo regravava "não tem química" por cima do que ela disse; "sem química" deixava tipo/data velhos na ficha.

Comportamento por regra (não é defeito): sem foto do cabelo, não passa horário de química (regra da Duda de 25/09).
Falta: comprovante -> dono confirma -> CONFIRMED + Google + finalização; lembrete antes do prazo;
prazo vencido -> libera e avisa; desmarcar com devolução.
