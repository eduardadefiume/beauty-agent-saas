-- O gatilho de procedência contou o próprio carimbo como ajuste do dono.
--
-- Ao adotar as famílias que já existiam, a migração anterior escreveu
-- `product_code` numa linha com `origin = 'PRODUTO'`. O gatilho viu campo
-- diferente e concluiu que alguém tinha reescrito a família: as 18 famílias
-- dos três salões nasceram PRODUTO_AJUSTADO sem ninguém ter tocado nelas.
--
-- É o erro que mais importa não deixar passar aqui, porque a coluna existe
-- justamente para o onboarding saber o que ainda falta perguntar. Linha que
-- mente dizendo "o dono já confirmou" some da lista de perguntas.
--
-- `product_code` é anotação de origem, não palavra de dono: entra na lista de
-- campos que o gatilho ignora, junto de posição.

create or replace function app.marcar_ajuste_do_dono()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.origin = 'PRODUTO' then
    if to_jsonb(new) - 'position' - 'updated_at' - 'origin' - 'product_code'
       is distinct from to_jsonb(old) - 'position' - 'updated_at' - 'origin' - 'product_code' then
      new.origin := 'PRODUTO_AJUSTADO';
    end if;
  end if;
  return new;
end;
$function$;

-- Devolve o carimbo certo a quem foi marcado por engano. O critério não é
-- confiança: é a linha ainda estar idêntica ao que o produto planta hoje.
-- Família que o dono realmente mudou não bate, e continua ajustada.
update app.tone_families t
   set origin = 'PRODUTO'
  from app.product_tone_families f
 where t.origin = 'PRODUTO_AJUSTADO'
   and t.product_code = f.code
   and t.answered_at is null
   and t.name = f.name
   and t.description is not distinct from f.description
   and t.min_level is not distinct from f.min_level
   and t.max_level is not distinct from f.max_level
   and t.needs_warm_base = f.needs_warm_base;
