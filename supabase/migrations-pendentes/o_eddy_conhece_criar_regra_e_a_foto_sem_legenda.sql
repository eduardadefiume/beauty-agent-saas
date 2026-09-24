-- O PROMPT DO EDDY CONHECE criar_regra E A FOTO SEM LEGENDA.
--
-- Aplicada so DEPOIS do deploy do eddy-agent que traz `criar_regra`, e do
-- whatsapp-media-reader que le a foto do dono como aula. Prompt citando
-- ferramenta que nao esta no ar e pior que prompt atrasado.

do $mig$
declare
  v_body text;
  c_ancora constant text := '`guardar_conhecimento` — tudo o que ele ENSINAR';
  c_regra constant text :=
    E'`criar_regra` — quando o que ele ensinou muda como a atendente fala com as clientes: o que o salão NÃO faz ("não corto cabelo curto"), uma condição ("luzes só com teste de mecha"), um jeito de falar. Escreva a regra como uma instrução clara para a atendente, e mande as palavras dele junto. Ela entra em rascunho: só vale para cliente depois que ele publicar.\n\n';
begin
  select body into v_body
    from app.agent_prompt_blocks
   where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and status = 'ACTIVE';

  if v_body is null then
    raise exception 'EDDY_O_QUE_VOCE_PODE_ESCREVER nao encontrado';
  end if;
  if position('`criar_regra`' in v_body) > 0 then
    raise exception 'o bloco ja cita criar_regra';
  end if;
  if position(c_ancora in v_body) = 0 then
    raise exception 'ancora do guardar_conhecimento sumiu: 20260924105534 nao esta aplicada?';
  end if;

  update app.agent_prompt_blocks
     set body = replace(v_body, c_ancora, c_regra || c_ancora),
         updated_at = statement_timestamp()
   where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and status = 'ACTIVE';
end
$mig$;

insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
select 'EDDY_FOTO_SEM_LEGENDA', 'Foto sem legenda',
$txt$FOTO SEM LEGENDA NÃO É PERGUNTA SEM RESPOSTA
Quando ele manda uma foto sem escrever nada, a leitura técnica da foto chega para você na mensagem (leituraDaMidia): o que a imagem é, a técnica, o corte, o tom.

Nunca responda "o que é essa foto?". Ele mandou para você olhar. Diga em uma frase o que você viu, com o nome técnico, como um colega de salão diria: "Isso é uma morena iluminada, mecha fina, clareando do meio para as pontas."

E faça UMA pergunta, a que só ele sabe responder: o que essa foto é para o salão. "Você faz esse trabalho, não faz, ou é referência de resultado?"

A resposta dele decide a ferramenta:
- faz, e ainda não está no catálogo → `criar_servico`;
- não faz → `criar_regra`, assunto PROCEDIMENTO;
- é referência de como fica o trabalho dele → `guardar_conhecimento`, com a leitura técnica junto.

Se a leitura disser que é tabela de preços ou arte do salão, o texto transcrito já é o conteúdo: trate como se ele tivesse digitado aquilo.$txt$,
57, 'ACTIVE', 'DONO'
where not exists (
  select 1 from app.agent_prompt_blocks where agent = 'DONO' and code = 'EDDY_FOTO_SEM_LEGENDA'
);
