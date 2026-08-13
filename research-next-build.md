# Evidência externa — erro de prerender do Next.js

## Fontes consultadas

- https://github.com/vercel/next.js/discussions/94667 — discussão de 10/06/2026 sobre Next.js 16.2.9, App Router e `Cannot read properties of null (reading 'useContext')` ao prerenderizar `/_global-error`. A discussão recomenda usar `next build --debug-prerender` para obter um stack trace mais detalhado e relata que o erro pode ocorrer durante o fallback de erro do framework.
- https://github.com/vercel/next.js/issues/84994 — issue do Next.js sobre `useContext` nulo no `/_global-error` com Next 16, inclusive em reproduções mínimas sem `global-error` customizado; indica que a origem pode estar no próprio runtime do framework, em especial no `Link`/`AppRouterContext` durante a geração da página de erro.
- https://github.com/vercel/next.js/issues/65447 — issue sobre falha de prerender de `/_not-found`; documenta que a rota de erro interna pode falhar por problemas de manifest/client references ou por uma exceção anterior durante a coleta de páginas.

## Aplicação ao caso

O projeto `@beauty/web` usa Next.js 16.2.12, React 19.2.8 e App Router. O build local concluiu typecheck e testes, mas falhou na etapa de prerender de `/_not-found`/`/_global-error` com `useContext` nulo, inclusive quando a importação global de CSS foi removida. Portanto, a causa não está comprovadamente no CSS do dashboard. O próximo diagnóstico deve usar `next build --debug-prerender` e verificar a exceção original que antecede a renderização da página interna de erro, sem assumir que o erro da página interna seja a causa primária.
