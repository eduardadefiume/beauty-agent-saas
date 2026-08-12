/**
 * Domínio de produção fixo, usado só para montar redirect_uri de fluxos
 * OAuth de terceiros (Google, e no futuro Microsoft). Esses provedores
 * exigem que o redirect_uri bata exatamente com o que está cadastrado no
 * console deles, então não dá para usar a origem da requisição (como o
 * resto do app faz): em um deploy de preview da Vercel a origem muda a
 * cada deploy e nunca vai bater com o que foi cadastrado no Google,
 * gerando "redirect_uri_mismatch". Configurável por env pra não precisar
 * mexer em código se o domínio mudar; sem a env, cai no domínio real.
 */
export function canonicalSiteUrl(): string {
  return (process.env.NEXT_PUBLIC_SITE_URL ?? 'https://eddigital.ia.br').replace(/\/$/, '');
}
