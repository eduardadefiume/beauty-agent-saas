-- CONEXAO QUE CAIU E DESCOBERTA NA GRAVACAO AVISA O DONO NA HORA.
--
-- 30/09/2026, teste "token vencido": a cliente marcou, a gravacao no Google
-- recebeu invalid_grant e so tentava de novo a cada minuto; o dono so seria
-- avisado na leitura de 15 em 15 minutos. Agora, erro de credencial na
-- gravacao derruba a conexao para ERROR (e o aviso ao dono sai pelo mesmo
-- caminho da leitura, uma vez por dia no maximo). A linha nao gasta
-- tentativa: quando ele reconectar, o gatilho da conexao poe tudo na fila de
-- novo e o agendamento aparece no Google.
create or replace function app.agenda_gravacao_feita(
  p_id                uuid,
  p_google_event_id   text,
  p_existe            boolean,
  p_erro              text,
  p_new_access_token  text,
  p_new_expires_at    timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_g app.agenda_gravacoes%rowtype;
begin
  select * into v_g from app.agenda_gravacoes where id = p_id for update;
  if v_g.id is null then
    return jsonb_build_object('ok', false, 'reason', 'NAO_EXISTE');
  end if;

  if p_new_access_token is not null then
    update app.calendar_connections
       set access_token = private.encrypt_calendar_token(p_new_access_token),
           token_expires_at = coalesce(p_new_expires_at, token_expires_at),
           updated_at = statement_timestamp()
     where id = v_g.connection_id;
  end if;

  if p_erro is not null then
    if p_erro in ('invalid_grant', 'REFRESH_TOKEN_MISSING', 'unauthorized_client')
       or p_erro like 'GOOGLE_401%' or p_erro like 'GOOGLE_403%' then
      update app.agenda_gravacoes
         set ultimo_erro = left(p_erro, 300), atualizado_em = statement_timestamp()
       where id = p_id;
      perform app.agenda_gravar_sincronizacao(v_g.connection_id, statement_timestamp(), statement_timestamp(),
                                              '[]'::jsonb, null, null, p_erro);
      return jsonb_build_object('ok', false, 'erro', p_erro, 'conexao', 'ERROR');
    end if;
    update app.agenda_gravacoes
       set tentativas = tentativas + 1, ultimo_erro = left(p_erro, 300),
           atualizado_em = statement_timestamp()
     where id = p_id;
    return jsonb_build_object('ok', false, 'erro', p_erro);
  end if;

  -- So baixa a fila se nada mudou desde que o worker leu: se o agendamento
  -- mudou no meio, a linha continua pendente e vai de novo.
  update app.agenda_gravacoes
     set pendente = case when deve_existir = p_existe then false else true end,
         google_event_id = case when p_existe then p_google_event_id else null end,
         gravado_em = statement_timestamp(),
         ultimo_erro = null,
         atualizado_em = statement_timestamp()
   where id = p_id;
  return jsonb_build_object('ok', true);
end;
$fn$;