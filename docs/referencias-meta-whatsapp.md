# Evidências oficiais — WhatsApp Business Platform

**Coletadas em:** 13 de agosto de 2026  
**Uso:** requisitos de inbox e campanha real do piloto.

| Evidência | Implicação de produto |
|---|---|
| A Cloud API usa Graph API para envio e webhooks para mensagens recebidas, estados de entrega e erros. | A inbox deve ser alimentada por webhook, e o estado de uma campanha não pode ser considerado entregue sem evento recebido. |
| Meta documenta que os webhooks podem ser reenviados por até sete dias quando o endpoint não retorna `200`, gerando notificações duplicadas. | O receptor precisa validar assinatura, persistir evento com chave idempotente e tratar duplicidade. |
| Templates são o único tipo de mensagem permitido fora da janela de atendimento; precisam estar aprovados para envio. | Campanha real deve bloquear envio se o template não estiver com status `APPROVED`. |
| A Meta exige opt-in antes do envio de templates e os templates podem ser de marketing, utilidade ou autenticação. | O público elegível precisa ter consentimento rastreável por tenant/canal, e a tela deve mostrar a categoria do template. |
| A plataforma publica mudanças de status e qualidade de templates via webhooks. | O dashboard deve expor bloqueio/alerta quando o status ou a qualidade inviabilizar o envio. |

## Fontes oficiais

1. [About the WhatsApp Business Platform](https://developers.facebook.com/documentation/business-messaging/whatsapp/about-the-platform), atualizado em 4 de agosto de 2026.
2. [Webhooks](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview), atualizado em 26 de junho de 2026.
3. [Template fundamentals](https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview), atualizado em 21 de maio de 2026.
