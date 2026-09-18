-- site_save_client apaga as visitas manuais (appointment_id is null) e
-- reinsere o que vier no payload. site_load_client, porem, devolve TODAS as
-- visitas sem dizer quais nasceram de um agendamento.
--
-- Consequencia: qualquer tela que carregue a ficha e salve de volta -- o
-- caminho normal -- duplica toda visita vinda da agenda, porque ela sobrevive
-- ao delete e entra de novo pelo insert. O erro so aparece depois, como
-- historico inflado, e ninguem liga uma coisa na outra.
--
-- A leitura passa a dizer de onde a visita veio. Com isso a tela devolve so as
-- manuais, que sao as unicas que ela pode editar.
do $$
declare
  antes  constant text := $t$'amountCents', v.amount_cents, 'notes', v.notes$t$;
  depois constant text := $t$'amountCents', v.amount_cents, 'notes', v.notes,
               'appointmentId', v.appointment_id$t$;
  definicao text;
begin
  select pg_get_functiondef(p.oid)
    into definicao
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'site_load_client';

  if definicao is null then
    raise exception 'public.site_load_client nao existe';
  end if;

  if position('''appointmentId'', v.appointment_id' in definicao) > 0 then
    raise notice 'a visita ja diz de onde veio, nada a fazer';
    return;
  end if;

  if position(antes in definicao) = 0 then
    raise exception 'o bloco visits de site_load_client nao esta como esperado; nada foi alterado';
  end if;

  execute replace(definicao, antes, depois);
end $$;
