-- A ficha da cliente ganha rosto.
--
-- O PROBLEMA REAL, nas palavras da Duda: "para quando formos olhar quem é
-- andreia sabermos qual delas que é porque tem mais de 1 no salão."
--
-- Quem atende reconhece cliente por rosto, não por telefone. Uma lista com três
-- Andreias e nenhuma foto obriga quem está no balcão a abrir uma por uma
-- procurando o histórico que bate -- e no meio de um atendimento ninguém faz
-- isso, chuta.
--
-- POR QUE UM `kind` NOVO E NÃO UMA COLUNA. A ficha já guarda foto: CABELO_ATUAL
-- é a régua daquela cliente, RESULTADO é como ficou, COR é o tom que saiu.
-- Todas moram em `client_photos`, no balde `clientes`, sob o mesmo consentimento
-- e o mesmo prazo de apagamento. PERFIL é mais uma delas, e entrar por aqui é o
-- que faz "apagar os dados da fulana" continuar sendo um comando só.
--
-- E ELA NÃO É FOTO DE CABELO. As outras três existem para o trabalho técnico --
-- comparar antes e depois, lembrar o tom. Esta existe só para reconhecer a
-- pessoa. Misturá-las faria a foto do rosto entrar na comparação de resultado.

alter table app.client_photos drop constraint if exists client_photos_kind_check;
alter table app.client_photos add constraint client_photos_kind_check
  check (kind in ('CABELO_ATUAL', 'RESULTADO', 'COR', 'PERFIL'));

comment on column app.client_photos.kind is
  'CABELO_ATUAL e a regua daquela cliente, RESULTADO e como ficou, COR e o tom que saiu, PERFIL e o rosto que identifica a pessoa na lista. So PERFIL nao e foto de trabalho tecnico.';

-- Uma ficha tem no maximo um rosto. Sem isto, salvar duas vezes deixaria duas
-- e a lista escolheria uma no escuro.
create unique index if not exists client_photos_um_perfil_por_ficha
  on app.client_photos (profile_id) where kind = 'PERFIL';

-- ---------------------------------------------------------------------------
-- A lista traz o rosto junto do nome.
--
-- Sem isto a foto existiria na ficha e a lista continuaria sendo três nomes
-- iguais -- que é exatamente o problema que ela resolve.
-- ---------------------------------------------------------------------------
do $$
declare
  definicao text := pg_get_functiondef('public.site_load_clients(text,text,uuid,integer)'::regprocedure);
  antes text := '''pendencias'',';
  depois text := '''avatarPath'', (select f.storage_path from app.client_photos f
                     where f.profile_id = p.id and f.kind = ''PERFIL'' limit 1),
                   ''pendencias'',';
begin
  if position('''avatarPath''' in definicao) > 0 then
    raise notice 'a lista ja traz o rosto, nada a fazer';
    return;
  end if;
  if position(antes in definicao) = 0 then
    raise exception 'site_load_clients nao esta como esperado; nada foi alterado';
  end if;
  execute replace(definicao, antes, depois);
end $$;
