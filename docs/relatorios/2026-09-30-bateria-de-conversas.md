# Bateria de conversas — 30/09/2026 (DEV, salão do William, modo UM SÓ, Google conectado)

Cada linha: o que a cliente/dono fez, o que aconteceu, a prova e o conserto.

## Eddy (dono)

| Caso                                                 | Resultado                                        | Conserto                                         |
| ---------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------ |
| Pergunta de preço sem ligação com cor                | OK, sem lembrete de cor e mechas                 | 7fb0326                                          |
| Muda preço do corte com escova                       | OK, sem lembrete                                 | —                                                |
| "Pode publicar. O que falta no cadastro?"            | FALHOU: sem resposta (o filtro engoliu)          | f7e4259 — reteste OK: "Só falta cor e mechas..." |
| "Depois vejo isso. Quantas clientes marcaram?"       | OK sem lembrete; **não sabe ver a agenda**       | lacuna de produto (abaixo)                       |
| Dono responde desconto pedido pela atendente (#AC07) | OK: repassado às 3 clientes e virou regra        | —                                                |

## Atendente (clientes)

| Caso                                                          | Resultado                                                        | Conserto / reteste                          |
| ------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------- |
| 4 perguntas numa msg (corte, progressiva, cartão, sábado)     | FALHOU: "sábado tenho horário! qual desses?" sem consultar       | d86f81b — trava "vaga sem consulta"         |
| idem (reteste)                                                | FALHOU: trava de "irmãos" juntou corte+progressiva; sábado sumiu | 4706f03 — reteste OK (4 respostas + 9h)     |
| "Sou a Paula, quero só o corte" → "Isso"                      | FALHOU GRAVE: marcou sábado 9h que ela nunca viu                 | 57d6e1e — só reserva horário visto/pedido   |
| Paula: "não escolhi 9h, tem 10h30?"                           | OK: pediu desculpa, remarcou, 9h cancelado, Google atualizado    | —                                           |
| Paula: "que horas ficou / com quem?"                          | FALHOU: "com a Karen" (ouviu William ao marcar)                  | 3403b85 + migr. 20260930182819 — reteste OK |
| Bia pede a Karen (modo um só)                                 | OK: oferece Karen; "é com a Karen né?" → "Isso"                  | —                                           |
| Carla e Bia no mesmo 9h                                       | OK: Carla com William, Bia com Karen, sem sobreposição           | —                                           |
| Orientação: "cabelo fino, progressiva fica murcho?"           | FALHOU: abre com "deixa eu te explicar melhor" na 1ª msg         | 4706f03 + 410bea7 — reteste OK              |
| Combo corte+progressiva com desconto                          | FALHOU: "muita química" (corte não é química)                    | migr. 20260930183909 — reteste OK           |
| Carla desmarca                                                | OK: CANCELLED e evento apagado do Google                         | —                                           |
| "Sou a Rê, corte dia 10 depois das 15h"                       | FALHOU: "Oi, Rê!" + "Qual o seu nome?"                           | 44a4030 — reteste OK (oferece 10/10 15h)    |
| Rê antiga: "Rê, já falei rs"                                  | FALHOU GRAVE: marcou 15h ("depois das 15h" contou como escolha)  | d0d4b80                                     |

## Lacunas de produto (não são defeito de conversa)

- O Eddy não consegue responder "quantas clientes marcaram essa semana" — o dono vai perguntar isso.
- Modo UM SÓ: no Google aparece quem faz de verdade (ex.: "Quem faz: Karen"); para a cliente é sempre o William. Confirmar com a Duda que é isso que ela quer.
- Resposta de orientação técnica ("fica murcho?") é honesta mas rasa: empurra para avaliação.
