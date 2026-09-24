-- O EDDY APRENDE SEM PRECISAR DESISTIR.
--
-- EDDY_O_QUE_VOCE_PODE_ESCREVER e a lista de ferramentas, e ela e contrato:
-- ferramenta no codigo que o bloco nao cita e ferramenta que ele nao usa, e
-- ferramenta que o bloco cita sem estar no ar e chamada para o vazio. Por isso
-- esta migration so e aplicada DEPOIS do deploy do eddy-agent que traz
-- `guardar_conhecimento`.
--
-- Tres mudancas no bloco, cada uma conferida antes de trocar: se o trecho
-- esperado nao estiver la, a migration para em vez de escrever por cima de um
-- texto que alguem ja mudou.
--
-- 1. `guardar_conhecimento` entra na lista.
-- 2. O `anotar` passa a dizer que PAUSA tambem nao passa por ele. Em 23/09
--    foram 17 recusas PAUSA_FORA_DE_FAIXA seguidas por isso.
-- 3. O ultimo paragrafo separava so "consigo" de "nao consigo -> HANDOFF". Mas
--    o dono ENSINAR uma coisa que nao cabe em ferramenta nenhuma nao e pedido
--    fora do alcance: e conhecimento, e se guarda. HANDOFF fica para quando ele
--    PEDE uma acao que ninguem ali faz.

do $mig$
declare
  v_body text;
  v_novo text;
  c_anotar_antes constant text :=
    'Preço NÃO passa por aqui, e nome, endereço, equipe e horário também não: cada um tem a ferramenta dele acima.';
  c_anotar_depois constant text :=
    'Preço NÃO passa por aqui, pausa também não (é `definir_pausa`), e nome, endereço, equipe e horário também não: cada um tem a ferramenta dele acima.';
  c_resumo constant text := E'`resumo` — o que mudou no rascunho e o que falta para publicar.';
  c_guardar constant text :=
    E'`guardar_conhecimento` — tudo o que ele ENSINAR e que nenhuma ferramenta acima grava: uma regra solta ("não corto cabelo curto"), uma preferência, o jeito de falar com as clientes, o que uma foto mostra ("essa é um loiro iluminado"). Guarde com as palavras dele. Não tem régua de confiança: é para aprender, e alguém revisa depois. Nunca diga "anotei" sem ter recebido "Guardado".\n\n';
  c_fim_antes constant text :=
    'E quando ele pedir alguma coisa que nenhuma dessas ferramentas alcança: diga a ele que você não consegue fazer aquilo por ali, sem explicar o sistema por dentro, e encerre com HANDOFF.';
  c_fim_depois constant text :=
    E'Separe duas coisas. Quando ele ENSINA algo que nenhuma ferramenta grava, isso não é problema: use `guardar_conhecimento` e siga a conversa. Quando ele PEDE uma ação que nenhuma dessas ferramentas faz: diga a ele que você não consegue fazer aquilo por ali, sem explicar o sistema por dentro, e encerre com HANDOFF.';
begin
  select body into v_body
    from app.agent_prompt_blocks
   where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and status = 'ACTIVE';

  if v_body is null then
    raise exception 'EDDY_O_QUE_VOCE_PODE_ESCREVER nao encontrado';
  end if;
  if position('guardar_conhecimento' in v_body) > 0 then
    raise exception 'o bloco ja cita guardar_conhecimento: alguem ja aplicou isto';
  end if;
  if position(c_anotar_antes in v_body) = 0 then
    raise exception 'trecho do anotar mudou desde a leitura de 24/09';
  end if;
  if position(c_resumo in v_body) = 0 then
    raise exception 'trecho do resumo mudou desde a leitura de 24/09';
  end if;
  if position(c_fim_antes in v_body) = 0 then
    raise exception 'paragrafo final mudou desde a leitura de 24/09';
  end if;

  v_novo := replace(v_body, c_anotar_antes, c_anotar_depois);
  v_novo := replace(v_novo, c_resumo, c_guardar || c_resumo);
  v_novo := replace(v_novo, c_fim_antes, c_fim_depois);

  update app.agent_prompt_blocks
     set body = v_novo, updated_at = statement_timestamp()
   where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and status = 'ACTIVE';
end
$mig$;
