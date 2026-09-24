-- O RESUMO DO CADASTRO ESCREVE O DIA.
--
-- 24/09/2026, teste com dono-robo. O cadastro tinha terca a sexta 9-19 e
-- sabado 8-17 (weekday 2..6), e o Eddy leu "2" como segunda e disse ao dono
-- "seg a sex 09:00-19:00" -- na hora de pedir confirmacao para publicar. O
-- dono diria "certo" para um horario que nao e o dele. Numero de dia e
-- convencao; nome de dia nao se le errado.

do $mig$
declare
  v_def text := pg_get_functiondef('app.eddy_cadastro_resumido(uuid)'::regprocedure);
  c_de constant text := E'jsonb_agg(h.weekday || '' '' || to_char(h.starts_at';
  c_para constant text := E'jsonb_agg((array[''domingo'',''segunda'',''terça'',''quarta'',''quinta'',''sexta'',''sábado''])[h.weekday + 1] || '' '' || to_char(h.starts_at';
begin
  if position(c_de in v_def) = 0 then
    raise exception 'ancora de eddy_cadastro_resumido sumiu';
  end if;
  execute replace(v_def, c_de, c_para);
end
$mig$;
