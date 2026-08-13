# Validação do domínio principal — 13/08/2026

URL validada: https://eddigital.ia.br/dashboard

Resultado: `404: This page could not be found.`

Interpretação: o preview da branch integrada está correto, mas o domínio principal continua associado ao deployment de Production da branch `main`. A rota `/dashboard` só ficará disponível em `eddigital.ia.br` depois que a branch `feature/saas-com-dashboard-completo` for definida como Production Branch e um deployment de produção bem-sucedido for criado, ou quando o domínio for atribuído diretamente a um deployment de produção dessa branch.
