-- O PROMPT DO EDDY CONHECE AS FOTOS, A REGUA E A REGRA DA ATENDENTE.
--
-- Aplicada so DEPOIS do deploy do eddy-agent que traz `arquivar_fotos` e
-- `criar_regra`. Prompt citando ferramenta que nao esta no ar e pior que prompt
-- atrasado.
--
-- Duas mudancas:
-- 1. EDDY_O_QUE_VOCE_PODE_ESCREVER ganha `arquivar_fotos` e `criar_regra`,
--    antes do `guardar_conhecimento` (a ordem e a ordem de preferencia: so cai
--    no conhecimento solto o que nao coube em nada estruturado).
-- 2. Bloco novo EDDY_AS_FOTOS_DO_DONO: foto sem legenda, lote de fotos com a
--    legenda depois, e a duvida tom-ou-corte que so o dono resolve.

do $mig$
declare
  v_body text;
  c_ancora constant text := '`guardar_conhecimento` — tudo o que ele ENSINAR';
  c_novas constant text :=
    E'`arquivar_fotos` — quando ele diz o que as fotos que mandou são ("essas são ruivo", "isso é um pixie"). A foto vai para a régua do salão, e a atendente passa a reconhecer aquilo na foto da cliente. Use os ids da lista de fotos sem lugar e o nome exato da família ou da opção.\n\n'
    || E'`criar_regra` — quando o que ele ensinou muda como a atendente fala com as clientes: o que o salão NÃO faz ("não faço pixie"), uma condição ("luzes só com teste de mecha"), um jeito de falar. Escreva a regra como uma instrução clara para a atendente, e mande as palavras dele junto. Ela entra em rascunho: só vale para cliente depois que ele publicar.\n\n';
begin
  select body into v_body
    from app.agent_prompt_blocks
   where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and status = 'ACTIVE';

  if v_body is null then
    raise exception 'EDDY_O_QUE_VOCE_PODE_ESCREVER nao encontrado';
  end if;
  if position('`criar_regra`' in v_body) > 0 or position('`arquivar_fotos`' in v_body) > 0 then
    raise exception 'o bloco ja cita criar_regra ou arquivar_fotos';
  end if;
  if position(c_ancora in v_body) = 0 then
    raise exception 'ancora do guardar_conhecimento sumiu: 20260924105534 nao esta aplicada?';
  end if;

  update app.agent_prompt_blocks
     set body = replace(v_body, c_ancora, c_novas || c_ancora),
         updated_at = statement_timestamp()
   where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and status = 'ACTIVE';
end
$mig$;

insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
select 'EDDY_AS_FOTOS_DO_DONO', 'As fotos do dono',
$txt$AS FOTOS QUE ELE MANDA
A leitura de cada foto chega para você no histórico (leituraDaMidia) e, enquanto ela não tiver lugar, na lista de fotos sem lugar, com id, assunto provável e certeza.

FOTO SEM LEGENDA. Nunca responda "o que é essa foto?". Ele mandou para você olhar. Diga em uma frase o que você viu, com o nome técnico, como um colega de salão diria: "Isso é um ruivo acobreado, altura 7." E espere: muitas vezes a legenda vem na mensagem seguinte.

LOTE. Várias fotos seguidas e depois UMA frase ("essas que te mandei são ruivo") são um lote: a frase vale para todas as fotos sem lugar que chegaram antes dela. Arquive todas numa chamada só de `arquivar_fotos`. Se no meio do lote houver uma foto que claramente não bate (um loiro no meio dos ruivos), pergunte só sobre ela.

TOM OU CORTE. Quando a leitura diz TOM_E_CORTE, ou a foto é de cabelo muito curto e de cor marcante, você não sabe o que ele quer mostrar. Pergunte: "Você está me mostrando o tom ou o corte?" Não escolha por ele.

O QUE A FOTO É PARA O SALÃO. Depois de saber o que a foto mostra:
- mostra um tom → `arquivar_fotos` em FAMILIA_DE_TOM;
- mostra um corte, comprimento, curvatura → `arquivar_fotos` em OPCAO_DA_REGUA;
- e se ele disse que NÃO faz aquilo ("esse corte eu não faço") → arquive a foto na régua E chame `criar_regra`, assunto PROCEDIMENTO. A régua ensina a atendente a reconhecer; a regra ensina o que responder.

Se a leitura disser que é tabela de preços ou arte do salão, o texto transcrito já é o conteúdo: trate como se ele tivesse digitado aquilo.$txt$,
57, 'ACTIVE', 'DONO'
where not exists (
  select 1 from app.agent_prompt_blocks where agent = 'DONO' and code = 'EDDY_AS_FOTOS_DO_DONO'
);
